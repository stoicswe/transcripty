import Foundation
import SwiftData

/// One reversible edit recorded against a project. Edits are persisted, so the
/// revision history survives app launches — the user can look back at what
/// they changed last week and step back through it.
///
/// The structured payload (`ProjectEditPayload`) captures everything needed to
/// invert the edit. We encode it as JSON in `payloadData` rather than relying
/// on SwiftData to model the variants, which keeps schema migrations simple
/// when we add new edit kinds.
@Model
final class ProjectEdit {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    /// Short, human-readable summary shown in the revision history list (e.g.
    /// "Renamed Speaker 1 to Alice"). Generated at record time so undoing the
    /// edit doesn't change how it reads after the fact.
    var summary: String
    /// String form of `ProjectEditPayload`'s case — useful for filtering and
    /// for diagnostics if the payload ever fails to decode.
    var kind: String
    var payloadData: Data
    /// The segment the user was inspecting when this edit happened, when the
    /// edit has one. For speaker renames it's the segment whose row triggered
    /// the popover — i.e. the one the user actually listened to before
    /// committing the new name. The voice-print enrollment uses this to
    /// weight that segment more heavily than other segments that just
    /// inherited the name transitively. Optional and stored alongside the
    /// payload so the existing JSON-encoded enum stays binary-compatible
    /// with prior versions.
    var contextSegmentID: UUID?
    var project: TranscriptionProject?

    init(
        summary: String,
        payload: ProjectEditPayload,
        contextSegmentID: UUID? = nil
    ) {
        self.id = UUID()
        self.timestamp = .now
        self.summary = summary
        self.kind = payload.kind
        self.payloadData = (try? JSONEncoder().encode(payload)) ?? Data()
        self.contextSegmentID = contextSegmentID
    }

    var payload: ProjectEditPayload? {
        guard !payloadData.isEmpty else { return nil }
        return try? JSONDecoder().decode(ProjectEditPayload.self, from: payloadData)
    }
}

/// All the user-driven edits the app knows how to record + undo. Each case
/// carries the *previous* state, so applying its inverse restores the project
/// to where it was before the edit.
enum ProjectEditPayload: Codable, Equatable {
    case titleChanged(previousTitle: String)
    case speakerNameChanged(speakerID: String, previousName: String?)
    case labelAdded(labelID: UUID)
    case labelRemoved(labelID: UUID)
    case segmentSplit(
        originalSegmentID: UUID,
        newSegmentID: UUID,
        previousText: String,
        previousEndSeconds: Double,
        previousWords: [WordTiming],
        addedSpeakerID: String?
    )
    /// Two adjacent segments collapsed into one. `survivingSegmentID` is
    /// the earlier-in-time segment that absorbed the other; the rest captures
    /// the absorbed segment's full state plus the survivor's pre-merge text /
    /// end / words / embedding so undo can recreate both.
    case segmentsMerged(
        survivingSegmentID: UUID,
        previousSurvivorText: String,
        previousSurvivorEndSeconds: Double,
        previousSurvivorWords: [WordTiming],
        previousSurvivorEmbedding: [Float],
        absorbedStartSeconds: Double,
        absorbedEndSeconds: Double,
        absorbedText: String,
        absorbedSpeakerID: String,
        absorbedSpeakerName: String,
        absorbedWords: [WordTiming],
        absorbedEmbedding: [Float]
    )
    /// One inline text edit recorded by the editor. Stores the *previous*
    /// snapshot (text, word timings, edited flag) so undo can restore the
    /// segment exactly as it was before the user typed.
    case textChanged(
        segmentID: UUID,
        previousText: String,
        previousWords: [WordTiming],
        previousWasEdited: Bool
    )
    /// User dragged a contiguous run of words from one segment into the
    /// chronologically-adjacent segment ("merge selection with previous /
    /// next speaker"). We store the moved word list plus the *previous*
    /// shape of both segments so undo can rebuild the old boundaries.
    case wordsMoved(
        sourceSegmentID: UUID,
        targetSegmentID: UUID,
        movedWords: [WordTiming],
        sourcePreviousText: String,
        sourcePreviousWords: [WordTiming],
        sourcePreviousStartSeconds: Double,
        sourcePreviousEndSeconds: Double,
        targetPreviousText: String,
        targetPreviousWords: [WordTiming],
        targetPreviousStartSeconds: Double,
        targetPreviousEndSeconds: Double,
        movedToPrefix: Bool
    )

    var kind: String {
        switch self {
        case .titleChanged: "title"
        case .speakerNameChanged: "speakerName"
        case .labelAdded: "labelAdded"
        case .labelRemoved: "labelRemoved"
        case .segmentSplit: "split"
        case .segmentsMerged: "merge"
        case .textChanged: "textChanged"
        case .wordsMoved: "wordsMoved"
        }
    }
}
