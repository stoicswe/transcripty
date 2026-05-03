import Foundation

struct DiarizedSegment: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let speakerID: String
    /// 256-D speaker embedding (WeSpeaker space) for the audio in this turn.
    /// Empty when the diarizer didn't produce one — callers should treat
    /// missing embeddings as "no enrollment data available for this turn".
    let embedding: [Float]
}

/// Bundles the diarizer's segment timeline with the per-speaker centroid map
/// so downstream code can do voice-print matching (e.g. enrollment, label
/// transfer across re-runs) without recomputing embeddings.
struct DiarizationOutput: Sendable {
    let segments: [DiarizedSegment]
    /// Average embedding per speakerID — already L2-normalized by the
    /// diarizer. Empty when the underlying engine doesn't expose centroids.
    let speakerCentroids: [String: [Float]]
}

enum DiarizerProgress: Sendable {
    case preparingModels
    case downloadingModels(fraction: Double?)
    case analyzing
}

protocol Diarizer: Sendable {
    func diarize(
        audioURL: URL,
        expectedSpeakerCount: Int?,
        onProgress: @escaping @Sendable (DiarizerProgress) -> Void
    ) async throws -> DiarizationOutput
}

enum DiarizerError: LocalizedError {
    case modelPreparationFailed(underlying: any Error)
    case audioUnreadable(URL, underlying: (any Error)?)

    var errorDescription: String? {
        switch self {
        case .modelPreparationFailed(let underlying):
            return "Couldn't prepare the speaker-diarization models: \(underlying.localizedDescription)"
        case .audioUnreadable(let url, let underlying):
            if let underlying {
                return "Couldn't read audio for diarization at \(url.path): \(underlying.localizedDescription)"
            }
            return "Couldn't read audio for diarization at \(url.path)."
        }
    }
}
