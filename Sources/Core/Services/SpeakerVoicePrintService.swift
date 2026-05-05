import Foundation

/// Read-only voice-print suggestion engine. Sits next to
/// `TranscriptionService` (which owns mutation + centroid maintenance) and
/// reads the persisted `project.speakerCentroids` to surface "this segment
/// sounds more like another speaker" hints in the editor.
///
/// Also drives the mid-segment speaker-change detection flow (Path B): the
/// flag heuristic runs on persisted data, and the on-demand detection
/// re-runs the diarizer on a sliced audio range to find concrete split
/// points.
///
/// All math runs synchronously on the main actor and is cheap — cosine
/// similarity over a 256-D vector against ~2–8 centroids is microseconds.
/// We re-evaluate per render rather than caching; if performance ever
/// becomes an issue with very long transcripts, the caller can hold a
/// per-segment cache invalidated by the centroid dict's identity.
@MainActor
@Observable
final class SpeakerVoicePrintService {

    /// Minimum cosine similarity an alternative speaker's centroid must
    /// reach before we consider it a viable relabel candidate. Below this
    /// floor every speaker looks "kind of similar" and the suggestion is
    /// noise. Calibrated to roughly match the diarizer's own
    /// `absorbThreshold` used during retranscription label transfer.
    private static let candidateFloor: Float = 0.42

    /// How much closer (in cosine space) the alternative centroid must be
    /// vs. the segment's currently-assigned speaker for the suggestion to
    /// surface. The margin is the noise filter: small differences would
    /// flap across rerenders as centroids shift, which would feel like a
    /// nag. 0.05 catches genuine mismatches without firing on borderline
    /// segments.
    private static let suggestionMargin: Float = 0.05

    /// How close (in cosine space) the *current* and the next-best
    /// alternative centroid have to be for us to suspect the segment
    /// contains both speakers. The signal is "the embedding is pulled
    /// roughly equally between two centroids," which usually means
    /// the underlying audio is mixed.
    private static let mixedAmbiguityWindow: Float = 0.08

    /// Floor the alternative centroid must clear before we believe the
    /// "ambiguous" reading. Without this, segments where every centroid
    /// is in the noise band would always look ambiguous.
    private static let mixedAlternativeFloor: Float = 0.30

    /// Minimum segment duration before we'll even consider running the
    /// mid-segment detector. Sub-second turns aren't going to contain
    /// multiple distinct voices worth splitting.
    private static let mixedMinDurationSeconds: TimeInterval = 4.0

    /// Minimum word count for the same reason — short utterances don't
    /// have enough word boundaries for a meaningful split point anyway.
    private static let mixedMinWordCount: Int = 8

    /// Diarizer used for on-demand sub-segment detection. Shared with the
    /// main `TranscriptionService`; loading happens lazily inside the
    /// underlying `OfflineDiarizerManager` per call.
    private let diarizer: any Diarizer

    init(diarizer: any Diarizer = FluidAudioDiarizer()) {
        self.diarizer = diarizer
    }

    // MARK: - Public types

    /// Suggestion the editor renders next to a segment when the centroid
    /// for another speaker is meaningfully closer than the segment's
    /// currently-assigned speaker.
    struct RelabelSuggestion: Equatable {
        let suggestedSpeakerID: String
        let suggestedDisplayName: String
        /// Cosine similarity to the *current* speaker's centroid — useful
        /// for tooltips ("currently 0.71 vs. suggested 0.83").
        let currentSimilarity: Float
        /// Cosine similarity to the suggested speaker's centroid.
        let suggestedSimilarity: Float
    }

    /// One detected speaker change inside a segment. Identified by the word
    /// index *before which* a split should be inserted; the suggested
    /// speaker is the project speaker that the audio after the split point
    /// most closely resembles. Carries a confidence score (cosine similarity
    /// to the matched centroid) for transparency.
    struct SplitCandidate: Equatable, Identifiable {
        let id = UUID()
        let beforeWordIndex: Int
        let suggestedSpeakerID: String
        let suggestedDisplayName: String
        let confidence: Float

        static func == (lhs: SplitCandidate, rhs: SplitCandidate) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// Lifecycle of a sub-segment detection request. Stored per-segment so
    /// the row can show a spinner / results / error state while the diarizer
    /// is working.
    enum DetectionState: Equatable {
        case running
        case results([SplitCandidate])
        case noChangesFound
        case failed(String)
    }

