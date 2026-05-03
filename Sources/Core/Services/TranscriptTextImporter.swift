import Foundation

/// Parser for plain-text transcripts that Transcripty produces via
/// `TranscriptExporter.plainText`. Re-imports those files so the user can
/// hand-edit the transcript in any text editor and feed the result back into
/// the project as inline-edit revisions.
///
/// The exporter writes one block per segment:
///
///     [00:00] Speaker Name
///     Segment text content, possibly spanning multiple lines.
///
///     [00:05] Other Speaker
///     …
///
/// (Plus a 4-line preamble: title, date, separator, blank.) The parser is
/// permissive about the preamble — anything before the first timestamp line
/// is skipped — so users can prepend notes without breaking re-import.
enum TranscriptTextImporter {

    struct ImportedSegment: Sendable, Equatable {
        let startSeconds: TimeInterval
        let speakerName: String
        let text: String
    }

    static func parse(_ source: String) -> [ImportedSegment] {
        var results: [ImportedSegment] = []
        var lines = source.components(separatedBy: .newlines)
        // Trim a trailing blank line (common in editors) so the loop's
        // "blank ends a segment" rule doesn't drop the last segment.
        while lines.last?.isEmpty == true { lines.removeLast() }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard let header = parseHeader(line) else {
                i += 1
                continue
            }
            // Read text lines until a blank, the next header, or EOF.
            var textLines: [String] = []
            var j = i + 1
            while j < lines.count {
                let next = lines[j]
                if next.isEmpty { break }
                if parseHeader(next) != nil { break }
                textLines.append(next)
                j += 1
            }
            let text = textLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(ImportedSegment(
                startSeconds: header.start,
                speakerName: header.speakerName,
                text: text
            ))
            i = j
        }
        return results
    }

    // MARK: - Header parsing

    private struct ParsedHeader {
        let start: TimeInterval
        let speakerName: String
    }

    /// Recognizes lines like:
    ///   `[00:00] Speaker`
    ///   `[1:23:45] Speaker`
    /// Returns nil for everything else, so unrelated text in the preamble
    /// or interspersed comments are simply skipped.
    private static func parseHeader(_ line: String) -> ParsedHeader? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return nil }
        guard let closeBracket = trimmed.firstIndex(of: "]") else { return nil }
        let timestampSubstring = trimmed[trimmed.index(after: trimmed.startIndex)..<closeBracket]
        guard let seconds = parseTimestamp(String(timestampSubstring)) else { return nil }
        let afterBracket = trimmed.index(after: closeBracket)
        let speakerSubstring = trimmed[afterBracket...].drop(while: { $0 == " " })
        let speaker = String(speakerSubstring).trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedHeader(start: seconds, speakerName: speaker)
    }

    /// Decodes `mm:ss` and `h:mm:ss` (and the `hh:mm:ss` variant the exporter
    /// emits for ≥ 1 hour transcripts). Returns nil for malformed input — the
    /// caller treats that as "not a header line" and moves on.
    private static func parseTimestamp(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var seconds: TimeInterval = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }
}
