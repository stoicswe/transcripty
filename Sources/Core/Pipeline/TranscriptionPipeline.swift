import Foundation

enum PipelineProgress: Sendable {
    case diarizing(DiarizerProgress)
    case transcribing(TranscriberProgress)
    case merging
}

/// Speaker-labelled transcription segment as a plain value type.
/// The service layer turns these into persisted `SpeakerSegment` records.
struct LabelledSegment: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let speakerID: String
    let speakerName: String
    let text: String
    let words: [WordTiming]
    /// Diarizer-provided 256-D voice embedding for this segment (when one is
    /// available). Persisted so future re-transcription runs can build user-
    /// labelled reference centroids without recomputing embeddings.
    let embedding: [Float]
}

/// Runs diarization + transcription concurrently, then merges the two timelines
/// so every transcription segment is labelled with a speaker ID.
struct TranscriptionPipeline {
    let transcriber: any Transcriber
    let diarizer: any Diarizer

    struct Output: Sendable {
        let segments: [LabelledSegment]
        let speakerIDs: [String]
        /// Per-speakerID voice centroid in WeSpeaker space, when available.
        /// Used by the service layer for embedding-based label transfer on
        /// re-transcription.
        let speakerCentroids: [String: [Float]]
    }

    func run(
        audioURL: URL,
        locale: Locale = .current,
        expectedSpeakerCount: Int? = nil,
        onProgress: @escaping @Sendable (PipelineProgress) -> Void = { _ in }
    ) async throws -> Output {
        // Always normalize the input to mono 16 kHz int16 WAV before the
        // models touch it — this is the format both FluidAudio and Apple's
        // SpeechTranscriber want natively, so standardizing here means stereo
        // 48 kHz, MP3, FLAC, AAC, etc. all run through the same code path.
        // Playback in the editor uses the untouched source either way.
        let enhancedURL = try? await AudioEnhancer.enhance(sourceURL: audioURL)
        let workingURL = enhancedURL ?? audioURL
        defer {
            if let enhancedURL { try? FileManager.default.removeItem(at: enhancedURL) }
        }

        let (diarOutput, transSegments): (DiarizationOutput, [TranscribedSegment])
        do {
            async let diar = runDiarization(audioURL: workingURL,
                                             expectedSpeakerCount: expectedSpeakerCount,
                                             onProgress: onProgress)
            async let trans = runTranscription(audioURL: workingURL, locale: locale, onProgress: onProgress)
            (diarOutput, transSegments) = try await (diar, trans)
        } catch {
            // If the normalized copy tripped a model on the way in, fall back
            // to the original audio rather than failing the whole run. The
            // original is what playback uses anyway, so a recovered run still
            // lines up with the editor timeline.
            if enhancedURL != nil {
                async let diar = runDiarization(audioURL: audioURL,
                                                 expectedSpeakerCount: expectedSpeakerCount,
                                                 onProgress: onProgress)
                async let trans = runTranscription(audioURL: audioURL, locale: locale, onProgress: onProgress)
                (diarOutput, transSegments) = try await (diar, trans)
            } else {
                throw error
            }
        }

        onProgress(.merging)
        let merged = merge(diarization: diarOutput.segments, transcription: transSegments)
        let speakerIDs = orderedUniqueSpeakerIDs(from: diarOutput.segments, fallback: merged)
        return Output(
            segments: merged,
            speakerIDs: speakerIDs,
            speakerCentroids: diarOutput.speakerCentroids
        )
    }

    // MARK: - Sub-tasks

    private func runDiarization(
        audioURL: URL,
        expectedSpeakerCount: Int?,
        onProgress: @escaping @Sendable (PipelineProgress) -> Void
    ) async throws -> DiarizationOutput {
        try await diarizer.diarize(
            audioURL: audioURL,
            expectedSpeakerCount: expectedSpeakerCount,
            onProgress: { sub in onProgress(.diarizing(sub)) }
        )
    }

    private func runTranscription(
        audioURL: URL,
        locale: Locale,
        onProgress: @escaping @Sendable (PipelineProgress) -> Void
    ) async throws -> [TranscribedSegment] {
        try await transcriber.transcribe(
            audioURL: audioURL,
            locale: locale,
            onProgress: { sub in onProgress(.transcribing(sub)) }
        )
    }

    // MARK: - Merge logic

    /// Max total duration of a mis-attributed run that gets reassigned to
    /// the surrounding speaker. A *run* (one or more consecutive same-speaker
    /// words) sandwiched between two same-other-speaker neighbors is treated
    /// as diarizer flicker when its total duration stays under this bound.
    /// 0.8s comfortably covers one-word fillers and two-syllable backchannels
    /// ("uh-huh", "right"), but is short enough to not collapse real turns.
    private static let flickerRunMaxDuration: TimeInterval = 0.8

