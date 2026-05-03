import Foundation
import SwiftData

enum ProjectStatus: String, Codable {
    case pending
    case transcribing
    case ready
    case failed

    var displayName: String {
        switch self {
        case .pending: "Pending"
        case .transcribing: "Transcribing"
        case .ready: "Ready"
        case .failed: "Failed"
        }
    }
}

@Model
final class TranscriptionProject {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    /// Legacy bookmark from an older version that referenced files in-place.
    /// New projects store a copy of the audio in the sandbox instead.
    var sourceAudioBookmark: Data?
    /// Filename (relative to `AudioStorage.audioDirectory()`) of the copy
    /// that lives inside the sandbox. Projects created after adding this
    /// field always have it; older projects fall back to the bookmark.
    var storedAudioFilename: String?
    var rawStatus: String
    var speakerOrder: [String] = []
    /// User-assigned display names keyed by stable speakerID (e.g.
    /// `"Speaker_1" -> "Alice"`). Missing entries fall back to the
    /// auto-generated default ("Speaker 1").
    var speakerNames: [String: String] = [:]
    /// Optional hint supplied at import time — when set, the diarizer is
    /// constrained to exactly this many speakers, which dramatically
    /// improves separation accuracy for known-count recordings (e.g. a
    /// two-person interview). `nil` means auto-detect.
    var expectedSpeakerCount: Int?
    /// Cached high-resolution waveform peaks for this project. Computed
    /// lazily on first render (expensive for hour-long recordings) and
    /// reused by both the grid thumbnail and the playback waveform —
    /// downsampled to whatever count the current view needs. `nil` means
    /// not yet computed.
    var cachedPeaks: [Float]?

    @Relationship(deleteRule: .cascade, inverse: \SpeakerSegment.project)
    var segments: [SpeakerSegment] = []

    /// Reversible edit log used by the revision history panel. Persisted, so
    /// users can step back through edits across sessions.
    @Relationship(deleteRule: .cascade, inverse: \ProjectEdit.project)
    var edits: [ProjectEdit] = []

    var labels: [ProjectLabel] = []

    var status: ProjectStatus {
        get { ProjectStatus(rawValue: rawStatus) ?? .pending }
        set { rawStatus = newValue.rawValue }
    }

    var sourceAudioURL: URL? {
        if let filename = storedAudioFilename,
           let url = AudioStorage.url(forStoredFilename: filename) {
            return url
        }
        guard let data = sourceAudioBookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data,
                        options: [.withSecurityScope],
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale)
    }

    init(title: String) {
        self.id = UUID()
        self.title = title
        self.createdAt = .now
        self.rawStatus = ProjectStatus.pending.rawValue
    }

    /// Returns the user-chosen name for `speakerID`, or the default
    /// (`"Speaker N"` when the ID follows the `Speaker_N` convention).
    func displayName(forSpeakerID speakerID: String) -> String {
        if let custom = speakerNames[speakerID]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        if speakerID.hasPrefix("Speaker_"),
           let num = Int(speakerID.dropFirst("Speaker_".count)) {
            return "Speaker \(num)"
        }
        return speakerID
    }
}

@Model
final class SpeakerSegment {
    @Attribute(.unique) var id: UUID
    var startSeconds: Double
    var endSeconds: Double
    var speakerID: String
    var speakerName: String
    var text: String
    /// Per-word playback timings used for in-block word highlight + scroll.
    /// Empty for older projects imported before word timings were captured —
    /// callers fall back to whole-segment highlighting.
    var words: [WordTiming] = []
    /// Diarizer-provided 256-D voice embedding (WeSpeaker space) for this
    /// segment. Empty for legacy projects and when the diarizer didn't
    /// produce one. Used as the "voice fingerprint" for embedding-based
    /// label transfer when the user retranscribes — every segment they've
    /// labelled becomes a piece of training data.
    var embedding: [Float] = []
    /// True when the user has manually edited the text of this segment but
    /// hasn't asked for a fresh forced-alignment pass yet. Until that runs,
    /// any inserted/changed words carry interpolated timings that the editor
    /// surfaces via a "Recompute Timings" affordance.
    var wasEdited: Bool = false
    var project: TranscriptionProject?

    init(startSeconds: Double,
         endSeconds: Double,
         speakerID: String,
         speakerName: String,
         text: String,
         words: [WordTiming] = [],
         embedding: [Float] = []) {
        self.id = UUID()
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.text = text
        self.words = words
        self.embedding = embedding
    }

    func contains(time: TimeInterval) -> Bool {
        time >= startSeconds && time < endSeconds
    }

    /// Index of the last word whose start has been reached at `time`. When the
    /// playhead is sitting in a gap between words — common for podcasts where
    /// the speech model inserts music/silence between runs — we hold on the
    /// most recently spoken word instead of jumping to the next one that
    /// hasn't started yet. `nil` when playback is before the first word or
    /// the segment has no word-level timing.
    func activeWordIndex(at time: TimeInterval) -> Int? {
        guard !words.isEmpty, time >= startSeconds else { return nil }
        // Binary search for the last word with start <= time.
        var lo = 0
        var hi = words.count - 1
        var best: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if words[mid].start <= time {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }
}
