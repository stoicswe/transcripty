import Foundation
import SwiftData

/// Observable coordinator that runs the full diarize + transcribe + merge
/// pipeline and writes results back into the project's SwiftData store.
@MainActor
@Observable
final class TranscriptionService {

    struct JobState: Sendable {
        var phase: Phase = .queued
        var modelDownloadFraction: Double?
        var errorMessage: String?

        enum Phase: Sendable, Equatable {
            case queued
            case preparingDiarizer
            case preparingTranscriber
            case downloadingTranscriberModel
            case analyzing
            case saving
            case finished
            case failed
        }
    }

    private(set) var jobs: [UUID: JobState] = [:]

    private let pipeline: TranscriptionPipeline
    private let modelContext: ModelContext
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(
        modelContext: ModelContext,
        transcriber: any Transcriber = AppleSpeechTranscriber(),
        diarizer: any Diarizer = FluidAudioDiarizer()
    ) {
        self.modelContext = modelContext
        self.pipeline = TranscriptionPipeline(transcriber: transcriber, diarizer: diarizer)
    }

    func start(project: TranscriptionProject, locale: Locale = .current) {
        runPipeline(for: project, locale: locale, hints: nil)
    }

    /// Re-runs the diarize + transcribe pipeline using the user's existing
    /// labels as supervision. Two pieces of supervision are passed in:
    ///
    ///   1. **Speaker count** — when the user has named N distinct speakers
    ///      we pin VBx clustering to that exact count. This is the highest-
    ///      leverage hint we can give the diarizer; the count alone resolves
    ///      most over-/under-clustering errors.
    ///   2. **Label transfer by overlap** — after the new pipeline produces
    ///      its own anonymous `Speaker_N` IDs, each new ID is mapped to the
    ///      user-named display whose annotated time-ranges overlap it most.
    ///      The mapping is applied via `project.speakerNames`, so the user's
    ///      naming work survives re-transcription.
    ///
    /// Future direction: pass true voice-print embeddings into FluidAudio's
    /// `SpeakerManager.initializeKnownSpeakers` for embedding-based identity
    /// instead of overlap-based. That requires deeper coupling to the
    /// segmentation pipeline than fits this iteration.
    func retranscribe(project: TranscriptionProject, locale: Locale = .current) {
        let hints = supervisionHints(from: project)
        wipeTranscript(in: project)
        runPipeline(for: project, locale: locale, hints: hints)
    }

    /// Re-runs the pipeline using settings the user explicitly chose in the
    /// project's transcription-settings sheet.
    ///
    ///   - `expectedSpeakerCount` is written through to the project (so the
    ///     value persists for future runs) and authoritatively drives VBx
    ///     clustering, even if the inferred count from labels would differ.
    ///   - `useLabels` controls whether the user's existing speaker names are
    ///     transferred onto the new run via overlap + embedding matching. Off
    ///     when the user wants a clean run with no transitive naming.
    func retranscribe(
        project: TranscriptionProject,
        locale: Locale = .current,
        expectedSpeakerCount: Int?,
        useLabels: Bool
    ) {
        project.expectedSpeakerCount = expectedSpeakerCount

        var hints = useLabels ? supervisionHints(from: project) : nil
        if let base = hints, let count = expectedSpeakerCount {
            // The user picked a count explicitly. That value wins over the
            // count inferred from how many distinct speakers they labelled.
            hints = SupervisionHints(
                speakerCount: count,
                namedRanges: base.namedRanges,
                referenceEmbeddings: base.referenceEmbeddings
            )
        }

        wipeTranscript(in: project)
        runPipeline(for: project, locale: locale, hints: hints)
    }