    /// In-memory per-segment cache. Cleared on app relaunch — re-running
    /// detection is cheap from the user's perspective (one click) and the
    /// results don't need to survive a process restart.
    private(set) var detectionResults: [UUID: DetectionState] = [:]

    // MARK: - Phase 2: relabel suggestion

    /// Returns a relabel suggestion for `segment` when the project's
    /// centroids point at a different speaker more confidently than the
    /// segment's current assignment. Returns `nil` for legacy segments
    /// (no embedding), single-speaker projects, segments the user already
    /// dismissed, and segments where the current label is already the
    /// closest centroid.
    func suggestion(
        for segment: SpeakerSegment,
        in project: TranscriptionProject
    ) -> RelabelSuggestion? {
        guard !segment.embedding.isEmpty else { return nil }
        guard !project.dismissedRelabelSuggestions.contains(segment.id) else { return nil }
        guard project.speakerCentroids.count >= 2 else { return nil }

        let queryNormalized = Self.l2Normalize(segment.embedding)
        var currentSimilarity: Float = -1
        var bestAlternative: (id: String, sim: Float)? = nil

        for (speakerID, centroid) in project.speakerCentroids {
            guard centroid.count == queryNormalized.count else { continue }
            let sim = Self.dot(queryNormalized, centroid)
            if speakerID == segment.speakerID {
                currentSimilarity = sim
            } else if bestAlternative == nil || sim > bestAlternative!.sim {
                bestAlternative = (speakerID, sim)
            }
        }

        guard let alternative = bestAlternative else { return nil }
        guard alternative.sim >= Self.candidateFloor else { return nil }
        guard alternative.sim - currentSimilarity >= Self.suggestionMargin else { return nil }

        return RelabelSuggestion(
            suggestedSpeakerID: alternative.id,
            suggestedDisplayName: project.displayName(forSpeakerID: alternative.id),
            currentSimilarity: currentSimilarity,
            suggestedSimilarity: alternative.sim
        )
    }

    // MARK: - Path B: mid-segment speaker-change flag

    /// True when this segment is a plausible candidate for *containing*
    /// multiple speakers — long enough for a swap to make sense, with a
    /// whole-segment embedding that sits roughly equally between two
    /// project centroids (unlike `suggestion`, which fires when the
    /// centroid clearly favors a different speaker).
    ///
    /// Returns `false` when the user already resolved or dismissed
    /// detection on this segment, or when a relabel suggestion is taking
    /// priority — those resolve the ambiguity in their own way.
    func mixedSpeakerCandidate(
        for segment: SpeakerSegment,
        in project: TranscriptionProject
    ) -> Bool {
        guard !project.checkedMixedSpeakerSegments.contains(segment.id) else { return false }
        // Don't compete with a clear relabel suggestion — handle that first.
        guard suggestion(for: segment, in: project) == nil else { return false }

        let duration = segment.endSeconds - segment.startSeconds
        guard duration >= Self.mixedMinDurationSeconds else { return false }
        guard segment.words.count >= Self.mixedMinWordCount else { return false }
        guard !segment.embedding.isEmpty else { return false }
        guard project.speakerCentroids.count >= 2 else { return false }

        let queryNormalized = Self.l2Normalize(segment.embedding)
        var currentSimilarity: Float = -1
        var bestAlternative: Float = -1

        for (speakerID, centroid) in project.speakerCentroids {
            guard centroid.count == queryNormalized.count else { continue }
            let sim = Self.dot(queryNormalized, centroid)
            if speakerID == segment.speakerID {
                currentSimilarity = sim
            } else if sim > bestAlternative {
                bestAlternative = sim
            }
        }

        guard bestAlternative >= Self.mixedAlternativeFloor else { return false }
        return abs(bestAlternative - currentSimilarity) < Self.mixedAmbiguityWindow
    }

    /// Reads the cached detection state for a segment. `nil` means the
    /// user hasn't run detection on this segment yet (or the cache was
    /// cleared by an app restart).
    func detectionState(for segmentID: UUID) -> DetectionState? {
        detectionResults[segmentID]
    }

    /// Discards the cached detection state for a segment (e.g. when the
    /// user dismisses results or after an accept that splits the segment).
    func clearDetectionState(for segmentID: UUID) {
        detectionResults.removeValue(forKey: segmentID)
    }

