import Foundation
import SwiftData
import UniformTypeIdentifiers

/// File-format helpers for `.tscripty` archives. A `.tscripty` file is a
/// flat ZIP containing two entries:
///
///   * `manifest.json` — JSON-encoded project metadata, segments, and labels
///   * `audio.<ext>`    — the original imported audio, byte-for-byte
///
/// Importing recreates the project as a brand-new SwiftData record (fresh
/// project ID, fresh stored-audio filename), so a user can import the same
/// archive twice without conflicts. Segment, label, and edit IDs from the
/// archive *are* preserved — UUID collisions across machines are vanishingly
/// unlikely, and keeping them stable lets the revision-history layer keep
/// working without a rewriting pass.
enum ProjectArchive {

    static let fileExtension = "tscripty"

    /// Type identifier matched in Info.plist's UTExportedTypeDeclarations.
    /// `UTType(exportedAs:)` resolves against that declaration when present
    /// and falls back to a runtime stub that conforms to `.data` otherwise,
    /// so the build still works while the Info.plist update propagates.
    static let contentType: UTType = UTType(
        exportedAs: "com.transcripty.archive",
        conformingTo: .data
    )

    // MARK: - Manifest schema

    struct Manifest: Codable {
        static let currentVersion = 1

        let version: Int
        let exportedAt: Date
        let appVersion: String?
        let project: ProjectRecord
        let segments: [SegmentRecord]
        let labels: [LabelRecord]
        let audioFilename: String

        struct ProjectRecord: Codable {
            let id: UUID
            let title: String
            let createdAt: Date
            let expectedSpeakerCount: Int?
            let speakerOrder: [String]
            let speakerNames: [String: String]
        }

        struct SegmentRecord: Codable {
            let id: UUID
            let startSeconds: Double
            let endSeconds: Double
            let speakerID: String
            let speakerName: String
            let text: String
            let words: [WordTiming]
            let embedding: [Float]
        }

        struct LabelRecord: Codable {
            let id: UUID
            let name: String
            let colorHex: String
            let createdAt: Date
        }
    }

    // MARK: - Errors

    enum ArchiveError: LocalizedError {
        case audioMissing
        case manifestMissing
        case manifestInvalid(detail: String)
        case versionUnsupported(Int)

        var errorDescription: String? {
            switch self {
            case .audioMissing:
                return "The project's audio file is no longer available, so the archive can't be exported."
            case .manifestMissing:
                return "This archive doesn't contain a project manifest. It may be corrupt or from a different application."
            case .manifestInvalid(let detail):
                return "The archive's project manifest is invalid: \(detail)."
            case .versionUnsupported(let version):
                return "This archive was created with a newer version of Transcripty (format v\(version)). Please update the app to open it."
            }
        }
    }

    // MARK: - Export

    /// Writes a `.tscripty` archive of `project` to `destinationURL`. Runs the
    /// CRC32 + zip pass on a background priority since audio entries can be
    /// hundreds of MB.
    @MainActor
    static func export(project: TranscriptionProject, to destinationURL: URL) async throws {
        guard let audioURL = project.sourceAudioURL else {
            throw ArchiveError.audioMissing
        }
        let manifest = Self.buildManifest(for: project, audioURL: audioURL)
        let manifestData = try JSONEncoder.archiveEncoder.encode(manifest)

        let audioFilename = manifest.audioFilename
        let audioPath = audioURL.path

        try await Task.detached(priority: .userInitiated) {
            // Read audio without holding a security-scoped resource — the
            // sandbox copy lives inside the app container so plain Foundation
            // file IO is enough.
            let audioData = try Data(contentsOf: URL(fileURLWithPath: audioPath),
                                      options: [.mappedIfSafe])
            let entries: [ZipArchive.Entry] = [
                ZipArchive.Entry(name: "manifest.json", data: manifestData),
                ZipArchive.Entry(name: audioFilename, data: audioData),
            ]
            try ZipArchive.write(entries: entries, to: destinationURL)
        }.value
    }

    private static func buildManifest(for project: TranscriptionProject, audioURL: URL) -> Manifest {
        let segments = project.segments
            .sorted { $0.startSeconds < $1.startSeconds }
            .map { segment in
                Manifest.SegmentRecord(
                    id: segment.id,
                    startSeconds: segment.startSeconds,
                    endSeconds: segment.endSeconds,
                    speakerID: segment.speakerID,
                    speakerName: segment.speakerName,
                    text: segment.text,
                    words: segment.words,
                    embedding: segment.embedding
                )
            }
        let labels = project.labels.map { label in
            Manifest.LabelRecord(
                id: label.id,
                name: label.name,
                colorHex: label.colorHex,
                createdAt: label.createdAt
            )
        }
        let audioFilename = audioURL.pathExtension.isEmpty
            ? "audio"
            : "audio.\(audioURL.pathExtension)"
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        return Manifest(
            version: Manifest.currentVersion,
            exportedAt: .now,
            appVersion: appVersion,
            project: Manifest.ProjectRecord(
                id: project.id,
                title: project.title,
                createdAt: project.createdAt,
                expectedSpeakerCount: project.expectedSpeakerCount,
                speakerOrder: project.speakerOrder,
                speakerNames: project.speakerNames
            ),
            segments: segments,
            labels: labels,
            audioFilename: audioFilename
        )
    }

    // MARK: - Import

    /// Decoded archive contents, ready to materialize into SwiftData. Split
    /// into a "load" + "materialize" pair so the heavy zip+JSON work happens
    /// off the main actor while the SwiftData inserts stay on it.
    struct LoadedArchive {
        let manifest: Manifest
        let audioData: Data
    }

    /// Reads + validates the archive on a background priority.
    static func load(from sourceURL: URL) async throws -> LoadedArchive {
        try await Task.detached(priority: .userInitiated) {
            let entries = try ZipArchive.read(from: sourceURL)
            guard let manifestEntry = entries.first(where: { $0.name == "manifest.json" }) else {
                throw ArchiveError.manifestMissing
            }
            let manifest: Manifest
            do {
                manifest = try JSONDecoder.archiveDecoder.decode(Manifest.self, from: manifestEntry.data)
            } catch {
                throw ArchiveError.manifestInvalid(detail: error.localizedDescription)
            }
            guard manifest.version <= Manifest.currentVersion else {
                throw ArchiveError.versionUnsupported(manifest.version)
            }
            guard let audioEntry = entries.first(where: { $0.name == manifest.audioFilename }) else {
                throw ArchiveError.audioMissing
            }
            return LoadedArchive(manifest: manifest, audioData: audioEntry.data)
        }.value
    }
}

// MARK: - Encoder/decoder configuration

private extension JSONEncoder {
    static var archiveEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var archiveDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
