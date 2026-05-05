import Foundation

/// Quality grade for a word's timing. Set by the alignment verifier when a
/// recompute pass runs; legacy / never-verified words default to
/// `.unverified`. The editor uses this to decide whether to surface a
/// "this segment may seek imprecisely" hint.
enum WordTimingQuality: String, Sendable, Codable, CaseIterable {
    /// Default for legacy data and freshly-imported segments — no
    /// verification has been run on these timings yet.
    case unverified
    /// ASR matched a recognizer word AND VAD snapped both edges to a
    /// real speech boundary inside ±30 ms. Highest confidence; seeking
    /// here lands on the right syllable.
    case verified
    /// ASR matched a recognizer word but VAD couldn't snap one or both
    /// edges within the tight window. Edges fall back to ASR's output —
    /// usually fine but not corroborated by signal-level boundaries.
    case approximate
    /// LCS couldn't match the user's token to the recognizer's output;
    /// timings are interpolated between the nearest matched anchors.
    /// Seeking here may drift up to a word's worth.
    case interpolated
}

struct WordTiming: Sendable, Equatable, Hashable, Codable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    /// Recognizer-reported confidence in 0…1 when available. Legacy
    /// timings (before the verifier landed) decode as 0.
    var confidence: Float
    /// Verifier-assigned quality. Legacy / never-verified entries decode
    /// as `.unverified`.
    var quality: WordTimingQuality

    init(
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        confidence: Float = 0,
        quality: WordTimingQuality = .unverified
    ) {
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
        self.quality = quality
    }

    // Custom decoding so legacy persisted JSON (`{start, end, text}`
    // with no `confidence` or `quality` fields) decodes cleanly with
    // the defaults above. Without this, every existing segment in
    // every existing project would fail to decode after this change.
    private enum CodingKeys: String, CodingKey {
        case start, end, text, confidence, quality
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.start = try container.decode(TimeInterval.self, forKey: .start)
        self.end = try container.decode(TimeInterval.self, forKey: .end)
        self.text = try container.decode(String.self, forKey: .text)
        self.confidence = try container.decodeIfPresent(Float.self, forKey: .confidence) ?? 0
        self.quality = try container.decodeIfPresent(WordTimingQuality.self, forKey: .quality) ?? .unverified
    }
}

struct TranscribedSegment: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let words: [WordTiming]
}

/// Progress signals emitted while transcribing. `fraction` is 0…1 when known.
enum TranscriberProgress: Sendable {
    case checkingSupport
    case downloadingModel(fraction: Double?)
    case preparing
    case analyzing
}

protocol Transcriber: Sendable {
    func transcribe(
        audioURL: URL,
        locale: Locale,
        onProgress: @escaping @Sendable (TranscriberProgress) -> Void
    ) async throws -> [TranscribedSegment]
}

enum TranscriptionError: LocalizedError {
    case localeNotSupported(Locale)
    case modelInstallFailed(underlying: any Error)
    case audioUnreadable(URL)
    case securityScopedAccessDenied(URL)

    var errorDescription: String? {
        switch self {
        case .localeNotSupported(let locale):
            return "On-device speech recognition isn't available for \(locale.identifier(.bcp47))."
        case .modelInstallFailed(let underlying):
            return "Couldn't install the speech model: \(underlying.localizedDescription)"
        case .audioUnreadable(let url):
            return "Couldn't open the audio file at \(url.path)."
        case .securityScopedAccessDenied(let url):
            return "Transcripty doesn't have permission to read the audio file at \(url.path)."
        }
    }
}