    /// Removes a single split candidate from the cached results — used when
    /// the user dismisses one inline marker but wants to keep evaluating
    /// the others. If the list ends up empty we collapse to
    /// `.noChangesFound` so the UI stops showing markers.
    func dismissCandidate(_ candidate: SplitCandidate, for segmentID: UUID) {
        guard case .results(let candidates) = detectionResults[segmentID] else { return }
        let remaining = candidates.filter { $0.id != candidate.id }
        detectionResults[segmentID] = remaining.isEmpty ? .noChangesFound : .results(remaining)
    }

    /// Runs the diarizer on the segment's audio range and computes
    /// candidate split points by mapping each fine-grained sub-speaker
    /// back to the closest project speaker via centroid cosine similarity.
    /// State updates flow through `detectionResults` so observing views
    /// re-render automatically.
    ///
    /// Implementation notes worth knowing:
    ///  * The diarizer pipeline loads CoreML models on every call (no
    ///    public model-cache hook), so each detection takes a few seconds
    ///    to spin up before the actual analysis. The button doc-string
    ///    in the editor warns the user.
    ///  * We constrain the sub-run to `expectedSpeakerCount: 2` — the
    ///    parent segment was assigned one speaker; we're checking whether
    ///    a second one is hiding inside. Three-way mixes inside a single
    ///    segment are rare and easier to handle by re-running detection
    ///    on the resulting halves.
    ///  * Sub-speakers that don't map cleanly to any project speaker are
    ///    skipped — surfacing "Unknown speaker?" markers without an
    ///    actionable next step would be clutter.
    func detectSpeakerChanges(
        for segment: SpeakerSegment,
        in project: TranscriptionProject
    ) async {
        let segmentID = segment.id
        guard let audioURL = project.sourceAudioURL else {
            detectionResults[segmentID] = .failed("Project audio is unavailable.")
            return
        }
        let segmentStart = segment.startSeconds
        let segmentEnd = segment.endSeconds
        let segmentDuration = segmentEnd - segmentStart
        guard segmentDuration >= 1.0 else {
            detectionResults[segmentID] = .noChangesFound
            return
        }
        let currentSpeakerID = segment.speakerID
        // Snapshot word timings + centroids on the main actor before
        // dispatching — `SpeakerSegment` and `TranscriptionProject` are
        // SwiftData @Model types and aren't `Sendable`.
        let words = segment.words
        let projectCentroids = project.speakerCentroids

        detectionResults[segmentID] = .running

        let diarizer = self.diarizer
        do {
            let slicedURL = try await TranscriptEditing.extractAudioRange(
                from: audioURL,
                start: segmentStart,
                end: segmentEnd
            )
            defer { try? FileManager.default.removeItem(at: slicedURL) }

            let output = try await diarizer.diarize(
                audioURL: slicedURL,
                expectedSpeakerCount: 2,
                onProgress: { _ in }
            )

            // Times in `output.segments` are relative to the *sliced* audio
            // (start at 0). Translate them back to project time before we
            // use them — though for word-boundary mapping we'll convert
            // back into segment-relative time anyway.
            let candidates = Self.computeSplitCandidates(
                subSegments: output.segments,
                subCentroids: output.speakerCentroids,
                projectCentroids: projectCentroids,
                segmentStart: segmentStart,
                currentSpeakerID: currentSpeakerID,
                segmentWords: words
            )
            // The detached worker only knows the suggested *speakerID* — the
            // user-facing display name is project-bound metadata that lives
            // on the main actor, so resolve it here before publishing.
            let resolved: [SplitCandidate] = candidates.map { c in
                SplitCandidate(
                    beforeWordIndex: c.beforeWordIndex,
                    suggestedSpeakerID: c.suggestedSpeakerID,
                    suggestedDisplayName: project.displayName(forSpeakerID: c.suggestedSpeakerID),
                    confidence: c.confidence
                )
            }

            if resolved.isEmpty {
                detectionResults[segmentID] = .noChangesFound
            } else {
                detectionResults[segmentID] = .results(resolved)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            detectionResults[segmentID] = .failed(message)
        }
    }

    // MARK: - Pure helpers

    /// Walks the diarizer's sub-segments in time order, maps each to the
    /// closest project speaker via centroid cosine similarity, and emits
    /// a candidate at every transition where the mapped speaker differs
    /// from the segment's currently-assigned one.
    nonisolated private static func computeSplitCandidates(
        subSegments: [DiarizedSegment],
        subCentroids: [String: [Float]],
        projectCentroids: [String: [Float]],
        segmentStart: TimeInterval,
        currentSpeakerID: String,
        segmentWords: [WordTiming]
    ) -> [(beforeWordIndex: Int, suggestedSpeakerID: String, confidence: Float)] {
        guard !subSegments.isEmpty, !segmentWords.isEmpty else { return [] }
        // Pre-normalize project centroids once so each lookup is a dot product.
        let normalizedProject = projectCentroids.compactMapValues { centroid -> [Float]? in
            guard !centroid.isEmpty else { return nil }
            return l2Normalize(centroid)
        }
        guard !normalizedProject.isEmpty else { return [] }

        // For each sub-segment, decide which project speaker its embedding
        // most resembles. We prefer the per-segment embedding from the sub-
        // run; if it's missing we fall back to the sub-run's centroid for
        // that anonymous ID.
        struct SubAssignment {
            let start: TimeInterval
            let end: TimeInterval
            let projectSpeakerID: String?
            let confidence: Float
        }
        var assignments: [SubAssignment] = []
        for sub in subSegments {
            let queryRaw: [Float]
            if !sub.embedding.isEmpty {
                queryRaw = sub.embedding
            } else if let centroid = subCentroids[sub.speakerID], !centroid.isEmpty {
                queryRaw = centroid
            } else {
                continue
            }
            let query = l2Normalize(queryRaw)
            var best: (String, Float)? = nil
            for (speakerID, centroid) in normalizedProject {
                let sim = dot(query, centroid)
                if best == nil || sim > best!.1 {
                    best = (speakerID, sim)
                }
            }
            // 0.40 floor: roughly the diarizer's "this is the same voice"
            // threshold during retranscription. Below that, we don't trust
            // the mapping enough to suggest a split.
            let mapped = (best?.1 ?? 0) >= 0.40 ? best?.0 : nil
            assignments.append(SubAssignment(
                start: sub.start + segmentStart,
                end: sub.end + segmentStart,
                projectSpeakerID: mapped,
                confidence: best?.1 ?? 0
            ))
        }

        // Walk the assignments in time order, emit a candidate whenever the
        // mapped speaker differs from `currentSpeakerID`. We collapse runs
        // of the same speaker so a long Speaker-B stretch produces one
        // candidate at its leading edge, not one per sub-segment.
        var candidates: [(Int, String, Float)] = []
        var lastSpeaker: String? = currentSpeakerID
        for assignment in assignments {
            guard let mapped = assignment.projectSpeakerID else { continue }
            if mapped != lastSpeaker {
                if let wordIndex = nearestWordBoundary(
                    after: assignment.start,
                    in: segmentWords
                ), wordIndex > 0, wordIndex < segmentWords.count {
                    candidates.append((wordIndex, mapped, assignment.confidence))
                }
                lastSpeaker = mapped
            }
        }
        // Deduplicate by word index — multiple sub-segments rounding to the
        // same boundary should fold into one marker.
        var seen = Set<Int>()
        return candidates.filter { tuple in
            if seen.contains(tuple.0) { return false }
            seen.insert(tuple.0)
            return true
        }.map { tuple in
            (beforeWordIndex: tuple.0, suggestedSpeakerID: tuple.1, confidence: tuple.2)
        }
    }

    /// Picks the index of the first word whose start time is >= `time`.
    /// Returns nil if `time` is past the last word.
    nonisolated private static func nearestWordBoundary(
        after time: TimeInterval,
        in words: [WordTiming]
    ) -> Int? {
        for (index, word) in words.enumerated() where word.start >= time {
            return index
        }
        return nil
    }

    // MARK: - Math helpers

    /// L2-normalizes a vector so that cosine similarity collapses to a
    /// straight dot product downstream. Mirrors the convention the
    /// transcription pipeline uses for its reference embeddings.
    nonisolated private static func l2Normalize(_ vector: [Float]) -> [Float] {
        var sumSq: Float = 0
        for v in vector { sumSq += v * v }
        guard sumSq > 0 else { return vector }
        let scale = 1.0 / sqrtf(sumSq)
        return vector.map { $0 * scale }
    }

    /// Dot product, used in place of cosine similarity when both inputs
    /// are already L2-normalized.
    nonisolated private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in 0..<a.count { sum += a[i] * b[i] }
        return sum
    }
}
