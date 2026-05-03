import Foundation
import NaturalLanguage

/// On-device scan for personal names, place names, and organizations across
/// a project's transcript. Backed by `NLTagger` — Apple's named-entity
/// recognizer — which runs entirely locally so audio + transcripts never
/// leave the user's Mac (consistent with the rest of the privacy story).
enum EntityScanner {

    enum EntityKind: String, Sendable, Hashable {
        case personalName
        case placeName
        case organizationName

        var displayName: String {
            switch self {
            case .personalName: "Person"
            case .placeName: "Place"
            case .organizationName: "Organization"
            }
        }

        var systemImage: String {
            switch self {
            case .personalName: "person.fill"
            case .placeName: "mappin.and.ellipse"
            case .organizationName: "building.2.fill"
            }
        }
    }

    /// One occurrence of a detected entity. We collapse occurrences of the
    /// same surface text + kind into a `Group` for the UI, but keep the per-
    /// occurrence segment + character range so applying a replacement edits
    /// every spot the entity appears.
    struct Occurrence: Sendable, Identifiable {
        let id = UUID()
        let segmentID: UUID
        let kind: EntityKind
        let text: String
        /// Byte-stable lowercased form used to group occurrences together.
        let normalized: String
    }

    struct Group: Sendable, Identifiable {
        let id = UUID()
        let kind: EntityKind
        let text: String
        let normalized: String
        var occurrences: [Occurrence]
    }

    /// Snapshot of the data the scanner needs from a segment. Lets callers
    /// hop the named-entity work to a background task without dragging the
    /// SwiftData model through the actor boundary.
    struct SegmentSample: Sendable {
        let id: UUID
        let text: String
    }

    static func scan(segments: [SpeakerSegment]) -> [Group] {
        scan(samples: segments.map { SegmentSample(id: $0.id, text: $0.text) })
    }

    /// Scans every segment's text for named entities and returns the unique
    /// groups, sorted by kind then alphabetically. Empty array means the
    /// transcript has no detectable names/places — at which point the editor
    /// suppresses the privacy popup.
    static func scan(samples: [SegmentSample]) -> [Group] {
        var occurrences: [Occurrence] = []

        for sample in samples {
            let text = sample.text
            guard !text.isEmpty else { continue }
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = text

            let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
            tagger.enumerateTags(
                in: text.startIndex..<text.endIndex,
                unit: .word,
                scheme: .nameType,
                options: options
            ) { tag, range in
                guard let tag, let kind = mapTag(tag) else { return true }
                let surfaceText = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard surfaceText.count >= 2 else { return true }
                let normalized = surfaceText.lowercased()
                occurrences.append(Occurrence(
                    segmentID: sample.id,
                    kind: kind,
                    text: surfaceText,
                    normalized: normalized
                ))
                return true
            }
        }

        // Group identical entities (same kind + normalized text). The first
        // occurrence's casing wins as the display label.
        var groups: [String: Group] = [:]
        for occ in occurrences {
            let key = "\(occ.kind.rawValue)|\(occ.normalized)"
            if var existing = groups[key] {
                existing.occurrences.append(occ)
                groups[key] = existing
            } else {
                groups[key] = Group(
                    kind: occ.kind,
                    text: occ.text,
                    normalized: occ.normalized,
                    occurrences: [occ]
                )
            }
        }

        return groups.values.sorted { lhs, rhs in
            if lhs.kind == rhs.kind {
                return lhs.text.localizedCaseInsensitiveCompare(rhs.text) == .orderedAscending
            }
            return kindOrder(lhs.kind) < kindOrder(rhs.kind)
        }
    }

    private static func mapTag(_ tag: NLTag) -> EntityKind? {
        switch tag {
        case .personalName: return .personalName
        case .placeName: return .placeName
        case .organizationName: return .organizationName
        default: return nil
        }
    }

    private static func kindOrder(_ kind: EntityKind) -> Int {
        switch kind {
        case .personalName: 0
        case .placeName: 1
        case .organizationName: 2
        }
    }
}
