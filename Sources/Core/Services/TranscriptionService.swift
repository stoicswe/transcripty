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
    private let verifier: AlignmentVerificationService
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Per-project debounced auto-recompute task. A flurry of edits within
    /// the debounce window collapses into one recompute pass at the end.
    private var pendingAutoRecompute: [UUID: Task<Void, Never>] = [:]
    /// Long-lived background-healer task. Non-nil only while the user has
    /// the toggle on in Preferences; nil otherwise so it doesn't burn CPU
    /// on by-default behavior.
    private var backgroundHealer: Task<Void, Never>?

    init(
        modelContext: ModelContext,
        transcriber: any Transcriber = AppleSpeechTranscriber(),
        diarizer: any Diarizer = FluidAudioDiarizer(),
        verifier: AlignmentVerificationService = AlignmentVerificationService()
    ) {
        self.modelContext = modelContext
        self.pipeline = TranscriptionPipeline(transcriber: transcriber, diarizer: diarizer)
        self.verifier = verifier
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
        guard !segment.isNonSpeech else { return nil }
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

        // Pick the most likely speaker for the split-off half. In a 2-speaker
        // project that's the other speaker; in a multi-speaker project it's
        // the closest neighbor's speaker (the diarizer typically fuses a turn
        // when the speaker swap is brief). Only when no plausible existing
        // speaker exists do we mint a new one — that covers single-speaker
        // projects or genuine new-voice cases.
        let newSpeakerID = suggestedSpeakerIDForSplit(
            parent: segment,
            in: project
        ) ?? nextAvailableSpeakerID(in: project)
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
        // No auto-recompute on split: both halves preserve their original
        // ASR-produced word timings (already in project-absolute time).
        // The split only redraws segment boundaries, it doesn't change
        // when individual words are spoken — running ASR again on a short
        // post-split slice produces *worse* timings than the originals
        // because Apple's recognizer is unreliable on very short audio.
        try? modelContext.save()
        recomputeSpeakerCentroids(in: project)
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
        // Music / silence blocks never merge with speech turns — that
        // would smear word timings back across the gap we just isolated.
        guard !a.isNonSpeech, !b.isNonSpeech else { return nil }
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
        // No auto-recompute on merge: words from both halves carry their
        // original ASR-produced project-time timings, and concatenating
        // the lists preserves them. Re-running ASR on the merged span
        // would be redundant at best and risk worse alignment at worst.
        try? modelContext.save()
        recomputeSpeakerCentroids(in: project)
        return first
    }

    /// Removes a segment outright. Records the segment's full state in the
    /// revision history so undo can recreate it (the recreated segment
    /// gets a fresh UUID; that's fine because no live payloads outlive
    /// this call still pointing at the old one). Triggers a centroid
    /// recompute since the speaker landscape changed.
    func deleteSegment(
        _ segment: SpeakerSegment,
        in project: TranscriptionProject
    ) {
        guard project.segments.contains(where: { $0.id == segment.id }) else { return }
        let summary = "Deleted segment from \(project.displayName(forSpeakerID: segment.speakerID))"
        recordEdit(
            .segmentDeleted(
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                speakerID: segment.speakerID,
                speakerName: segment.speakerName,
                text: segment.text,
                words: segment.words,
                embedding: segment.embedding,
                wasEdited: segment.wasEdited
            ),
            summary: summary,
            in: project
        )
        // Drop the relabel-dismissal hint and the mixed-speaker checked
        // marker — both keyed by the about-to-be-deleted segment ID and
        // serve no purpose post-delete.
        project.dismissedRelabelSuggestions.removeAll { $0 == segment.id }
        project.checkedMixedSpeakerSegments.removeAll { $0 == segment.id }
        modelContext.delete(segment)
        try? modelContext.save()
        recomputeSpeakerCentroids(in: project)
    }

    /// Reassigns a segment to a different existing speaker. Records the
    /// previous identity in the revision history so undo can restore it,
    /// clears any prior dismissal feedback for this segment (so the user's
    /// new pick is what trains the centroids next), and kicks a centroid
    /// recompute so the inline suggestion engine reflects the change.
    /// No-ops when `newSpeakerID` matches the current assignment.
    @discardableResult
    func relabelSegment(
        _ segment: SpeakerSegment,
        toSpeakerID newSpeakerID: String,
        in project: TranscriptionProject
    ) -> Bool {
        guard project.segments.contains(where: { $0.id == segment.id }) else { return false }
        guard segment.speakerID != newSpeakerID else { return false }
        let previousSpeakerID = segment.speakerID
        let previousSpeakerName = segment.speakerName
        let newDisplayName = project.displayName(forSpeakerID: newSpeakerID)

        segment.speakerID = newSpeakerID
        segment.speakerName = newDisplayName
        // A confirmed dismissal would have biased the centroid for the
        // *old* speaker; the user's reassignment overrules that, so clear
        // it before recomputing.
        project.dismissedRelabelSuggestions.removeAll { $0 == segment.id }

        recordEdit(
            .segmentSpeakerChanged(
                segmentID: segment.id,
                previousSpeakerID: previousSpeakerID,
                previousSpeakerName: previousSpeakerName
            ),
            summary: "Reassigned segment to \(newDisplayName)",
            in: project,
            contextSegmentID: segment.id
        )
        try? modelContext.save()
        recomputeSpeakerCentroids(in: project)
        return true
    }

    /// Accepts a mid-segment speaker-change candidate from the inline
    /// detector: splits the parent segment at the candidate's word index
    /// and relabels the resulting *second half* to the suggested speaker.
    /// Returns the new (second-half) segment, or `nil` when the split or
    /// relabel can't be applied.
    ///
    /// Why split-then-relabel-the-second-half: the candidate's
    /// `beforeWordIndex` marks where the *new* speaker starts speaking, so
    /// after the split the second half is the new-speaker territory. The
    /// existing `splitSegment` machinery handles the cut + records an
    /// undoable `.segmentSplit` edit; we then call `relabelSegment` on
    /// the new segment to set the suggested speaker, which records its own
    /// undoable `.segmentSpeakerChanged` edit. Two separate edits in the
    /// history is intentional — the user can undo the relabel without
    /// reverting the split if they decide the cut was right but the label
    /// wasn't.
    @discardableResult
    func acceptSpeakerChangeCandidate(
        wordIndex: Int,
        suggestedSpeakerID: String,
        in segment: SpeakerSegment,
        in project: TranscriptionProject
    ) -> SpeakerSegment? {
        guard let newSegment = splitSegment(segment, atWordIndex: wordIndex, in: project) else {
            return nil
        }
        // splitSegment already auto-suggests a speaker for the new half via
        // adjacency heuristics; if it picked something other than what
        // the voice-print detection indicates, override it.
        if newSegment.speakerID != suggestedSpeakerID {
            relabelSegment(newSegment, toSpeakerID: suggestedSpeakerID, in: project)
        }
        return newSegment
    }

    /// Records that the user explicitly confirmed a segment's current
    /// speaker label despite the suggestion engine flagging it for relabel.
    /// Stops the suggestion from re-appearing for that segment, and the
    /// next centroid recompute weights this segment 2× toward its current
    /// speaker — pulling the centroid toward a known-good example, which
    /// tightens classifications on the *other* segments. Idempotent.
    func dismissRelabelSuggestion(
        for segment: SpeakerSegment,
        in project: TranscriptionProject
    ) {
        guard project.segments.contains(where: { $0.id == segment.id }) else { return }
        if !project.dismissedRelabelSuggestions.contains(segment.id) {
            project.dismissedRelabelSuggestions.append(segment.id)
        }
        try? modelContext.save()
        recomputeSpeakerCentroids(in: project)
    }

    /// Restores `segment.words` to the snapshot the verifier captured the
    /// first time it ran on this segment — useful when a recompute pass
    /// produced worse alignment than the original recognizer output. The
    /// snapshot itself is left in place so the user can restore again
    /// after a future bad recompute. No-op when no snapshot exists yet.
    @discardableResult
    func restoreOriginalWordTimings(
        for segment: SpeakerSegment,
        in project: TranscriptionProject
    ) -> Bool {
        guard let original = segment.originalWords, !original.isEmpty else { return false }
        let previousWords = segment.words
        let previousWasEdited = segment.wasEdited
        segment.words = original
        segment.wasEdited = false
        segment.lastTimingsRecomputeAt = nil
        recordEdit(
            .textChanged(
                segmentID: segment.id,
                previousText: segment.text,
                previousWords: previousWords,
                previousWasEdited: previousWasEdited
            ),
            summary: "Restored original word timings",
            in: project,
            contextSegmentID: segment.id
        )
        try? modelContext.save()
        return true
    }

    // MARK: - Non-speech (music / long silence) blocks

    /// Marker text used by every non-speech segment. The editor renders
    /// these rows with an animated music-note view rather than the text,
    /// so the literal value is mostly load-bearing for the plain-text
    /// export path; using a recognizable bracket-marker keeps exports
    /// readable.
    static let nonSpeechMarker: String = "[MUSIC]"

    /// Default minimum gap length (in seconds) before a non-speech stretch
    /// gets its own block. Three seconds is long enough that the diarizer
    /// would never have called it part of one speaker turn anyway, and
    /// short enough to catch typical interludes like intros or stingers.
    /// Anything shorter is a normal between-speaker pause and stays
    /// implicit in the segment boundary.
    static let nonSpeechGapThresholdSeconds: TimeInterval = 3.0

    /// Inserts a non-speech ("[MUSIC]") block for every gap between
    /// chronologically-adjacent speech segments that exceeds
    /// `gapThreshold`. Idempotent: a gap already filled by an existing
    /// non-speech segment is skipped, so the same project can be
    /// re-detected without producing duplicates.
    ///
    /// We don't trim adjacent speech segments here — their existing word
    /// timings are usually accurate, and shrinking the segment bounds
    /// would risk dropping legitimate trailing/leading speech. The block
    /// itself is enough to fix the user-visible "click first word after
    /// music, audio is mis-anchored" symptom because the post-music
    /// segment's `startSeconds` is preserved while the prior segment's
    /// trailing silence/music stops being considered part of *that* turn.
    @discardableResult
    func detectAndInsertNonSpeechBlocks(
        in project: TranscriptionProject,
        gapThreshold: TimeInterval = TranscriptionService.nonSpeechGapThresholdSeconds
    ) -> Int {
        let ordered = project.segments.sorted { $0.startSeconds < $1.startSeconds }
        guard ordered.count >= 2 else { return 0 }
        var inserted = 0
        for index in 0..<(ordered.count - 1) {
            let earlier = ordered[index]
            let later = ordered[index + 1]
            // Skip if either bookend is itself non-speech — the gap is
            // already accounted for by the existing non-speech row.
            if earlier.isNonSpeech || later.isNonSpeech { continue }
            let gapStart = earlier.endSeconds
            let gapEnd = later.startSeconds
            let gap = gapEnd - gapStart
            guard gap >= gapThreshold else { continue }
            let block = SpeakerSegment(
                startSeconds: gapStart,
                endSeconds: gapEnd,
                speakerID: "_nonspeech",
                speakerName: "",
                text: Self.nonSpeechMarker
            )
            block.isNonSpeech = true
            block.project = project
            modelContext.insert(block)
            inserted += 1
        }
        if inserted > 0 {
            try? modelContext.save()
        }
        return inserted
    }

    /// Suppresses the "may contain multiple speakers" flag for a segment.
    /// Called both when the user dismisses the flag without running
    /// detection ("don't ask again") and after a successful detection
    /// settles — once the user has seen the result, re-flagging would be
    /// nagging. Idempotent.
    func markMixedSpeakerSegmentChecked(
        _ segment: SpeakerSegment,
        in project: TranscriptionProject
    ) {
        guard project.segments.contains(where: { $0.id == segment.id }) else { return }
        if !project.checkedMixedSpeakerSegments.contains(segment.id) {
            project.checkedMixedSpeakerSegments.append(segment.id)
        }
        try? modelContext.save()
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

    /// Best guess for which existing speaker the split-off half belongs to.
    /// Returns `nil` when no existing speaker is a plausible candidate (e.g.
    /// single-speaker project) — callers should mint a new speaker in that
    /// case.
    ///
    /// Ranking, in order:
    /// 1. Two-speaker project: the *other* speaker. Trivially correct.
    /// 2. Multi-speaker: the speaker of the segment immediately following the
    ///    parent, then the segment immediately preceding it. Diarizers fuse a
    ///    turn most often when the swap is brief, so the bordering speaker is
    ///    typically the one bleeding into the parent.
    /// 3. Falls back to whichever non-parent speaker has the most segments
    ///    project-wide — the dominant other voice is the safest default in a
    ///    crowded conversation.
    ///
    /// We deliberately avoid embedding-similarity ranking here: the parent's
    /// stored embedding is computed across the whole turn, so when half of it
    /// is actually a different speaker the embedding is a mix and similarity
    /// to centroids is biased. Adjacency is a stronger signal until we extract
    /// per-slice embeddings (planned alongside per-project speaker learning).
    private func suggestedSpeakerIDForSplit(
        parent: SpeakerSegment,
        in project: TranscriptionProject
    ) -> String? {
        let parentSpeakerID = parent.speakerID
        // Non-speech rows aren't valid candidates — their `_nonspeech`
        // speakerID would otherwise leak into the suggestion ranking.
        let allSegments = project.segments
            .filter { !$0.isNonSpeech }
            .sorted { $0.startSeconds < $1.startSeconds }
        let candidateIDs = Set(allSegments.map(\.speakerID)).subtracting([parentSpeakerID])
        guard !candidateIDs.isEmpty else { return nil }
        if candidateIDs.count == 1 { return candidateIDs.first }

        if let parentIndex = allSegments.firstIndex(where: { $0.id == parent.id }) {
            let nextSpeaker = allSegments
                .dropFirst(parentIndex + 1)
                .first(where: { $0.speakerID != parentSpeakerID })?
                .speakerID
            if let nextSpeaker, candidateIDs.contains(nextSpeaker) {
                return nextSpeaker
            }
            let prevSpeaker = allSegments
                .prefix(parentIndex)
                .reversed()
                .first(where: { $0.speakerID != parentSpeakerID })?
                .speakerID
            if let prevSpeaker, candidateIDs.contains(prevSpeaker) {
                return prevSpeaker
            }
        }

        let counts = Dictionary(grouping: allSegments, by: \.speakerID).mapValues(\.count)
        return candidateIDs.max(by: { (counts[$0] ?? 0) < (counts[$1] ?? 0) })
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
        // Most edit kinds change which segments belong to which speaker, so
        // a centroid recompute keeps the suggestion engine honest. Cheap
        // when the centroids are stable (same numbers fall out the math).
        recomputeSpeakerCentroids(in: project)
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

        case let .textChanged(segmentID, previousText, previousWords, previousWasEdited):
            guard let segment = project.segments.first(where: { $0.id == segmentID }) else { return }
            segment.text = previousText
            segment.words = previousWords
            segment.wasEdited = previousWasEdited

        case let .segmentSpeakerChanged(segmentID, previousSpeakerID, previousSpeakerName):
            guard let segment = project.segments.first(where: { $0.id == segmentID }) else { return }
            segment.speakerID = previousSpeakerID
            segment.speakerName = previousSpeakerName
            // The redo state may have stamped this segment as user-confirmed
            // when the relabel happened; clearing it lets the suggestion
            // engine re-evaluate after the undo lands.
            project.dismissedRelabelSuggestions.removeAll { $0 == segmentID }

        case let .segmentDeleted(startSeconds, endSeconds, speakerID, speakerName,
                                  text, words, embedding, wasEdited):
            let recreated = SpeakerSegment(
                startSeconds: startSeconds,
                endSeconds: endSeconds,
                speakerID: speakerID,
                speakerName: speakerName,
                text: text,
                words: words,
                embedding: embedding
            )
            recreated.wasEdited = wasEdited
            recreated.project = project
            modelContext.insert(recreated)

        case let .wordsMoved(sourceID, targetID, _,
                              srcText, srcWords, srcStart, srcEnd,
                              tgtText, tgtWords, tgtStart, tgtEnd, _):
            guard let source = project.segments.first(where: { $0.id == sourceID }),
                  let target = project.segments.first(where: { $0.id == targetID }) else { return }
            source.text = srcText
            source.words = srcWords
            source.startSeconds = srcStart
            source.endSeconds = srcEnd
            target.text = tgtText
            target.words = tgtWords
            target.startSeconds = tgtStart
            target.endSeconds = tgtEnd
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

    // MARK: - Speaker centroid maintenance

    /// Recomputes `project.speakerCentroids` from the current segment
    /// embeddings. Called after every speaker-affecting edit (split, merge,
    /// word move, relabel, dismiss-relabel) so the editor's suggestion
    /// engine always works against fresh data.
    ///
    /// Math: each speaker's centroid is the L2-normalized mean of its
    /// segments' embeddings, with segments the user has explicitly
    /// confirmed (via dismissed-suggestion feedback) counted at 2× weight.
    /// Doubling the weight pulls the centroid toward known-good examples,
    /// which tightens classifications going forward.
    ///
    /// Snapshots the embeddings on the main actor before doing the math —
    /// SwiftData `@Model` values aren't `Sendable`, so we can't carry them
    /// across actors. The math itself is dispatched to a utility-priority
    /// detached task so long transcripts don't stall the UI; the result
    /// is written back on the main actor.
    func recomputeSpeakerCentroids(in project: TranscriptionProject) {
        let dismissed = Set(project.dismissedRelabelSuggestions)
        let samples: [(speakerID: String, embedding: [Float], weight: Float)] =
            project.segments.compactMap { segment in
                guard !segment.embedding.isEmpty else { return nil }
                let weight: Float = dismissed.contains(segment.id) ? 2.0 : 1.0
                return (segment.speakerID, segment.embedding, weight)
            }
        let projectID = project.id
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let centroids = Self.computeWeightedCentroids(from: samples)
            await MainActor.run {
                guard let project = self.fetchProject(projectID) else { return }
                project.speakerCentroids = centroids
                try? self.modelContext.save()
            }
        }
    }

    /// Pure function: groups samples by speakerID, computes the L2-
    /// normalized weighted mean of each group's embeddings. `nonisolated`
    /// so `Task.detached` can call it without crossing the main-actor
    /// boundary on the inputs (which are plain `Sendable` tuples).
    nonisolated private static func computeWeightedCentroids(
        from samples: [(speakerID: String, embedding: [Float], weight: Float)]
    ) -> [String: [Float]] {
        var sums: [String: [Float]] = [:]
        var totals: [String: Float] = [:]
        for sample in samples {
            let dim = sample.embedding.count
            if sums[sample.speakerID] == nil {
                sums[sample.speakerID] = [Float](repeating: 0, count: dim)
            }
            guard sums[sample.speakerID]?.count == dim else { continue }
            for i in 0..<dim {
                sums[sample.speakerID]![i] += sample.embedding[i] * sample.weight
            }
            totals[sample.speakerID, default: 0] += sample.weight
        }
        var out: [String: [Float]] = [:]
        for (speakerID, sum) in sums {
            guard let total = totals[speakerID], total > 0 else { continue }
            var mean = sum.map { $0 / total }
            // L2-normalize so cosine sim against incoming embeddings is a
            // straight dot product — same convention used by the diarizer's
            // reference embeddings elsewhere in this service.
            var sumSq: Float = 0
            for v in mean { sumSq += v * v }
            if sumSq > 0 {
                let scale = 1.0 / sqrtf(sumSq)
                for i in 0..<mean.count { mean[i] *= scale }
            }
            out[speakerID] = mean
        }
        return out
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

    // MARK: - Inline text editing

    /// Replaces a segment's transcript text with the user's edit and rebuilds
    /// its word-level timings via LCS-based reconciliation. Words that the
    /// user kept unchanged keep their original (model-provided) timings;
    /// inserted/changed words get evenly interpolated estimates between the
    /// nearest matched neighbors. The segment is flagged `wasEdited` so the
    /// editor surfaces the "Recompute Timings" affordance until the user
    /// asks for a forced-alignment pass.
    /// Pure-text substitution paths (find/replace, censor, replace-with) are
    /// passed `markEdited: false` so the change doesn't flip the segment's
    /// `wasEdited` flag — recomputing timings can't help when the audio
    /// underneath still says the *original* word, only when the user typed
    /// something the recognizer might align differently. The default `true`
    /// preserves the inline-editor and re-import flows.
    @discardableResult
    func applyTextEdit(
        to segment: SpeakerSegment,
        newText: String,
        in project: TranscriptionProject,
        markEdited: Bool = true,
        // Internal escape hatch: explicit non-speech edits would corrupt
        // the [MUSIC] marker and break the row's visual treatment.
        // The editor never invokes the text-editor on these rows, but the
        // guard makes the contract explicit at the service boundary.
        _ allowNonSpeech: Bool = false
    ) -> Bool {
        if segment.isNonSpeech, !allowNonSpeech { return false }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != segment.text else { return false }
        let newTokens = TranscriptEditing.tokenize(trimmed)

        // Snapshot pre-edit state so the revision history can undo this
        // change verbatim — not just the text, but the (possibly model-
        // produced) word timings + the wasEdited flag, since the act of
        // editing flips that flag and undoing should flip it back.
        let previousText = segment.text
        let previousWords = segment.words
        let previousWasEdited = segment.wasEdited

        if newTokens.isEmpty {
            // The user emptied the segment. Keep the row as a placeholder
            // rather than deleting it so they can recover by typing again;
            // surrounding playback timings stay intact.
            segment.words = []
            segment.text = ""
        } else {
            let reconciled = TranscriptEditing.reconcileWords(
                oldWords: segment.words,
                newTokens: newTokens,
                segmentStart: segment.startSeconds,
                segmentEnd: segment.endSeconds
            )
            segment.text = trimmed
            segment.words = reconciled
        }
        if markEdited {
            segment.wasEdited = true
        }

        recordEdit(
            .textChanged(
                segmentID: segment.id,
                previousText: previousText,
                previousWords: previousWords,
                previousWasEdited: previousWasEdited
            ),
            summary: editSummary(previous: previousText, current: trimmed),
            in: project,
            contextSegmentID: segment.id
        )
        try? modelContext.save()
        if markEdited {
            scheduleAutoRecompute(in: project)
        }
        return true
    }

    // MARK: - Transcript text re-import

    struct TranscriptImportSummary: Sendable {
        let updatedSegmentCount: Int
        let unchangedSegmentCount: Int
        let importedSegmentCount: Int
        let projectSegmentCount: Int

        var skippedSegmentCount: Int {
            max(0, projectSegmentCount - importedSegmentCount)
        }

        var extraSegmentCount: Int {
            max(0, importedSegmentCount - projectSegmentCount)
        }
    }

    /// Reads a plain-text transcript exported from this app and applies the
    /// per-segment text differences as inline edits — each one a discrete
    /// revision-history entry, so the reimport can be undone segment-by-
    /// segment if needed. Segments are matched by chronological order; the
    /// shorter of the two sides bounds how many get compared, and the user
    /// is told about any mismatch in the returned summary.
    @discardableResult
    func reimportTranscriptText(
        from sourceURL: URL,
        into project: TranscriptionProject
    ) throws -> TranscriptImportSummary {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let raw = try String(contentsOf: sourceURL, encoding: .utf8)
        let imported = TranscriptTextImporter.parse(raw)
        let ordered = project.segments.sorted { $0.startSeconds < $1.startSeconds }
        let comparable = min(imported.count, ordered.count)

        var updated = 0
        var unchanged = 0
        for i in 0..<comparable {
            let segment = ordered[i]
            let newText = imported[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
            let oldText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if newText == oldText {
                unchanged += 1
                continue
            }
            let didApply = applyTextEdit(to: segment, newText: newText, in: project)
            if didApply {
                updated += 1
            } else {
                unchanged += 1
            }
        }

        return TranscriptImportSummary(
            updatedSegmentCount: updated,
            unchangedSegmentCount: unchanged,
            importedSegmentCount: imported.count,
            projectSegmentCount: ordered.count
        )
    }

    enum MergeDirection {
        case previous
        case next
    }

    /// Moves a contiguous run of words from `segment` into the chronologically-
    /// adjacent segment in `direction`. The run must form a clean prefix
    /// (`direction == .previous`) or suffix (`direction == .next`) of
    /// `segment.words` — moving a slice from the middle would leave the
    /// segment with disconnected text.
    ///
    /// On success the words land at the *end* of the previous segment or the
    /// *start* of the next segment, both segments' text/start/end re-derive
    /// from the new word lists, and the move is recorded as a single undo-
    /// able edit in the revision history.
    @discardableResult
    func moveWords(
        from segment: SpeakerSegment,
        wordRange: Range<Int>,
        direction: MergeDirection,
        in project: TranscriptionProject
    ) -> Bool {
        guard !segment.isNonSpeech else { return false }
        guard !wordRange.isEmpty,
              wordRange.lowerBound >= 0,
              wordRange.upperBound <= segment.words.count else { return false }

        let isPrefix = wordRange.lowerBound == 0
        let isSuffix = wordRange.upperBound == segment.words.count
        switch direction {
        case .previous:
            guard isPrefix else { return false }
        case .next:
            guard isSuffix else { return false }
        }

        // Find the chronological neighbor.
        let ordered = project.segments.sorted { $0.startSeconds < $1.startSeconds }
        guard let currentIdx = ordered.firstIndex(where: { $0.id == segment.id }) else { return false }
        let neighborIndex: Int
        switch direction {
        case .previous: neighborIndex = currentIdx - 1
        case .next: neighborIndex = currentIdx + 1
        }
        guard neighborIndex >= 0, neighborIndex < ordered.count else { return false }
        let neighbor = ordered[neighborIndex]
        let movedWords = Array(segment.words[wordRange])
        guard !movedWords.isEmpty else { return false }

        // Snapshot pre-state for undo.
        let srcText = segment.text
        let srcWords = segment.words
        let srcStart = segment.startSeconds
        let srcEnd = segment.endSeconds
        let tgtText = neighbor.text
        let tgtWords = neighbor.words
        let tgtStart = neighbor.startSeconds
        let tgtEnd = neighbor.endSeconds

        // Apply the move.
        switch direction {
        case .previous:
            neighbor.words = neighbor.words + movedWords
            segment.words.removeSubrange(wordRange)
            // Source's startSeconds shifts to the new first word's start.
            // Target's endSeconds stretches to cover the appended words.
            if let firstRemaining = segment.words.first {
                segment.startSeconds = firstRemaining.start
            }
            if let lastMoved = movedWords.last {
                neighbor.endSeconds = max(neighbor.endSeconds, lastMoved.end)
            }
        case .next:
            neighbor.words = movedWords + neighbor.words
            segment.words.removeSubrange(wordRange)
            // Source's endSeconds shrinks to the new last word's end.
            // Target's startSeconds extends backward to cover the prepended.
            if let lastRemaining = segment.words.last {
                segment.endSeconds = lastRemaining.end
            }
            if let firstMoved = movedWords.first {
                neighbor.startSeconds = min(neighbor.startSeconds, firstMoved.start)
            }
        }

        // Re-derive plain text from the new word lists.
        segment.text = segment.words.map(\.text).joined(separator: " ")
        neighbor.text = neighbor.words.map(\.text).joined(separator: " ")

        recordEdit(
            .wordsMoved(
                sourceSegmentID: segment.id,
                targetSegmentID: neighbor.id,
                movedWords: movedWords,
                sourcePreviousText: srcText,
                sourcePreviousWords: srcWords,
                sourcePreviousStartSeconds: srcStart,
                sourcePreviousEndSeconds: srcEnd,
                targetPreviousText: tgtText,
                targetPreviousWords: tgtWords,
                targetPreviousStartSeconds: tgtStart,
                targetPreviousEndSeconds: tgtEnd,
                movedToPrefix: direction == .next
            ),
            summary: moveSummary(
                count: movedWords.count,
                direction: direction,
                neighbor: neighbor,
                project: project
            ),
            in: project,
            contextSegmentID: neighbor.id
        )
        // No auto-recompute on word-move: the moved words carry their
        // original project-time timings and the destination segment just
        // appends them — re-running ASR on the new boundary would risk
        // overwriting good timings with worse ones.
        try? modelContext.save()
        recomputeSpeakerCentroids(in: project)
        return true
    }

    private func moveSummary(
        count: Int,
        direction: MergeDirection,
        neighbor: SpeakerSegment,
        project: TranscriptionProject
    ) -> String {
        let target = project.displayName(forSpeakerID: neighbor.speakerID)
        let plural = count == 1 ? "word" : "words"
        switch direction {
        case .previous: return "Moved \(count) \(plural) to \(target) (previous)"
        case .next:     return "Moved \(count) \(plural) to \(target) (next)"
        }
    }

    /// One-line description for the revision-history list. Picks the first
    /// few words of the new text — enough to recognize *which* segment was
    /// edited at a glance.
    private func editSummary(previous: String, current: String) -> String {
        let trimmedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCurrent.isEmpty {
            return "Cleared segment text"
        }
        let tokens = trimmedCurrent.split(whereSeparator: { $0.isWhitespace })
        let preview = tokens.prefix(6).joined(separator: " ")
        let suffix = tokens.count > 6 ? "…" : ""
        return "Edited text — \"\(preview)\(suffix)\""
    }

    /// True when at least one segment carries the `wasEdited` flag — i.e.
    /// the user has made manual text edits since the last forced-alignment
    /// pass. The editor uses this to decide whether to show the recompute
    /// popup.
    func projectNeedsTimingRecompute(_ project: TranscriptionProject) -> Bool {
        project.segments.contains(where: { $0.wasEdited })
    }

    // MARK: - Auto-recompute scheduling (Option A)

    /// Debounced background recompute trigger. Called after every edit
    /// that affects word boundaries (text edit, split, merge, word move).
    /// A burst of edits collapses into a single recompute pass at the end
    /// of the debounce window — that's what makes the playback timings
    /// "self-heal" without the user clicking the badge or button.
    ///
    /// Failure is silent: the manual button + the floating badge stay
    /// available as fallbacks. The whole point of A is for the *common*
    /// case to just work; if it can't (audio missing, recognizer fails),
    /// the explicit affordances pick up the slack.
    func scheduleAutoRecompute(in project: TranscriptionProject) {
        let projectID = project.id
        pendingAutoRecompute[projectID]?.cancel()
        pendingAutoRecompute[projectID] = Task { @MainActor [weak self] in
            // 800 ms is long enough to coalesce a typing flurry into one
            // pass, short enough that the highlight refreshes before the
            // user has scrolled away mentally.
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard let project = self.fetchProject(projectID) else { return }
            do {
                try await self.recomputeTimings(for: project)
            } catch {
                // Silent — the user can still trigger via the manual paths.
            }
            self.pendingAutoRecompute.removeValue(forKey: projectID)
        }
    }

    // MARK: - Drift detection on segment activation (Option B)

    /// Called by the editor whenever the active playback segment changes.
    /// Schedules an auto-recompute only when the segment is *already*
    /// flagged `wasEdited` — i.e. a text edit set the flag and the
    /// debounced auto-recompute either hasn't run yet or got dropped.
    /// This is purely a safety net; the primary auto-recompute trigger
    /// is the text-edit hook itself.
    ///
    /// We deliberately do NOT use a pathology heuristic to second-guess
    /// the recognizer's original timings here. Earlier versions of this
    /// method tried to guess whether word-duration distributions "looked
    /// suspect" and proactively rescheduled recomputes — which caused
    /// timings to silently shift under the user as they clicked around
    /// the transcript. Real ASR produces short-duration words for
    /// fillers all the time; that's not a defect to fix automatically.
    /// The user has explicit affordances ("Recompute Word Timings",
    /// "Restore Original Word Timings") for the genuinely-broken cases.
    func scheduleDriftRecomputeIfNeeded(
        for segment: SpeakerSegment,
        in project: TranscriptionProject
    ) {
        guard !segment.isNonSpeech else { return }
        guard !segment.words.isEmpty else { return }
        guard segment.wasEdited else { return }
        scheduleAutoRecompute(in: project)
    }

    // MARK: - Idle-time background healer (Option C, opt-in)

    /// Toggle the always-on idle-time recompute pass. When enabled, a
    /// long-lived task walks the project store and re-aligns the oldest-
    /// validated segments one at a time, with sleeps between so it never
    /// competes with active user work. Off by default; the user opts in
    /// from the "Word Timings" pane in Preferences.
    func setBackgroundHealingEnabled(_ enabled: Bool) {
        if enabled {
            guard backgroundHealer == nil else { return }
            backgroundHealer = Task { @MainActor [weak self] in
                await self?.runBackgroundHealerLoop()
            }
        } else {
            backgroundHealer?.cancel()
            backgroundHealer = nil
        }
    }

    /// The healer's main loop. Picks one stale segment per pass, processes
    /// it, sleeps. The 60-second sleep between segments is intentional:
    /// it keeps the heat budget effectively zero on idle machines, and
    /// even a 1000-segment project gets fully validated in under a day
    /// of background time. Pauses entirely when any active job (initial
    /// transcription or user-triggered recompute) is in flight.
    private func runBackgroundHealerLoop() async {
        while !Task.isCancelled {
            // Sleep first so cancellation is responsive on toggle-off.
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }

            // Defer if any active user work is running — don't compete.
            let hasActiveJob = jobs.values.contains(where: {
                $0.phase != .finished && $0.phase != .failed
            })
            if hasActiveJob { continue }
            if !pendingAutoRecompute.isEmpty { continue }

            // Pick the oldest-validated segment across all projects. Nil
            // `lastTimingsRecomputeAt` sorts first so never-validated
            // segments get attention before stale-but-validated ones.
            guard let target = oldestStaleSegment() else { continue }
            guard let project = target.project else { continue }
            target.wasEdited = true
            try? modelContext.save()
            do {
                try await recomputeTimings(for: project)
            } catch {
                // Silent — try again next loop iteration on a different segment.
            }
        }
    }

    /// Finds the single most-stale segment in the model store: never-
    /// validated segments first, then the longest-since-validated one.
    /// `nil` when nothing exists or every segment is fresh.
    private func oldestStaleSegment() -> SpeakerSegment? {
        let descriptor = FetchDescriptor<SpeakerSegment>()
        guard let allSegments = try? modelContext.fetch(descriptor) else { return nil }
        // Skip empty-word segments (legacy / cleared) and non-speech
        // ([MUSIC]) blocks — recompute can't help when there's nothing
        // to align.
        let candidates = allSegments.filter { !$0.words.isEmpty && !$0.isNonSpeech }
        guard !candidates.isEmpty else { return nil }
        return candidates.min { lhs, rhs in
            switch (lhs.lastTimingsRecomputeAt, rhs.lastTimingsRecomputeAt) {
            case (nil, nil): return false
            case (nil, _): return true        // nil sorts first
            case (_, nil): return false
            case (let l?, let r?): return l < r
            }
        }
    }

    /// Re-extracts each segment's audio range, re-runs the speech recognizer
    /// on it, and rewrites the segment's word timings against the freshly
    /// aligned output. The user's segment *text* is authoritative — when
    /// the recognizer's transcript differs (because we re-typed it), LCS
    /// picks the matched words and interpolates the rest.
    ///
    /// `includeAll` controls scope:
    ///  * `false` (default) — only segments flagged `wasEdited` get a pass.
    ///    Keeps the floating "Recompute Timings" badge cheap (it only
    ///    appears after edits).
    ///  * `true` — every segment is re-aligned. Used by the manual
    ///    "Recompute Word Timings" button in Transcription Settings, for
    ///    when the user feels playback is drifting even though no edits
    ///    are flagged.
    @MainActor
    func recomputeTimings(
        for project: TranscriptionProject,
        locale: Locale = .current,
        includeAll: Bool = false,
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async throws {
        guard let audioURL = project.sourceAudioURL else {
            throw TranscriptEditing.RecomputeError.sourceUnavailable
        }
        let editedSegments = project.segments
            .filter { !$0.isNonSpeech && (includeAll || $0.wasEdited) }
            .sorted { $0.startSeconds < $1.startSeconds }
        guard !editedSegments.isEmpty else { return }

        let transcriber = AppleSpeechTranscriber()
        let total = Double(editedSegments.count)

        for (index, segment) in editedSegments.enumerated() {
            onProgress(Double(index) / total)

            // Pad each side a hair so the recognizer has a moment to settle —
            // 100 ms of leading/trailing context noticeably reduces clipped
            // edges, and the offset math below subtracts the lead back out.
            let leadPad: TimeInterval = 0.1
            let trailPad: TimeInterval = 0.1
            let extractStart = max(0, segment.startSeconds - leadPad)
            let extractEnd = segment.endSeconds + trailPad

            let extracted: URL
            do {
                extracted = try await TranscriptEditing.extractAudioRange(
                    from: audioURL,
                    start: extractStart,
                    end: extractEnd
                )
            } catch {
                // Segment-level failure shouldn't abort the whole recompute.
                continue
            }
            defer { try? FileManager.default.removeItem(at: extracted) }

            let recognized: [TranscribedSegment]
            do {
                recognized = try await transcriber.transcribe(
                    audioURL: extracted,
                    locale: locale,
                    onProgress: { _ in }
                )
            } catch {
                continue
            }
            let recognizedWords = recognized.flatMap(\.words)

            let aligned = await verifier.verifyTimings(
                slicedAudioURL: extracted,
                sliceLeadOffset: extractStart,
                userTokens: segment.words.map(\.text),
                recognizedWords: recognizedWords,
                segmentStart: segment.startSeconds,
                segmentEnd: segment.endSeconds
            )
            guard let aligned else {
                continue
            }
            // First-ever recompute on this segment? Snapshot the original
            // recognizer-produced word timings before we overwrite, so the
            // user can roll back per-segment if a verification pass ever
            // produces worse results.
            if segment.originalWords == nil {
                segment.originalWords = segment.words
            }
            segment.words = aligned
            segment.wasEdited = false
            segment.lastTimingsRecomputeAt = .now
            try? modelContext.save()
        }
        onProgress(1.0)
    }

    // MARK: - Project archive

    /// Exports `project` to a single-file `.tscripty` archive (a flat ZIP of
    /// the JSON manifest and the original audio). Throws when the project's
    /// audio is no longer accessible or the archive write fails.
    func exportArchive(project: TranscriptionProject, to destinationURL: URL) async throws {
        try await ProjectArchive.export(project: project, to: destinationURL)
    }

    /// Imports a `.tscripty` archive into a freshly-created project. Returns
    /// the new project's id so the caller can navigate to it. The archive's
    /// segment, label, and edit IDs are preserved; the project itself gets a
    /// new UUID and a fresh stored-audio filename, so importing the same
    /// archive twice produces two distinct projects without conflicts.
    @discardableResult
    func importArchive(from sourceURL: URL) async throws -> UUID {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let loaded = try await ProjectArchive.load(from: sourceURL)
        return try await materialize(loaded: loaded)
    }

    @MainActor
    private func materialize(loaded: ProjectArchive.LoadedArchive) async throws -> UUID {
        let manifest = loaded.manifest
        let project = TranscriptionProject(title: manifest.project.title)
        project.createdAt = manifest.project.createdAt
        project.expectedSpeakerCount = manifest.project.expectedSpeakerCount
        project.speakerOrder = manifest.project.speakerOrder
        project.speakerNames = manifest.project.speakerNames
        project.status = .ready

        // Lay the audio down inside the sandbox under the new project's id,
        // mirroring what AudioStorage.importAudio would have done at fresh-
        // import time. Without this the project would have no playable audio.
        let ext = (manifest.audioFilename as NSString).pathExtension
        let storedFilename = ext.isEmpty
            ? project.id.uuidString
            : "\(project.id.uuidString).\(ext)"
        let audioDir = try AudioStorage.audioDirectory()
        let audioDestination = audioDir.appendingPathComponent(storedFilename)
        try? FileManager.default.removeItem(at: audioDestination)
        try loaded.audioData.write(to: audioDestination, options: .atomic)
        project.storedAudioFilename = storedFilename

        modelContext.insert(project)

        // Reuse existing labels by name so importing doesn't duplicate the
        // recipient's labels. Anything that doesn't match gets created with
        // the archive's color so the visual identity carries over.
        let existingLabels = (try? modelContext.fetch(FetchDescriptor<ProjectLabel>())) ?? []
        let existingByName: [String: ProjectLabel] = Dictionary(
            existingLabels.map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var attachedLabels: [ProjectLabel] = []
        for record in manifest.labels {
            if let existing = existingByName[record.name.lowercased()] {
                attachedLabels.append(existing)
            } else {
                let label = ProjectLabel(name: record.name, colorHex: record.colorHex)
                modelContext.insert(label)
                attachedLabels.append(label)
            }
        }
        project.labels = attachedLabels

        for record in manifest.segments {
            let segment = SpeakerSegment(
                startSeconds: record.startSeconds,
                endSeconds: record.endSeconds,
                speakerID: record.speakerID,
                speakerName: record.speakerName,
                text: record.text,
                words: record.words,
                embedding: record.embedding
            )
            // Preserve the archive's segment id so any client tooling that
            // referenced segments by id continues to resolve.
            segment.id = record.id
            segment.project = project
            modelContext.insert(segment)
        }

        try modelContext.save()
        return project.id
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
        // Persist the diarizer's per-speaker centroids so the editor can
        // surface relabel suggestions from this point forward. Filter to the
        // speaker IDs that actually survived the run — any stale centroids
        // from a pre-retranscribe state would point at speakers that no
        // longer exist. Retranscribe also drops dismissed relabel hints
        // since the segment IDs are about to be regenerated.
        project.speakerCentroids = speakerCentroids.filter { speakerIDs.contains($0.key) }
        project.dismissedRelabelSuggestions = []
        project.status = .ready
        try? modelContext.save()
        // Once segments are persisted, scan for long non-speech gaps
        // (typically music interludes) and drop a [MUSIC] block in each.
        // This anchors the post-gap speech segment's timings against
        // the actual speech edge instead of bleeding across the gap.
        detectAndInsertNonSpeechBlocks(in: project)
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
