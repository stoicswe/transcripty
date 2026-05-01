import Foundation
import SwiftData

/// Resolves waveform peaks for a `TranscriptionProject`, computing them once
/// off-main and then persisting them on the project. Subsequent renders (grid
/// thumbnail, playback bar, any future view) downsample from the cached
/// high-resolution array instead of re-scanning the audio file.
enum ProjectWaveformCache {
    /// Resolution we persist per-project. High enough to downsample cleanly
    /// to the widest current renderer (the 400-bar playback bar), low enough
    /// to stay cheap in SwiftData (~3 KB per project).
    static let storedResolution = 800

    /// In-flight dedup: if the grid, editor, and playback bar all ask for a
    /// project's peaks at once, they share a single extraction.
    @MainActor private static var inFlight: [UUID: Task<[Float], Never>] = [:]

    /// Returns peaks for `project` at the requested bucket count. On the first
    /// call for a project the audio is scanned off-main and the result is
    /// written back to `project.cachedPeaks`.
    @MainActor
    static func peaks(
        for project: TranscriptionProject,
        targetCount: Int,
        modelContext: ModelContext
    ) async -> [Float] {
        if let cached = project.cachedPeaks, !cached.isEmpty {
            return downsample(cached, to: targetCount)
        }

        let projectID = project.id
        let task: Task<[Float], Never>
        if let existing = inFlight[projectID] {
            task = existing
        } else {
            guard let url = project.sourceAudioURL else { return [] }
            task = Task.detached(priority: .utility) {
                WaveformExtractor.extractPeaks(from: url, targetCount: storedResolution)
            }
            inFlight[projectID] = task
        }

        let stored = await task.value
        inFlight.removeValue(forKey: projectID)

        if !stored.isEmpty, project.cachedPeaks == nil {
            project.cachedPeaks = stored
            try? modelContext.save()
        }
        return downsample(stored, to: targetCount)
    }

    /// Max-pool downsample. Picks the loudest sample in each bucket so the
    /// downsampled shape keeps its peaks instead of averaging them away.
    static func downsample(_ peaks: [Float], to target: Int) -> [Float] {
        guard !peaks.isEmpty, target > 0 else { return [] }
        if target >= peaks.count { return peaks }

        let step = Double(peaks.count) / Double(target)
        var out: [Float] = []
        out.reserveCapacity(target)
        for i in 0..<target {
            let lo = Int(Double(i) * step)
            let hi = min(peaks.count, max(lo + 1, Int(Double(i + 1) * step)))
            var maxV: Float = 0
            for k in lo..<hi where peaks[k] > maxV {
                maxV = peaks[k]
            }
            out.append(maxV)
        }
        return out
    }
}