    /// Wipes the transcript (segments + revision history) but keeps the audio
    /// copy and project metadata. Use this to reset to a clean slate before a
    /// fresh transcription run, or as a standalone "start over" action.
    /// Cancels any in-flight job for the project first.
    func clearTranscript(in project: TranscriptionProject) {
        let id = project.id
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
        jobs.removeValue(forKey: id)

        try? modelContext.delete(model: SpeakerSegment.self, where: #Predicate { segment in
            segment.project?.id == id
        })
        try? modelContext.delete(model: ProjectEdit.self, where: #Predicate { edit in
            edit.project?.id == id
        })
        project.segments.removeAll()
        project.edits.removeAll()
        project.speakerOrder = []
        project.speakerNames = [:]
        project.status = .pending
        try? modelContext.save()
    }

    /// Drops just the segments (used between runs of `retranscribe`) without
    /// touching audio, edit log, or speaker naming — those stay so label
    /// transfer can still kick in on the new run.
    private func wipeTranscript(in project: TranscriptionProject) {
        for segment in project.segments {
            modelContext.delete(segment)
        }
        project.segments.removeAll()
        try? modelContext.save()
    }

    private func runPipeline(
        for project: TranscriptionProject,
        locale: Locale,
        hints: SupervisionHints?
    ) {
        let projectID = project.id
        guard let url = project.sourceAudioURL else {
            updateJob(projectID) { $0.phase = .failed; $0.errorMessage = "Audio file is no longer accessible." }
            project.status = .failed
            try? modelContext.save()
            return
        }

        // Cancel any in-flight run before kicking off another. Without this,
        // hitting Re-Transcribe twice would race two pipelines on one project.
        tasks[projectID]?.cancel()

        jobs[projectID] = JobState()
        project.status = .transcribing
        try? modelContext.save()

        let pipeline = self.pipeline
        // Hints' speaker count overrides whatever was captured at import time
        // — by the time the user retranscribes, they have a much better idea
        // of how many speakers are actually in the recording.
        let speakerCount = hints?.speakerCount ?? project.expectedSpeakerCount

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let progressHandler: @Sendable (PipelineProgress) -> Void = { progress in
                Task { @MainActor in
                    self?.handleProgress(projectID: projectID, progress: progress)
                }
            }

            do {
                let output = try await pipeline.run(
                    audioURL: url,
                    locale: locale,
                    expectedSpeakerCount: speakerCount,
                    onProgress: progressHandler
                )
                try Task.checkCancellation()
                await self?.finish(
                    projectID: projectID,
                    segments: output.segments,
                    speakerIDs: output.speakerIDs,
                    speakerCentroids: output.speakerCentroids,
                    hints: hints
                )
            } catch is CancellationError {
                return
            } catch {
                await self?.fail(projectID: projectID, error: error)
            }
        }
        tasks[projectID] = task
    }

    /// Splits `segment` into two at `wordIndex` — everything before the index
    /// stays on the original segment; the word at `wordIndex` and everything
    /// after becomes a new segment assigned to a fresh speaker ID so the user
    /// can rename it. No-ops when the index sits at the boundary (nothing to
    /// split) or the segment has no word-level timings.
    @discardableResult
    func splitSegment(
        _ segment: SpeakerSegment,
        atWordIndex wordIndex: Int,
        in project: TranscriptionProject
    ) -> SpeakerSegment? {
        guard wordIndex > 0, wordIndex < segment.words.count else { return nil }

        let firstWords = Array(segment.words.prefix(wordIndex))
        let secondWords = Array(segment.words.suffix(from: wordIndex))
        guard let firstEnd = firstWords.last?.end,
              let secondStart = secondWords.first?.start else { return nil }

        // Snapshot pre-split state so we can rebuild it on undo.
        let originalSegmentID = segment.id
        let previousText = segment.text
        let previousEndSeconds = segment.endSeconds
        let previousWords = segment.words
        let speakerOrderBeforeSplit = project.speakerOrder

        // Bridge the gap between the last word of the first half and the first
        // word of the second half. Splitting at strict word boundaries leaves
        // a tiny dead zone (the natural silence/breath between speakers) where
        // neither segment is "active" — playback highlight drops, scroll
        // pauses, and the audio feels desynced from the transcript. Putting
        // the cut at the midpoint is the conventional approach used by audio
        // annotation tools (Praat, ELAN): each speaker absorbs half of the
        // shared silence, so [first.start, first.end] and [second.start,
        // second.end] are contiguous in playback time.
        let boundary = (firstEnd + secondStart) / 2
        // First half keeps its original startSeconds (preserves any leading
        // silence/intro the diarizer grouped with this turn). The second half
        // inherits the original endSeconds (the trailing silence).
        let originalEnd = segment.endSeconds

        segment.words = firstWords
        segment.text = firstWords.map(\.text).joined(separator: " ")
        // startSeconds intentionally unchanged — keeps any leading silence
        // the diarizer originally grouped with this turn.
        segment.endSeconds = boundary

        let newSpeakerID = nextAvailableSpeakerID(in: project)
        let newSegment = SpeakerSegment(
            startSeconds: boundary,
            endSeconds: originalEnd,
            speakerID: newSpeakerID,
            speakerName: project.displayName(forSpeakerID: newSpeakerID),
            text: secondWords.map(\.text).joined(separator: " "),
            words: secondWords
        )
        newSegment.project = project
        modelContext.insert(newSegment)

        let addedSpeakerID = speakerOrderBeforeSplit.contains(newSpeakerID) ? nil : newSpeakerID
        if let addedSpeakerID {
            project.speakerOrder.append(addedSpeakerID)
        }
        recordEdit(
            .segmentSplit(
                originalSegmentID: originalSegmentID,
                newSegmentID: newSegment.id,
                previousText: previousText,
                previousEndSeconds: previousEndSeconds,
                previousWords: previousWords,
                addedSpeakerID: addedSpeakerID
            ),
            summary: "Split into \(project.displayName(forSpeakerID: newSpeakerID))",
            in: project
        )
        try? modelContext.save()
        return newSegment
    }

    /// Combines two segments into one. The earlier-in-time segment survives
    /// and absorbs the later one — its speaker identity is preserved (the
    /// user can rename afterward if they want a different label). Words and
    /// text are concatenated in time order, and the embedding becomes the
    /// average of the two halves so the merged segment's voice fingerprint
    /// represents the whole turn.
    ///
    /// Returns the surviving segment, or `nil` when the merge is degenerate
    /// (same segment passed twice, or one of them isn't part of the project).
    @discardableResult
    func mergeSegments(
        _ a: SpeakerSegment,
        _ b: SpeakerSegment,
        in project: TranscriptionProject
    ) -> SpeakerSegment? {
        guard a.id != b.id else { return nil }
        guard project.segments.contains(where: { $0.id == a.id }),
              project.segments.contains(where: { $0.id == b.id }) else { return nil }

        let (first, second) = a.startSeconds <= b.startSeconds ? (a, b) : (b, a)

        // Snapshot for undo before any mutation.
        let previousSurvivorText = first.text
        let previousSurvivorEndSeconds = first.endSeconds
        let previousSurvivorWords = first.words
        let previousSurvivorEmbedding = first.embedding
        let absorbedStartSeconds = second.startSeconds
        let absorbedEndSeconds = second.endSeconds
        let absorbedText = second.text
        let absorbedSpeakerID = second.speakerID
        let absorbedSpeakerName = second.speakerName
        let absorbedWords = second.words
        let absorbedEmbedding = second.embedding

        let combinedText: String = {
            if first.text.isEmpty { return second.text }
            if second.text.isEmpty { return first.text }
            return first.text + " " + second.text
        }()

        first.endSeconds = max(first.endSeconds, second.endSeconds)
        first.text = combinedText
        first.words = first.words + second.words
        first.embedding = averagedEmbedding(first.embedding, second.embedding)

        modelContext.delete(second)

        recordEdit(
            .segmentsMerged(
                survivingSegmentID: first.id,
                previousSurvivorText: previousSurvivorText,
                previousSurvivorEndSeconds: previousSurvivorEndSeconds,
                previousSurvivorWords: previousSurvivorWords,
                previousSurvivorEmbedding: previousSurvivorEmbedding,
                absorbedStartSeconds: absorbedStartSeconds,
                absorbedEndSeconds: absorbedEndSeconds,
                absorbedText: absorbedText,
                absorbedSpeakerID: absorbedSpeakerID,
                absorbedSpeakerName: absorbedSpeakerName,
                absorbedWords: absorbedWords,
                absorbedEmbedding: absorbedEmbedding
            ),
            summary: "Merged into \(project.displayName(forSpeakerID: first.speakerID))",
            in: project,
            contextSegmentID: first.id
        )
        try? modelContext.save()
        return first
    }

    /// Element-wise mean of two embeddings. Returns whichever non-empty one
    /// when only one side has data, preserving the surviving segment's
    /// fingerprint when the absorbed side has none.
    private func averagedEmbedding(_ a: [Float], _ b: [Float]) -> [Float] {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        guard a.count == b.count else { return a }
        var out = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count { out[i] = (a[i] + b[i]) / 2 }
        return out
    }

    private func nextAvailableSpeakerID(in project: TranscriptionProject) -> String {
        let taken = Set(project.segments.map(\.speakerID))
        var n = 1
        while taken.contains("Speaker_\(n)") { n += 1 }
        return "Speaker_\(n)"
    }

    // MARK: - Revision history

    /// Records a reversible edit on `project`. Callers fire this after they
    /// mutate the model — the service stores the *previous* state in the
    /// payload, so `undoEdit` can rebuild it later. `contextSegmentID` is the
    /// segment the user was inspecting at the moment of the edit (when one
    /// applies); voice-print enrollment uses it to weight verified segments
    /// over those that inherit a label transitively.
    func recordEdit(
        _ payload: ProjectEditPayload,
        summary: String,
        in project: TranscriptionProject,
        contextSegmentID: UUID? = nil
    ) {
        let edit = ProjectEdit(
            summary: summary,
            payload: payload,
            contextSegmentID: contextSegmentID
        )
        edit.project = project
        modelContext.insert(edit)
        try? modelContext.save()
    }

    /// Undoes the most recent edit on `project`, removing it from the history.
    /// Returns the edit that was undone (for UI feedback) or `nil` when there
    /// is nothing left to undo.
    @discardableResult
    func undoLastEdit(in project: TranscriptionProject) -> ProjectEdit? {
        guard let edit = project.edits.sorted(by: { $0.timestamp > $1.timestamp }).first,
              let payload = edit.payload else { return nil }
        applyInverse(of: payload, in: project)
        modelContext.delete(edit)
        try? modelContext.save()
        return edit
    }

    /// Erases the entire revision history for `project`. The current state is
    /// preserved — only the trail of edits is dropped.
    func clearEditHistory(in project: TranscriptionProject) {
        for edit in project.edits {
            modelContext.delete(edit)
        }
        try? modelContext.save()
    }

    private func applyInverse(of payload: ProjectEditPayload, in project: TranscriptionProject) {
        switch payload {
        case .titleChanged(let previous):
            project.title = previous

        case .speakerNameChanged(let speakerID, let previous):
            if let previous, !previous.isEmpty {
                project.speakerNames[speakerID] = previous
            } else {
                project.speakerNames.removeValue(forKey: speakerID)
            }

        case .labelAdded(let labelID):
            project.labels.removeAll { $0.id == labelID }

        case .labelRemoved(let labelID):
            // Look up the label across the store — it's possible the user
            // re-added it manually in between, in which case we no-op.
            guard !project.labels.contains(where: { $0.id == labelID }) else { return }
            let predicate = #Predicate<ProjectLabel> { $0.id == labelID }
            var descriptor = FetchDescriptor<ProjectLabel>(predicate: predicate)
            descriptor.fetchLimit = 1
            if let label = try? modelContext.fetch(descriptor).first {
                project.labels.append(label)
            }

        case let .segmentSplit(originalSegmentID, newSegmentID, previousText,
                                previousEndSeconds, previousWords, addedSpeakerID):
            guard let original = project.segments.first(where: { $0.id == originalSegmentID }),
                  let new = project.segments.first(where: { $0.id == newSegmentID }) else { return }
            // Restore the merged segment to its pre-split shape.
            original.words = previousWords
            original.text = previousText
            original.endSeconds = previousEndSeconds
            // Drop the spun-off half.
            modelContext.delete(new)
            if let addedSpeakerID {
                project.speakerOrder.removeAll { $0 == addedSpeakerID }
                project.speakerNames.removeValue(forKey: addedSpeakerID)
            }

        case let .segmentsMerged(survivingID, prevSurvivorText, prevSurvivorEnd,
                                  prevSurvivorWords, prevSurvivorEmbedding,
                                  absorbedStart, absorbedEnd, absorbedText,
                                  absorbedSpeakerID, absorbedSpeakerName,
                                  absorbedWords, absorbedEmbedding):
            // Restore the survivor to its pre-merge shape.
            guard let survivor = project.segments.first(where: { $0.id == survivingID }) else { return }
            survivor.endSeconds = prevSurvivorEnd
            survivor.text = prevSurvivorText
            survivor.words = prevSurvivorWords
            survivor.embedding = prevSurvivorEmbedding
            // Recreate the absorbed segment as a fresh row. It gets a new
            // UUID — any other revision-history payloads that referenced the
            // pre-merge id would have been recorded against a segment that
            // existed at the time, so they're unaffected by what we're doing
            // now (their own undo path uses snapshots, not live references).
            let recreated = SpeakerSegment(
                startSeconds: absorbedStart,
                endSeconds: absorbedEnd,
                speakerID: absorbedSpeakerID,
                speakerName: absorbedSpeakerName,
                text: absorbedText,
                words: absorbedWords,
                embedding: absorbedEmbedding
            )
            recreated.project = project
            modelContext.insert(recreated)
        }
    }

    // MARK: - Re-transcription hints

    /// User annotations packaged up for a re-transcription run. Carries the
    /// speaker count (a constraint for VBx clustering) and per-name voice
    /// references (used post-hoc to map new auto-IDs onto user names with
    /// embedding-space matching).
    struct SupervisionHints: Sendable {
        struct NamedRange: Sendable {
            let start: TimeInterval
            let end: TimeInterval
            let displayName: String
        }
        let speakerCount: Int
        let namedRanges: [NamedRange]
        /// Per-display-name reference embedding, built from the *previous*
        /// run's per-segment embeddings averaged over every segment the user
        /// labelled with that name. Empty when no embeddings were captured
        /// (legacy projects). L2-normalized.
        let referenceEmbeddings: [String: [Float]]
    }

    private func supervisionHints(from project: TranscriptionProject) -> SupervisionHints? {
        // We only build hints when the user has actually named speakers —
        // otherwise there's nothing to transfer and the run reduces to a
        // plain re-do.
        let namedSpeakerIDs = project.speakerNames
            .filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            .keys
        let distinctSpeakerIDs = Set(project.segments.map(\.speakerID))
        guard !namedSpeakerIDs.isEmpty else { return nil }

        let namedRanges = project.segments.compactMap { segment -> SupervisionHints.NamedRange? in
            guard let display = project.speakerNames[segment.speakerID]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !display.isEmpty else { return nil }
            return SupervisionHints.NamedRange(
                start: segment.startSeconds,
                end: segment.endSeconds,
                displayName: display
            )
        }

        let referenceEmbeddings = buildReferenceEmbeddings(for: project)

        return SupervisionHints(
            speakerCount: max(distinctSpeakerIDs.count, 1),
            namedRanges: namedRanges,
            referenceEmbeddings: referenceEmbeddings
        )
    }

    /// One labelled segment ready for reference-building, carrying its
    /// embedding and a confidence tier inferred from the edit log.
    private struct LabelledSample {
        let segmentID: UUID
        let embedding: [Float]
        let tier: ConfidenceTier
    }

    /// Builds a per-display-name "voice fingerprint" from the user's labelled
    /// segments, using the revision history to weight high-confidence labels
    /// over those inherited transitively, and dropping outliers that almost
    /// certainly came from a diarizer mistake the user didn't catch.
    ///
    /// Pipeline:
    ///   1. Grade each segment's confidence using the edit log:
    ///      - **Tier A (×3)** — segments that were *split into existence* by
    ///        a `.segmentSplit` edit. The user actively asserted a speaker
    ///        boundary here, so both halves are confidently distinct.
    ///      - **Tier B (×2)** — segments tagged as the *inspection target*
    ///        of a `.speakerNameChanged` edit. The user actually verified
    ///        this turn before committing the new name.
    ///      - **Tier C (×1)** — every other segment that shares the named
    ///        speaker ID. They got the name transitively when the user
    ///        renamed Speaker_N; the diarizer might have misplaced some of
    ///        them and we have no signal that the user verified them.
    ///   2. Compute a weighted mean embedding per name from the unfiltered
    ///      pool, L2-normalize.
    ///   3. Score every segment by cosine similarity to its name's initial
    ///      reference. Drop those below an absolute floor (likely a different
    ///      voice the diarizer mis-clustered) or that fall sharply below the
    ///      group median (one-sigma rule of thumb), but never drop Tier A or
    ///      Tier B segments — those are user-asserted ground truth.
    ///   4. Recompute the final reference from survivors only.
    private func buildReferenceEmbeddings(for project: TranscriptionProject) -> [String: [Float]] {
        let segmentTiers = computeSegmentTiers(for: project)

        // Group labelled segments + their tiers by display name.
        var samplesByName: [String: [LabelledSample]] = [:]
        for segment in project.segments {
            guard !segment.embedding.isEmpty,
                  let display = project.speakerNames[segment.speakerID]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !display.isEmpty else { continue }
            let tier = segmentTiers[segment.id] ?? .transitive
            samplesByName[display, default: []].append(
                LabelledSample(segmentID: segment.id, embedding: segment.embedding, tier: tier)
            )
        }

        var output: [String: [Float]] = [:]
        for (name, samples) in samplesByName {
            // Step 1: initial weighted mean over everything we have.
            guard let initialRef = weightedMean(samples) else { continue }

            // Step 2: outlier filter. Score each sample against the initial
            // reference; drop samples that are near-orthogonal to it
            // (likely a different voice) UNLESS the user explicitly verified
            // them via split or rename inspection.
            let scored = samples.map { sample -> (LabelledSample, Float) in
                (sample, cosineSim(l2Normalize(sample.embedding), initialRef))
            }
            // Use the median similarity of the top-tier samples as a
            // robust center. Falls back to the overall median when no
            // user-verified samples exist.
            let verifiedScores = scored
                .filter { $0.0.tier != .transitive }
                .map(\.1)
            let centerScore = verifiedScores.isEmpty
                ? median(scored.map(\.1))
                : median(verifiedScores)
            // A floor of 0.45 sim means "this sample is at least somewhat
            // pointing the same direction as the rest". Anything below is
            // almost certainly a different speaker.
            let absoluteFloor: Float = 0.45
            // Allow up to 0.15 below the verified center before we discard a
            // transitive sample as an outlier.
            let relativeMargin: Float = 0.15

            let kept = scored.filter { (sample, score) in
                if sample.tier != .transitive { return true } // ground truth — keep
                if score < absoluteFloor { return false }
                if score < centerScore - relativeMargin { return false }
                return true
            }
            .map { $0.0 }

            // Step 3: final reference from survivors. If the filter leaves
            // only ground-truth samples, that's fine — purer is better.
            if let finalRef = weightedMean(kept) {
                output[name] = finalRef
            } else if let finalRef = weightedMean(samples) {
                // Filter killed everything (extremely scattered samples) —
                // fall back to the unfiltered mean rather than no reference.
                output[name] = finalRef
            }
        }
        return output
    }

    /// Confidence tier for a labelled segment, inferred from the edit log.
    private enum ConfidenceTier {
        case split        // Tier A — user asserted a speaker boundary here.
        case inspected    // Tier B — user verified this turn before naming.
        case transitive   // Tier C — name inherited via Speaker_N rename.

        var weight: Float {
            switch self {
            case .split: 3
            case .inspected: 2
            case .transitive: 1
            }
        }
    }

    private func computeSegmentTiers(for project: TranscriptionProject) -> [UUID: ConfidenceTier] {
        var tiers: [UUID: ConfidenceTier] = [:]
        for edit in project.edits {
            switch edit.payload {
            case .segmentSplit(let originalID, let newID, _, _, _, _):
                // Both halves of a split are confidently distinguished — the
                // user did the work of asserting a boundary between them.
                tiers[originalID] = .split
                tiers[newID] = .split
            case .speakerNameChanged:
                if let id = edit.contextSegmentID,
                   tiers[id] != .split {
                    tiers[id] = .inspected
                }
            default:
                continue
            }
        }
        return tiers
    }

    private func weightedMean<S: Sequence>(_ samples: S) -> [Float]?
        where S.Element == LabelledSample
    {
        var sum: [Float] = []
        var weightTotal: Float = 0
        for sample in samples {
            guard !sample.embedding.isEmpty else { continue }
            if sum.isEmpty {
                sum = [Float](repeating: 0, count: sample.embedding.count)
            }
            guard sum.count == sample.embedding.count else { continue }
            let w = sample.tier.weight
            for i in 0..<sample.embedding.count {
                sum[i] += sample.embedding[i] * w
            }
            weightTotal += w
        }
        guard weightTotal > 0, !sum.isEmpty else { return nil }
        let mean = sum.map { $0 / weightTotal }
        return l2Normalize(mean)
    }

    private func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Resolves new-pipeline speaker IDs onto user-named displays using a
    /// two-stage match:
    ///
    ///   1. **Anchor** — for each user-named display, find the new speaker ID
    ///      that has the most cumulative *time-overlap* with the user's
    ///      labelled ranges. That's the "primary" ID for that name.
    ///   2. **Absorb** — for every other new speaker ID, compare its centroid
    ///      embedding to each user-name reference (cosine similarity) and to
    ///      the already-assigned anchors. If it's significantly closer to a
    ///      user reference than the next-best alternative, assign it that
    ///      name. This catches the "diarizer split one person into multiple
    ///      IDs" failure mode — e.g. Alice gets `Speaker_1` for the first
    ///      half of the recording and `Speaker_3` for the second because mic
    ///      distance changed, but both centroids cluster near Alice.
    ///
    /// Falls back to pure overlap when no reference embeddings are available
    /// (legacy projects pre-embedding-storage).
    private func applyLabelTransfer(
        hints: SupervisionHints,
        speakerCentroids: [String: [Float]],
        in project: TranscriptionProject
    ) {
        guard !hints.namedRanges.isEmpty else { return }

        // Per-name overlap totals: [newSpeakerID: [displayName: seconds]].
        var overlapTotals: [String: [String: TimeInterval]] = [:]
        for segment in project.segments {
            for range in hints.namedRanges {
                let overlap = max(0, min(segment.endSeconds, range.end) - max(segment.startSeconds, range.start))
                if overlap > 0 {
                    overlapTotals[segment.speakerID, default: [:]][range.displayName, default: 0] += overlap
                }
            }
        }

        // -- Stage 1: anchor each name to its highest-overlap new ID.
        let minimumOverlapSeconds: TimeInterval = 1.0
        var assignment: [String: String] = [:]   // newSpeakerID -> displayName
        var anchored: Set<String> = []           // names already anchored

        // Sort by descending best-overlap so the most confident anchor locks first.
        let ranked = overlapTotals.compactMap { (speakerID, byName) -> (String, String, TimeInterval)? in
            guard let best = byName.max(by: { $0.value < $1.value }) else { return nil }
            return (speakerID, best.key, best.value)
        }
        .sorted { $0.2 > $1.2 }

        for (speakerID, displayName, overlap) in ranked {
            guard overlap >= minimumOverlapSeconds,
                  !anchored.contains(displayName),
                  assignment[speakerID] == nil else { continue }
            assignment[speakerID] = displayName
            anchored.insert(displayName)
        }

        // -- Stage 2: absorb leftover IDs by embedding similarity.
        //
        // For each unassigned new speakerID, compute cosine similarity of
        // its centroid to every user-name reference. Assign the closest name
        // when it clears two bars: an absolute floor, and a margin over the
        // runner-up. The margin is what guards against false absorbs when
        // two real speakers happen to sound somewhat similar.
        //
        // These thresholds are calibrated for the cleaner references that
        // come out of `buildReferenceEmbeddings` (tier-weighted + outlier
        // filtered). Pre-cleanup we needed 0.5/0.08 to avoid pulling in
        // stray segments into the reference itself; the cleaner refs let us
        // catch genuinely-the-same-voice cases that previously fell short.
        let absorbThreshold: Float = 0.42
        let absorbMargin: Float = 0.05

        let unassignedIDs = Set(project.segments.map(\.speakerID)).subtracting(assignment.keys)
        for newID in unassignedIDs {
            guard let centroid = speakerCentroids[newID], !centroid.isEmpty else { continue }
            let normalizedCentroid = l2Normalize(centroid)

            let scored: [(String, Float)] = hints.referenceEmbeddings
                .map { (name, ref) in (name, cosineSim(normalizedCentroid, ref)) }
                .sorted { $0.1 > $1.1 }

            guard let top = scored.first, top.1 >= absorbThreshold else { continue }
            let runnerUpScore = scored.dropFirst().first?.1 ?? -1
            guard top.1 - runnerUpScore >= absorbMargin else { continue }

            // Absorb — same display can be assigned to multiple new IDs at
            // this stage, intentionally. That's how we re-merge a person the
            // diarizer wrongly split.
            assignment[newID] = top.0
        }

        // Apply assignments via speakerNames so the existing rename machinery
        // (display name resolution, history undo) handles them uniformly.
        for (newID, displayName) in assignment {
            project.speakerNames[newID] = displayName
        }
    }

    // MARK: - Embedding math

    private func l2Normalize(_ vector: [Float]) -> [Float] {
        var sumSq: Float = 0
        for v in vector { sumSq += v * v }
        guard sumSq > 0 else { return vector }
        let scale = 1.0 / sqrtf(sumSq)
        return vector.map { $0 * scale }
    }

    /// Cosine similarity over already-L2-normalized vectors == dot product.
    /// Returns 0 when shapes don't match — safer than crashing on partial
    /// pipeline output.
    private func cosineSim(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot
    }

    /// Cancels any in-flight job for `project` and removes it — including the
    /// sandboxed audio copy — from disk.
    ///
    /// The two batch-delete calls are deliberate: cascade-deleting through
    /// `.cascade` relationships materializes every child. SpeakerSegment's
    /// `words: [WordTiming]` is a Codable array stored as a transformer-
    /// encoded BLOB; if the cascade detaches a segment from its context
    /// before its `words` blob has been faulted in, any subsequent observer
    /// that touches `.words` crashes with "backing data was detached from a
    /// context without resolving attribute faults". The batch-delete API
    /// removes children in-store without ever loading them into memory, so
    /// no observer ever sees a half-detached object.
    func delete(project: TranscriptionProject) {
        let id = project.id
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
        jobs.removeValue(forKey: id)

        try? modelContext.delete(model: SpeakerSegment.self, where: #Predicate { segment in
            segment.project?.id == id
        })
        try? modelContext.delete(model: ProjectEdit.self, where: #Predicate { edit in
            edit.project?.id == id
        })

        if let filename = project.storedAudioFilename {
            AudioStorage.delete(filename: filename)
        }
        modelContext.delete(project)
        try? modelContext.save()
    }

    // MARK: - State transitions

    private func updateJob(_ id: UUID, _ mutate: (inout JobState) -> Void) {
        var state = jobs[id] ?? JobState()
        mutate(&state)
        jobs[id] = state
    }

    private func handleProgress(projectID: UUID, progress: PipelineProgress) {
        updateJob(projectID) { state in
            switch progress {
            case .diarizing(let sub):
                switch sub {
                case .preparingModels, .downloadingModels:
                    state.phase = .preparingDiarizer
                case .analyzing:
                    state.phase = .analyzing
                }
            case .transcribing(let sub):
                switch sub {
                case .checkingSupport, .preparing:
                    if state.phase != .analyzing { state.phase = .preparingTranscriber }
                case .downloadingModel(let fraction):
                    state.phase = .downloadingTranscriberModel
                    state.modelDownloadFraction = fraction
                case .analyzing:
                    state.phase = .analyzing
                }
            case .merging:
                state.phase = .saving
            }
        }
    }

    private func finish(
        projectID: UUID,
        segments: [LabelledSegment],
        speakerIDs: [String],
        speakerCentroids: [String: [Float]] = [:],
        hints: SupervisionHints? = nil
    ) {
        guard let project = fetchProject(projectID) else { return }
        updateJob(projectID) { $0.phase = .saving }

        project.segments.removeAll()
        for labelled in segments {
            let segment = SpeakerSegment(
                startSeconds: labelled.start,
                endSeconds: labelled.end,
                speakerID: labelled.speakerID,
                speakerName: labelled.speakerName,
                text: labelled.text,
                words: labelled.words,
                embedding: labelled.embedding
            )
            segment.project = project
            modelContext.insert(segment)
        }
        project.speakerOrder = speakerIDs
        // Drop any prior naming that doesn't apply to the new speaker IDs —
        // we'll re-seed names from the hints below if available.
        if hints != nil {
            project.speakerNames = project.speakerNames.filter { speakerIDs.contains($0.key) }
        }
        if let hints {
            applyLabelTransfer(
                hints: hints,
                speakerCentroids: speakerCentroids,
                in: project
            )
        }
        project.status = .ready
        try? modelContext.save()
        updateJob(projectID) { $0.phase = .finished }
        tasks.removeValue(forKey: projectID)
    }

    private func fail(projectID: UUID, error: any Error) {
        guard let project = fetchProject(projectID) else { return }
        project.status = .failed
        try? modelContext.save()
        updateJob(projectID) { state in
            state.phase = .failed
            state.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        tasks.removeValue(forKey: projectID)
    }

    private func fetchProject(_ id: UUID) -> TranscriptionProject? {
        let predicate = #Predicate<TranscriptionProject> { $0.id == id }
        var descriptor = FetchDescriptor<TranscriptionProject>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}
