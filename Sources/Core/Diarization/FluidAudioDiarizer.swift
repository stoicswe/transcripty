import Foundation
import FluidAudio

/// `Diarizer` conformer backed by FluidAudio's offline VBx pipeline
/// (pyannote powerset segmentation → WeSpeaker embeddings → VBx clustering).
///
/// Runs entirely on device via Core ML on the Apple Neural Engine. The only
/// network use is the first-time download of the two `.mlmodelc` bundles from
/// the FluidInference Hugging Face registry; after that, no network access.
final class FluidAudioDiarizer: Diarizer {

    func diarize(
        audioURL: URL,
        expectedSpeakerCount: Int?,
        onProgress: @escaping @Sendable (DiarizerProgress) -> Void
    ) async throws -> DiarizationOutput {

        let accessed = audioURL.startAccessingSecurityScopedResource()
        defer { if accessed { audioURL.stopAccessingSecurityScopedResource() } }

        let manager = OfflineDiarizerManager(config: Self.makeConfig(expectedSpeakerCount: expectedSpeakerCount))

        onProgress(.preparingModels)
        do {
            try await manager.prepareModels()
        } catch {
            throw DiarizerError.modelPreparationFailed(underlying: error)
        }

        onProgress(.analyzing)
        let result: DiarizationResult
        do {
            result = try await manager.process(audioURL)
        } catch {
            throw DiarizerError.audioUnreadable(audioURL)
        }

        let segments = result.segments.map { seg in
            DiarizedSegment(
                start: TimeInterval(seg.startTimeSeconds),
                end: TimeInterval(seg.endTimeSeconds),
                speakerID: seg.speakerId,
                embedding: seg.embedding
            )
        }
        return DiarizationOutput(
            segments: segments,
            speakerCentroids: result.speakerDatabase ?? [:]
        )
    }

    /// Accuracy-biased configuration for the FluidAudio pipeline. Each tweak
    /// away from the community defaults is there to address a real failure
    /// mode we saw on multi-speaker recordings:
    ///
    ///   * `clustering.numSpeakers` — when the user tells us the count up
    ///     front, VBx is constrained to exactly N clusters, which is far
    ///     more reliable than threshold-based auto-detection.
    ///   * `clustering.threshold` slightly lower (0.55 vs 0.6) — the
    ///     default tends to merge similar voices (e.g. two adult males on
    ///     the same mic) into one cluster. A small nudge separates them
    ///     without producing spurious 3rd/4th speakers on typical audio.
    ///   * `embedding.minSegmentDurationSeconds` lower (0.5 vs 1.0) —
    ///     captures short turns (backchannels, one-word answers) that the
    ///     default threshold would otherwise skip entirely, leaving them
    ///     unattributed and merged into whichever neighbor wins on overlap.
    ///   * `segmentation.stepRatio` tighter (0.1 vs 0.2) — doubles the
    ///     window overlap so turn boundaries land on the right sample,
    ///     which is what our per-word assignment reads against.
    ///   * `postProcessing.minGapDurationSeconds` nudged up slightly to
    ///     merge micro-gaps inside one person's continued speech.
    private static func makeConfig(expectedSpeakerCount: Int?) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig()
        if let count = expectedSpeakerCount, count >= 1 {
            config.clustering.numSpeakers = count
        } else {
            config.clustering.threshold = 0.55
        }
        config.embedding.minSegmentDurationSeconds = 0.5
        config.segmentation.stepRatio = 0.1
        config.postProcessing.minGapDurationSeconds = 0.3
        return config
    }
}
