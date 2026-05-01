import Foundation
import AVFoundation

/// Writes a loudness-normalized, softly-compressed, mono 16 kHz copy of the
/// source audio to a temp file and returns its URL, *only when the input is
/// quiet enough to benefit*. Already-loud recordings return `nil` and the
/// pipeline uses the original file directly — this avoids producing a very
/// large temp file (and the associated disk/read risk) for hour-long audio
/// that wouldn't meaningfully change from enhancement.
///
/// When enhancement runs, it:
///   1. Mixes to mono (both speaker models are mono-native)
///   2. Peak-normalizes to −3 dBFS (brings quiet recordings up)
///   3. Applies a soft-knee compressor (−24 dBFS / 3:1) to lift soft passages
///   4. Downsamples to 16 kHz (native rate for SpeechTranscriber and WeSpeaker)
enum AudioEnhancer {
    /// Returns an enhanced temp-file URL only if the source needs it. `nil`
    /// means the caller should transcribe the original file directly.
    static func enhance(sourceURL: URL) async throws -> URL? {
        try await Task.detached(priority: .userInitiated) {
            try enhanceSync(sourceURL: sourceURL)
        }.value
    }

    // MARK: - Implementation

    private static let outputSampleRate: Double = 16_000
    private static let targetPeak: Float = 0.707       // −3 dBFS
    private static let threshold: Float = 0.0631       // −24 dBFS
    private static let ratio: Float = 3.0
    private static let makeupGain: Float = 1.25
    private static let maxNormGain: Float = 16.0       // +24 dB cap; avoids amplifying tape hiss
    /// Skip enhancement when *both* conditions hold:
    ///   - the peak is already within a few dB of target (≈ −6 dBFS), so
    ///     normalization would barely move the level, AND
    ///   - the RMS is above broadcast-ish speech levels (≈ −22 dBFS), so
    ///     compression wouldn't meaningfully lift soft passages.
    /// A recording with one loud spike but mostly quiet speech will still
    /// trip the RMS gate and get enhanced.
    private static let skipEnhancementPeak: Float = 0.5      // −6 dBFS
    private static let skipEnhancementRMS: Float = 0.08      // −22 dBFS

    enum EnhancerError: Error {
        case bufferAllocFailed
        case converterInitFailed
        case conversionFailed
    }

    private struct Stats {
        var peak: Float = 0
        var rms: Float = 0
    }

    private static func enhanceSync(sourceURL: URL) throws -> URL? {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let stats = try scanStats(url: sourceURL)
        if stats.peak >= skipEnhancementPeak, stats.rms >= skipEnhancementRMS {
            return nil
        }
        let normGain = stats.peak > 1e-5
            ? min(maxNormGain, targetPeak / stats.peak)
            : 1.0

        return try processAndWrite(url: sourceURL, normGain: normGain)
    }

    private static func scanStats(url: URL) throws -> Stats {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let chunkFrames: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw EnhancerError.bufferAllocFailed
        }
        var stats = Stats()
        var sumSquares: Double = 0
        var sampleCount: Int = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for j in 0..<frames {
                var s: Float = 0
                for c in 0..<channels { s += data[c][j] }
                s /= Float(channels)
                let a = abs(s)
                if a > stats.peak { stats.peak = a }
                sumSquares += Double(s) * Double(s)
                sampleCount += 1
            }
        }
        if sampleCount > 0 {
            stats.rms = Float((sumSquares / Double(sampleCount)).squareRoot())
        }
        return stats
    }

    private static func processAndWrite(url: URL, normGain: Float) throws -> URL {
        let inputFile = try AVAudioFile(forReading: url)
        let inputFormat = inputFile.processingFormat
        let channels = Int(inputFormat.channelCount)
        let chunkFrames: AVAudioFrameCount = 65_536

        guard let monoSourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw EnhancerError.bufferAllocFailed }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: false
        ) else { throw EnhancerError.bufferAllocFailed }

        guard let inputChunk = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunkFrames),
              let monoChunk  = AVAudioPCMBuffer(pcmFormat: monoSourceFormat, frameCapacity: chunkFrames)
        else { throw EnhancerError.bufferAllocFailed }

        guard let converter = AVAudioConverter(from: monoSourceFormat, to: outputFormat) else {
            throw EnhancerError.converterInitFailed
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripty-enhanced-\(UUID().uuidString).caf")
        let outputFile = try AVAudioFile(forWriting: tempURL, settings: outputFormat.settings)

        while inputFile.framePosition < inputFile.length {
            try inputFile.read(into: inputChunk)
            let frames = Int(inputChunk.frameLength)
            if frames == 0 { break }

            guard let inData = inputChunk.floatChannelData,
                  let outMono = monoChunk.floatChannelData?[0] else { break }

            for j in 0..<frames {
                var s: Float = 0
                for c in 0..<channels { s += inData[c][j] }
                s = (s / Float(channels)) * normGain

                let a = abs(s)
                if a > threshold {
                    let overdB = 20 * log10f(a / threshold)
                    let newA = threshold * powf(10, (overdB / ratio) / 20)
                    s = s >= 0 ? newA : -newA
                }

                var y = s * makeupGain
                if y > 0.98 { y = 0.98 } else if y < -0.98 { y = -0.98 }
                outMono[j] = y
            }
            monoChunk.frameLength = AVAudioFrameCount(frames)

            let outCapacity = AVAudioFrameCount(
                Double(frames) * outputSampleRate / inputFormat.sampleRate + 1024
            )
            guard let outChunk = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
                throw EnhancerError.bufferAllocFailed
            }
            var consumed = false
            var convError: NSError?
            let status = converter.convert(to: outChunk, error: &convError) { _, outStatus in
                if consumed { outStatus.pointee = .endOfStream; return nil }
                consumed = true
                outStatus.pointee = .haveData
                return monoChunk
            }
            if let convError { throw convError }
            if status == .error { throw EnhancerError.conversionFailed }

            if outChunk.frameLength > 0 {
                try outputFile.write(from: outChunk)
            }
        }

        if let tail = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 2048) {
            var drained = false
            var err: NSError?
            _ = converter.convert(to: tail, error: &err) { _, outStatus in
                if drained { outStatus.pointee = .endOfStream; return nil }
                drained = true
                outStatus.pointee = .endOfStream
                return nil
            }
            if tail.frameLength > 0 {
                try outputFile.write(from: tail)
            }
        }

        return tempURL
    }
}
