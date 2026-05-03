import Foundation
import AVFoundation

/// Pure helpers behind the user's inline-edit + recompute-timings flow. Kept
/// out of `TranscriptionService` so the alignment + audio-extraction logic
/// can be unit-tested in isolation and reasoned about without the SwiftData
/// machinery.
enum TranscriptEditing {

    // MARK: - Tokenization

    /// Splits user-edited segment text into the per-word units we store in
    /// `WordTiming`. Whitespace-separated; empty tokens dropped. Punctuation
    /// stays attached to its preceding token (matching how Apple's speech
    /// recognizer emits words like "today.").
    static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Reconciliation

    /// Rebuilds a segment's word list when the user changes its text. Words
    /// that survived the edit (matched by case-insensitive equality, in LCS
    /// order) keep their original timings; new/inserted words get evenly-
    /// spaced interpolated timings between their nearest matched neighbors.
    /// The interpolation is intentionally crude — it's good enough for the
    /// editor's playback highlight to land in the right neighborhood, and
    /// the user can hit "Recompute Timings" to get a forced-alignment pass.
    static func reconcileWords(
        oldWords: [WordTiming],
        newTokens: [String],
        segmentStart: TimeInterval,
        segmentEnd: TimeInterval
    ) -> [WordTiming] {
        guard !newTokens.isEmpty else { return [] }

        let oldLower = oldWords.map { $0.text.lowercased() }
        let newLower = newTokens.map { $0.lowercased() }
        let matches = lcsMatches(old: oldLower, new: newLower)
        let matchedNewIndices = Dictionary(uniqueKeysWithValues: matches.map { ($0.newIdx, $0.oldIdx) })

        // Pre-fill timings for matched words; leave unmatched as nil so the
        // interpolation pass below can fold them between anchors.
        var slots: [WordTiming?] = Array(repeating: nil, count: newTokens.count)
        for (newIdx, oldIdx) in matchedNewIndices {
            let old = oldWords[oldIdx]
            slots[newIdx] = WordTiming(start: old.start, end: old.end, text: newTokens[newIdx])
        }

        var i = 0
        while i < slots.count {
            if slots[i] != nil {
                i += 1
                continue
            }
            // Find the run of consecutive nil entries [i..<j).
            var j = i
            while j < slots.count, slots[j] == nil { j += 1 }
            let runCount = j - i

            let leadAnchor: TimeInterval = (i > 0)
                ? (slots[i - 1]?.end ?? segmentStart)
                : segmentStart
            let trailAnchor: TimeInterval
            if j < slots.count, let next = slots[j] {
                trailAnchor = next.start
            } else {
                trailAnchor = segmentEnd
            }
            let span = max(0.05, trailAnchor - leadAnchor)
            let perWord = span / Double(runCount)

            for k in 0..<runCount {
                let s = leadAnchor + perWord * Double(k)
                let e = leadAnchor + perWord * Double(k + 1)
                slots[i + k] = WordTiming(start: s, end: e, text: newTokens[i + k])
            }

            i = j
        }

        return slots.compactMap { $0 }
    }

    // MARK: - LCS