    /// Assigns a speaker to every *word* (not every transcription segment) by
    /// looking up which diarization speaker overlaps the word's time range the
    /// most. Consecutive same-speaker words are then grouped into one block.
    ///
    /// This is finer-grained than segment-level assignment: when Apple groups
    /// "A talks… B interjects… A continues" into a single utterance, the
    /// previous approach labelled the whole thing as A (majority overlap).
    /// Per-word assignment lets B's interjection stand out as its own block.
    private struct TimedWord {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var speakerID: String
    }

    private func merge(diarization: [DiarizedSegment],
                       transcription: [TranscribedSegment]) -> [LabelledSegment] {
        var timed: [TimedWord] = []
        for ts in transcription {
            // Fallback for segments with no word-level timing: treat the
            // whole segment as a single "word" so the rest of the pipeline
            // still works.
            let words = ts.words.isEmpty
                ? [WordTiming(start: ts.start, end: ts.end, text: ts.text)]
                : ts.words
            for w in words {
                let speakerID = bestSpeakerID(start: w.start, end: w.end, in: diarization) ?? "S1"
                timed.append(TimedWord(start: w.start, end: w.end, text: w.text, speakerID: speakerID))
            }
        }
        timed.sort { $0.start < $1.start }
        smoothFlicker(&timed)
        refineBoundariesUsingText(&timed)

        var blocks: [LabelledSegment] = []
        for w in timed {
            let wordTiming = WordTiming(start: w.start, end: w.end, text: w.text)
            if let last = blocks.last, last.speakerID == w.speakerID {
                let joinedText = last.text.isEmpty ? w.text : last.text + " " + w.text
                blocks[blocks.count - 1] = LabelledSegment(
                    start: last.start,
                    end: max(last.end, w.end),
                    speakerID: last.speakerID,
                    speakerName: last.speakerName,
                    text: joinedText,
                    words: last.words + [wordTiming],
                    embedding: last.embedding
                )
            } else {
                // Attach the embedding from whichever diarized turn this
                // block sits inside, so each persisted segment carries voice
                // data we can match against on a future re-run.
                let embedding = bestEmbedding(start: w.start, end: w.end, in: diarization)
                blocks.append(LabelledSegment(
                    start: w.start,
                    end: w.end,
                    speakerID: w.speakerID,
                    speakerName: defaultName(for: w.speakerID),
                    text: w.text,
                    words: [wordTiming],
                    embedding: embedding
                ))
            }
        }
        return blocks
    }

    private func bestEmbedding(start: TimeInterval,
                                end: TimeInterval,
                                in diarization: [DiarizedSegment]) -> [Float] {
        guard !diarization.isEmpty else { return [] }
        var best: (overlap: TimeInterval, embedding: [Float])? = nil
        for d in diarization {
            let overlap = max(0, min(end, d.end) - max(start, d.start))
            guard overlap > 0, !d.embedding.isEmpty else { continue }
            if best == nil || overlap > best!.overlap {
                best = (overlap, d.embedding)
            }
        }
        return best?.embedding ?? []
    }

    /// Words that conventionally open a new turn in conversational speech.
    /// When one of these appears as the first word of a new speaker's run, the
    /// diarizer's boundary is almost certainly correctly placed — these are
    /// what people say *as they take the floor*. We use the inverse signal
    /// too: when the diarizer puts a boundary in the middle of a sentence
    /// without a turn-opener at the new side, it's probably misplaced.
    /// Lower-cased, punctuation-stripped before comparison.
    private static let turnOpeners: Set<String> = [
        "yeah", "yes", "no", "okay", "ok", "well", "so", "but",
        "right", "alright", "actually", "exactly", "uh-huh", "uhhuh",
        "mhm", "mm-hmm", "huh", "oh"
    ]

