import Foundation

struct WordTiming: Sendable, Equatable, Hashable, Codable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
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
