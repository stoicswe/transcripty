import Foundation
import AVFoundation

/// Renders the source audio into a normalized mono 16 kHz int16 WAV temp file
/// for the diarization + transcription models to consume. The pipeline always
/// operates against this normalized copy regardless of the source format —
/// stereo, multichannel, 48/96 kHz, AAC, FLAC, MP3, CAF, AIFF, etc. all reach
/// the models in the format they actually want (which is what FluidAudio and
/// SpeechTranscriber both expect natively).
///
/// On every input the file gets:
///   * mono mixdown
///   * downsample to 16 kHz
///   * encode as 16-bit PCM interleaved WAV
///
/// On *quiet* inputs (peak < −6 dBFS or RMS < −22 dBFS) it additionally gets:
///   * peak normalization to −3 dBFS
///   * a soft-knee compressor (−24 dBFS / 3:1) with 1.25× makeup
///
/// Loud inputs skip the level processing because amplifying them further would
/// just clip; they still go through the format conversion so the downstream
/// code path is uniform.
enum AudioEnhancer {
    /// Always returns a temp-file URL pointing at the normalized copy. The
    /// caller is responsible for deleting it when the run finishes.
    static func enhance(sourceURL: URL) async throws -> URL {
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
    /// Skip level processing when *both* conditions hold:
    ///   - the peak is already within a few dB of target (≈ −6 dBFS), so
    ///     normalization would barely move the level, AND
    ///   - the RMS is above broadcast-ish speech levels (≈ −22 dBFS), so
    ///     compression wouldn't meaningfully lift soft passages.
    /// A recording with one loud spike but mostly quiet speech will still
    /// trip the RMS gate and get the level-enhancement chain.
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

    private static func enhanceSync(sourceURL: URL) throws -> URL {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let stats = try scanStats(url: sourceURL)
        let needsLevelEnhancement = !(stats.peak >= skipEnhancementPeak && stats.rms >= skipEnhancementRMS)
        let normGain: Float
        if needsLevelEnhancement {
            normGain = stats.peak > 1e-5
                ? min(maxNormGain, targetPeak / stats.peak)
                : 1.0
        } else {
            normGain = 1.0
        }

        return try processAndWrite(
            url: sourceURL,
            normGain: normGain,
            applyCompression: needsLevelEnhancement
        )
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

    private static func processAndWrite(
        url: URL,
        normGain: Float,
        applyCompression: Bool
    ) throws -> URL {
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

        // 16-bit PCM mono interleaved WAV at 16 kHz. AVAudioFile's storage
        // format is what we specify here; its in-memory `processingFormat` is
        // float32, so we keep writing float32 buffers and let the file convert
        // on the way to disk. Plain int16 WAV is the lingua franca of speech
        // tooling — every reader downstream handles it.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripty-enhanced-\(UUID().uuidString).wav")
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let outputFile = try AVAudioFile(forWriting: tempURL, settings: fileSettings)

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

                if applyCompression {
                    let a = abs(s)
                    if a > threshold {
                        let overdB = 20 * log10f(a / threshold)
                        let newA = threshold * powf(10, (overdB / ratio) / 20)
                        s = s >= 0 ? newA : -newA
                    }
                    s *= makeupGain
                }

                if s > 0.98 { s = 0.98 } else if s < -0.98 { s = -0.98 }
                outMono[j] = s
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
