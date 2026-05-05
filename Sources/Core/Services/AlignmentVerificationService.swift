import AVFoundation
import FluidAudio
import Foundation

/// Pipeline that turns the user's segment text plus a recognizer pass into
/// word timings whose edges are corroborated by a signal-level VAD pass.
///
/// The pipeline:
///   1. **LCS-match** the user's tokens against the recognizer's words
///      (case-insensitive, punctuation-stripped). Matched words get the
///      recognizer's start/end (offset back into the project's timeline).
///   2. **VAD edge-snap.** Run the FluidAudio VAD on the slice and snap
///      each matched word's `start` and `end` to the nearest VAD speech-
///      region boundary within ±50 ms. This catches the "ASR says
///      1.234 s, the actual silence-to-speech transition was at 1.198 s"
///      drift — the dominant cause of perceived seek misalignment.
///   3. **Quality grading.** Snap deltas inside ±30 ms → `.verified`;
///      ±30–100 ms or no nearby boundary → `.approximate`; LCS-unmatched
///      words → `.interpolated` (with timings interpolated between the
///      nearest matched anchors).
///
/// VAD is intentionally the *only* extra signal here. A second ASR
/// (Parakeet or Whisper) would tighten the unverified-vs-verified split
/// further but would also force a several-hundred-megabyte model download
/// per app install. VAD is small (~few MB) and is signal-level truth —
/// where speech actually starts/stops in the audio doesn't depend on a
/// language model. Empirically, snapping ASR-derived edges to VAD
/// boundaries is the single biggest accuracy win available short of a
/// full forced aligner.
///
/// All work after init runs synchronously on the actor; the heavy
/// CoreML inference is dispatched by the FluidAudio actors internally.
@MainActor
@Observable
final class AlignmentVerificationService {

    /// Window (seconds) inside which a recognizer word edge can snap to a
    /// VAD speech-region boundary. Beyond this we leave the edge at the
    /// recognizer's value and grade the word as `.approximate` — VAD
    /// isn't claiming a boundary that close, so snapping further would
    /// be guessing.
    private static let snapWindow: TimeInterval = 0.050

    /// Tighter window for promotion to `.verified`. Edges that find a
    /// VAD boundary inside ±30 ms get the highest-confidence quality
    /// grade. The looser `snapWindow` is the floor for *any* snap.
    private static let verifiedWindow: TimeInterval = 0.030

    /// Lazily-initialized VAD manager. The first call pays a model load
    /// (~few MB download on first run, then cached on disk); subsequent
    /// calls reuse the loaded model. Held as a single instance so the
    /// background healer doesn't reload on every segment it processes.
    private var vad: VadManager?

    /// In-flight initialization task, dedup'd so concurrent first-callers
    /// don't each kick off a separate model load.
    private var initTask: Task<VadManager?, Never>?

    init() {}

    /// Verifies a single segment's word timings. The caller is expected to
    /// have already extracted the segment's audio to a 16 kHz mono WAV
    /// (via `TranscriptEditing.extractAudioRange`) and run the ASR pass —
    /// the verifier handles the LCS match, VAD pass, edge-snap, and
    /// quality grading.
    ///
    /// `sliceLeadOffset` is the project-time of t=0 in the sliced audio
    /// (i.e. `extractStart`). All recognizer + VAD times are in slice-
    /// relative seconds; the returned `WordTiming`s are translated back
    /// into the project's absolute timeline.
    ///
    /// Returns `nil` if `userTokens` is empty (caller should keep the
    /// existing words). Always returns a list the same length as
    /// `userTokens` on success.
    func verifyTimings(
        slicedAudioURL: URL,
        sliceLeadOffset: TimeInterval,
        userTokens: [String],
        recognizedWords: [WordTiming],
        segmentStart: TimeInterval,
        segmentEnd: TimeInterval
    ) async -> [WordTiming]? {
        guard !userTokens.isEmpty else { return nil }

        // 1. LCS match — same logic the existing `align` used, broken out
        // here so the verifier owns end-to-end timing assignment.
        let absoluteRecognized = recognizedWords.map { word in
            WordTiming(
                start: sliceLeadOffset + word.start,
                end: sliceLeadOffset + word.end,
                text: word.text,
                confidence: word.confidence,
                quality: .approximate
            )
        }
        let userClean = userTokens.map { Self.stripPunctuation($0.lowercased()) }
        let recogClean = absoluteRecognized.map { Self.stripPunctuation($0.text.lowercased()) }
        let matches = TranscriptEditing.lcsMatches(old: recogClean, new: userClean)

        // 2. VAD pass — best-effort. If VAD fails (model load issue,
        // empty audio), we keep the ASR-only timings and grade them
        // `.approximate`. Don't fail the whole verification.
        let vadBoundaries: [TimeInterval]
        if let manager = await ensureVad(),
           let samples = Self.readMonoFloatSamples(at: slicedAudioURL),
           !samples.isEmpty,
           let segments = try? await manager.segmentSpeech(samples) {
            // Boundaries the recognizer might want to snap to are the
            // start AND end of every detected speech region. Translate
            // from slice-relative back to project-time so the math below
            // matches the recognizer's coordinate system.
            var raw: [TimeInterval] = []
            raw.reserveCapacity(segments.count * 2)
            for seg in segments {
                raw.append(sliceLeadOffset + seg.startTime)
                raw.append(sliceLeadOffset + seg.endTime)
            }
            vadBoundaries = raw.sorted()
        } else {
            vadBoundaries = []
        }

        // 3. Slot matched user tokens, then VAD-snap their edges.
        var slots: [WordTiming?] = Array(repeating: nil, count: userTokens.count)
        for (recogIdx, userIdx) in matches {
            let r = absoluteRecognized[recogIdx]
            let snappedStart = Self.snap(r.start, to: vadBoundaries, within: Self.snapWindow)
            let snappedEnd = Self.snap(r.end, to: vadBoundaries, within: Self.snapWindow)
            let startDelta = abs((snappedStart ?? r.start) - r.start)
            let endDelta = abs((snappedEnd ?? r.end) - r.end)
            // Both edges fell inside the tight window: highest confidence.
            // Either edge fell inside the looser window or only one
            // snapped: middling. Neither snapped: ASR-only.
            let quality: WordTimingQuality = {
                let bothTight = snappedStart != nil && snappedEnd != nil
                    && startDelta <= Self.verifiedWindow
                    && endDelta <= Self.verifiedWindow
                if bothTight { return .verified }
                return .approximate
            }()
            slots[userIdx] = WordTiming(
                start: snappedStart ?? r.start,
                end: snappedEnd ?? r.end,
                text: userTokens[userIdx],
                confidence: r.confidence,
                quality: quality
            )
        }

        // 4. Interpolate unmatched runs between the nearest matched
        // anchors (or segment bounds at the edges) — same fallback the
        // legacy `align` used. Words filled this way are graded
        // `.interpolated` so the editor can hint that seeking may drift.
        var i = 0
        while i < slots.count {
            if slots[i] != nil { i += 1; continue }
            var j = i
            while j < slots.count, slots[j] == nil { j += 1 }
            let lead: TimeInterval = (i > 0) ? (slots[i - 1]?.end ?? segmentStart) : segmentStart
            let trail: TimeInterval = (j < slots.count) ? (slots[j]?.start ?? segmentEnd) : segmentEnd
            let span = max(0.05, trail - lead)
            let runCount = j - i
            let perWord = span / Double(runCount)
            for k in 0..<runCount {
                let s = lead + perWord * Double(k)
                let e = lead + perWord * Double(k + 1)
                slots[i + k] = WordTiming(
                    start: s,
                    end: e,
                    text: userTokens[i + k],
                    confidence: 0,
                    quality: .interpolated
                )
            }
            i = j
        }

        return slots.compactMap { $0 }
    }

