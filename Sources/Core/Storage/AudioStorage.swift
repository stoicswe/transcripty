import Foundation

/// Manages per-project copies of imported audio inside the app sandbox so
/// projects stay playable even if the user deletes the original file.
/// Files live at `Application Support/Transcripty/Audio/<project-uuid>.<ext>`.
enum AudioStorage {
    enum StorageError: LocalizedError {
        case noExtension(URL)
        case copyFailed(URL, underlying: any Error)

        var errorDescription: String? {
            switch self {
            case .noExtension(let url):
                return "The file at \(url.lastPathComponent) has no extension, so Transcripty can't tell what kind of audio it is."
            case .copyFailed(let url, let underlying):
                return "Couldn't copy \(url.lastPathComponent) into the project: \(underlying.localizedDescription)"
            }
        }
    }

    static func audioDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport
            .appendingPathComponent("Transcripty", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies `sourceURL` into the sandbox and returns the filename (relative
    /// to `audioDirectory()`) under which it's stored.
    static func importAudio(from sourceURL: URL, projectID: UUID) throws -> String {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let ext = sourceURL.pathExtension
        guard !ext.isEmpty else { throw StorageError.noExtension(sourceURL) }

        let filename = "\(projectID.uuidString).\(ext)"
        let destination = try audioDirectory().appendingPathComponent(filename)

        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            throw StorageError.copyFailed(sourceURL, underlying: error)
        }
        return filename
    }

    /// Resolves `filename` to a URL within the sandbox, or `nil` if the file
    /// is missing.
    static func url(forStoredFilename filename: String) -> URL? {
        guard let dir = try? audioDirectory() else { return nil }
        let url = dir.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func delete(filename: String) {
        guard let dir = try? audioDirectory() else { return }
        let url = dir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }
}