    /// Longest common subsequence over two token lists. Returns the matched
    /// (oldIdx, newIdx) pairs in increasing order. Lowercased comparison is
    /// the caller's responsibility.
    static func lcsMatches(old: [String], new: [String]) -> [(oldIdx: Int, newIdx: Int)] {
        let m = old.count
        let n = new.count
        guard m > 0, n > 0 else { return [] }

        // Standard O(mn) DP table. Segment word counts top out in the low
        // hundreds even for long monologues, so this fits comfortably.
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if old[i - 1] == new[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        var matches: [(oldIdx: Int, newIdx: Int)] = []
        var i = m, j = n
        while i > 0, j > 0 {
            if old[i - 1] == new[j - 1] {
                matches.append((oldIdx: i - 1, newIdx: j - 1))
                i -= 1
                j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return matches.reversed()
    }

    // MARK: - Audio range extraction

    /// Errors that can short-circuit the recompute-timings pipeline.
    enum RecomputeError: LocalizedError {
        case sourceUnavailable
        case extractionFailed(underlying: any Error)
        case rangeOutOfBounds

        var errorDescription: String? {
            switch self {
            case .sourceUnavailable:
                return "The project's audio is no longer accessible."
            case .extractionFailed(let underlying):
                return "Couldn't extract the segment's audio: \(underlying.localizedDescription)"
            case .rangeOutOfBounds:
                return "The segment's time range is outside the audio file."
            }
        }
    }

    /// Pulls a `start..<end` slice out of `sourceURL` and writes it as a
    /// 16-bit PCM mono WAV to a temp file. Mono + 16 kHz here matches what
    /// `AppleSpeechTranscriber` is happiest with — small, consistent input
    /// shape gives the recognizer the best shot at clean word timings.
    static func extractAudioRange(
        from sourceURL: URL,
        start: TimeInterval,
        end: TimeInterval
    ) async throws -> URL {
        let path = sourceURL.path
        let startTime = max(0, start)
        let endTime = max(startTime + 0.05, end)
        return try await Task.detached(priority: .userInitiated) {
            let url = URL(fileURLWithPath: path)
            let inputFile = try AVAudioFile(forReading: url)
            let inputFormat = inputFile.processingFormat
            let inChannels = Int(inputFormat.channelCount)
            let inSampleRate = inputFormat.sampleRate
            let totalFrames = inputFile.length

            let startFrame = AVAudioFramePosition(startTime * inSampleRate)
            let endFrame = AVAudioFramePosition(endTime * inSampleRate)
            guard startFrame < totalFrames, startFrame >= 0 else {
                throw RecomputeError.rangeOutOfBounds
            }
            let clampedEnd = min(endFrame, totalFrames)
            let frameCount = AVAudioFrameCount(clampedEnd - startFrame)
            guard frameCount > 0 else {
                throw RecomputeError.rangeOutOfBounds
            }

            inputFile.framePosition = startFrame
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
                throw RecomputeError.extractionFailed(underlying: NSError(
                    domain: "TranscriptEditing",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "couldn't allocate input buffer"]
                ))
            }
            do {
                try inputFile.read(into: inputBuffer, frameCount: frameCount)
            } catch {
                throw RecomputeError.extractionFailed(underlying: error)
            }

            let targetSampleRate: Double = 16_000
            guard let monoFloat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inSampleRate,
                channels: 1,
                interleaved: false
            ),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            ),
            let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFloat, frameCapacity: frameCount),
            let converter = AVAudioConverter(from: monoFloat, to: outputFormat) else {
                throw RecomputeError.extractionFailed(underlying: NSError(
                    domain: "TranscriptEditing",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "couldn't initialize audio resampler"]
                ))
            }

            // Mix to mono.
            guard let inData = inputBuffer.floatChannelData,
                  let monoOut = monoBuffer.floatChannelData?[0] else {
                throw RecomputeError.extractionFailed(underlying: NSError(
                    domain: "TranscriptEditing",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "missing channel data"]
                ))
            }
            let frames = Int(inputBuffer.frameLength)
            for j in 0..<frames {
                var s: Float = 0
                for c in 0..<inChannels { s += inData[c][j] }
                monoOut[j] = s / Float(inChannels)
            }
            monoBuffer.frameLength = AVAudioFrameCount(frames)

            // Resample to 16 kHz mono float32.
            let outCapacity = AVAudioFrameCount(
                Double(frames) * targetSampleRate / inSampleRate + 1024
            )
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
                throw RecomputeError.extractionFailed(underlying: NSError(
                    domain: "TranscriptEditing",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "couldn't allocate output buffer"]
                ))
            }
            var consumed = false
            var convError: NSError?
            _ = converter.convert(to: outBuffer, error: &convError) { _, status in
                if consumed { status.pointee = .endOfStream; return nil }
                consumed = true
                status.pointee = .haveData
                return monoBuffer
            }
            if let convError {
                throw RecomputeError.extractionFailed(underlying: convError)
            }

            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcripty-segment-\(UUID().uuidString).wav")
            let fileSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: targetSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let outputFile = try AVAudioFile(forWriting: outURL, settings: fileSettings)
            try outputFile.write(from: outBuffer)
            return outURL
        }.value
    }
}