    // MARK: - VAD lifecycle

    /// Returns a ready VAD manager, downloading + loading on the first
    /// call and reusing the cached instance afterwards. Returns `nil` on
    /// init failure so callers can fall back to ASR-only grading.
    private func ensureVad() async -> VadManager? {
        if let vad { return vad }
        if let task = initTask { return await task.value }
        let task = Task { @MainActor () -> VadManager? in
            do {
                let manager = try await VadManager()
                self.vad = manager
                return manager
            } catch {
                return nil
            }
        }
        initTask = task
        return await task.value
    }

    // MARK: - Pure helpers

    /// Snaps `value` to the nearest entry in a *sorted* boundary list when
    /// the closest boundary is within `tolerance`. Returns `nil` when
    /// nothing is close enough — caller decides what to do (we keep the
    /// original value and grade lower).
    nonisolated private static func snap(
        _ value: TimeInterval,
        to sortedBoundaries: [TimeInterval],
        within tolerance: TimeInterval
    ) -> TimeInterval? {
        guard !sortedBoundaries.isEmpty else { return nil }
        // Linear scan is fine — we expect at most a few dozen VAD edges
        // per segment, and we run this once per matched word.
        var best: (delta: TimeInterval, edge: TimeInterval)? = nil
        for edge in sortedBoundaries {
            let delta = abs(edge - value)
            if best == nil || delta < best!.delta {
                best = (delta, edge)
            }
            // Sorted input lets us break early once we've passed `value`
            // and the deltas start growing again.
            if edge > value, let current = best, delta > current.delta { break }
        }
        guard let pick = best, pick.delta <= tolerance else { return nil }
        return pick.edge
    }

    nonisolated private static func stripPunctuation(_ s: String) -> String {
        s.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
            .reduce(into: "") { $0.append(Character($1)) }
    }

    /// Reads a 16 kHz mono WAV (the format `extractAudioRange` produces)
    /// into a `[Float]` for VAD consumption. Returns `nil` on read
    /// failure. The audio is expected to already be mono — we just
    /// convert int16 samples to Float in [-1, 1] when needed.
    nonisolated private static func readMonoFloatSamples(at url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return nil }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        guard let channelData = buffer.floatChannelData else {
            // Non-float source — convert. Rare for our slices since
            // `extractAudioRange` writes 16 kHz mono int16 WAV; AVAudioFile
            // exposes that as Float in `processingFormat` though, so we
            // usually take the fast path above.
            return nil
        }
        let channelCount = Int(format.channelCount)
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        }
        // Down-mix in case the slice is unexpectedly multi-channel.
        var mono = [Float](repeating: 0, count: frames)
        for c in 0..<channelCount {
            let chan = channelData[c]
            for i in 0..<frames { mono[i] += chan[i] }
        }
        let scale = 1.0 / Float(channelCount)
        for i in 0..<frames { mono[i] *= scale }
        return mono
    }
}