    /// Slides speaker boundaries to nearby sentence ends when the diarizer
    /// places them mid-sentence. The heuristic is conservative: the diarizer
    /// is the source of truth for *who*; punctuation only refines *exactly
    /// where* its boundary lands.
    ///
    /// Specifically: when a speaker change happens between consecutive words
    /// `prev` and `curr`, we check whether the cut is linguistically
    /// well-anchored — `prev` ending a sentence, or `curr` being a turn-
    /// opener like "yeah" or "so". If neither, we look 1–2 words ahead in
    /// `curr`'s run for a sentence-ending word; if the audio span between
    /// the original cut and that sentence end is short enough to plausibly
    /// be a one-word diarizer slip (< 1.5 s), we reassign those words back
    /// to `prev`'s speaker so the sentence completes with its actual author.
    ///
    /// This also helps the user's split UX: cuts now naturally land at
    /// sentence boundaries, so the speaker rows read as complete thoughts
    /// instead of split-mid-clause.
    private func refineBoundariesUsingText(_ words: inout [TimedWord]) {
        guard words.count >= 2 else { return }
        let maxShiftSeconds: TimeInterval = 1.5
        let lookahead = 2

        var i = 1
        while i < words.count {
            guard words[i].speakerID != words[i - 1].speakerID else {
                i += 1
                continue
            }

            let prev = words[i - 1]
            let curr = words[i]

            if endsSentence(prev.text) || isTurnOpener(curr.text) {
                // Boundary is linguistically anchored — leave it alone.
                i += 1
                continue
            }

            // Search forward (still inside curr's run) for the next sentence
            // end. If we find one within `lookahead` words AND the audio span
            // is short, reassign those words to prev so the sentence ends
            // with its real author.
            var sentEndAt: Int? = nil
            var k = i
            var steps = 0
            while k < words.count, words[k].speakerID == curr.speakerID, steps <= lookahead {
                if endsSentence(words[k].text) {
                    sentEndAt = k
                    break
                }
                k += 1
                steps += 1
            }

            if let sentEndAt {
                let span = words[sentEndAt].end - words[i].start
                if span < maxShiftSeconds {
                    for j in i...sentEndAt {
                        words[j].speakerID = prev.speakerID
                    }
                    i = sentEndAt + 1
                    continue
                }
            }

            i += 1
        }
    }

    private func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return last == "." || last == "?" || last == "!"
    }

    private func isTurnOpener(_ text: String) -> Bool {
        let cleaned = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters)
        return Self.turnOpeners.contains(cleaned)
    }

    /// Rewrites any *run* of same-speaker words whose total duration stays
    /// under `flickerRunMaxDuration` when both surrounding neighbors belong
    /// to the same other speaker. This generalises single-word flicker
    /// cleanup to short bursts (e.g. two-word backchannels) that would
    /// otherwise split a real monologue into three blocks.
    private func smoothFlicker(_ words: inout [TimedWord]) {
        guard words.count >= 3 else { return }
        var i = 0
        while i < words.count {
            let runSpeaker = words[i].speakerID
            var j = i + 1
            while j < words.count, words[j].speakerID == runSpeaker { j += 1 }

            if i > 0, j < words.count {
                let prev = words[i - 1].speakerID
                let next = words[j].speakerID
                let runDuration = words[j - 1].end - words[i].start
                if prev == next,
                   prev != runSpeaker,
                   runDuration < Self.flickerRunMaxDuration {
                    for k in i..<j {
                        words[k].speakerID = prev
                    }
                }
            }
            i = j
        }
    }

    private func bestSpeakerID(start: TimeInterval,
                               end: TimeInterval,
                               in diarization: [DiarizedSegment]) -> String? {
        guard !diarization.isEmpty else { return nil }

        var totals: [String: TimeInterval] = [:]
        for d in diarization {
            let overlap = max(0, min(end, d.end) - max(start, d.start))
            if overlap > 0 { totals[d.speakerID, default: 0] += overlap }
        }
        if let best = totals.max(by: { $0.value < $1.value })?.key {
            return best
        }

        // No overlap at all — snap to the closest diarization segment.
        let mid = (start + end) / 2
        return diarization.min(by: { abs(midpoint($0) - mid) < abs(midpoint($1) - mid) })?.speakerID
    }

    private func midpoint(_ seg: DiarizedSegment) -> TimeInterval {
        (seg.start + seg.end) / 2
    }

    private func defaultName(for speakerID: String) -> String {
        if speakerID.hasPrefix("Speaker_"), let num = Int(speakerID.dropFirst("Speaker_".count)) {
            return "Speaker \(num)"
        }
        return speakerID
    }

    private func orderedUniqueSpeakerIDs(from diarization: [DiarizedSegment],
                                         fallback: [LabelledSegment]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for seg in diarization where !seen.contains(seg.speakerID) {
            seen.insert(seg.speakerID)
            ordered.append(seg.speakerID)
        }
        if ordered.isEmpty {
            for seg in fallback where !seen.contains(seg.speakerID) {
                seen.insert(seg.speakerID)
                ordered.append(seg.speakerID)
            }
        }
        return ordered
    }
}
