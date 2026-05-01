import Foundation
import Speech
import AVFAudio
import CoreMedia

/// Apple Speech framework conformer for `Transcriber`.
///
/// Uses `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26+) with the offline,
/// word-timed configuration for maximum accuracy on recorded audio files.
/// All processing happens on device; no network activity is performed except
/// the one-time Apple asset download for the selected locale.
final class AppleSpeechTranscriber: Transcriber {

    func transcribe(
        audioURL: URL,
        locale: Locale,
        onProgress: @escaping @Sendable (TranscriberProgress) -> Void
    ) async throws -> [TranscribedSegment] {

        let accessed = audioURL.startAccessingSecurityScopedResource()
        defer { if accessed { audioURL.stopAccessingSecurityScopedResource() } }

        onProgress(.checkingSupport)
        let resolvedLocale = try await Self.resolveSupportedLocale(preferred: locale)

        // Configure for max-accuracy offline transcription with word-level timing.
        // - Empty reportingOptions => only finalized results (no volatile partials
        //   for file transcription; they would just be noise).
        // - attributeOptions: [.audioTimeRange] => each AttributedString run
        //   carries its CMTimeRange, which the editor uses for synced playback.
        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        try await Self.ensureModelInstalled(for: transcriber, locale: resolvedLocale, onProgress: onProgress)

        onProgress(.preparing)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            throw TranscriptionError.audioUnreadable(audioURL)
        }

        let resultStream = transcriber.results
        let collector = Task { () throws -> [TranscribedSegment] in
            var collected: [TranscribedSegment] = []
            for try await result in resultStream {
                guard result.isFinal else { continue }
                if let segment = Self.makeSegment(from: result.text) {
                    collected.append(segment)
                }
            }
            return collected
        }

        onProgress(.analyzing)
        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }

        return try await collector.value
    }

    // MARK: - Segment construction

    private static func makeSegment(from attributed: AttributedString) -> TranscribedSegment? {
        var start: CMTime?
        var end: CMTime?
        var words: [WordTiming] = []
        for run in attributed.runs {
            guard let range = run.audioTimeRange else { continue }
            if start == nil || range.start < start! { start = range.start }
            if end == nil || range.end > end! { end = range.end }

            let runText = String(attributed[run.range].characters)
            let tokens = runText
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            guard !tokens.isEmpty else { continue }
            let rangeStart = range.start.seconds
            let rangeEnd = range.end.seconds
            let duration = max(0, rangeEnd - rangeStart)
            // Apple usually emits one run per token, so tokens.count == 1 is
            // the common case and perToken == duration. When a run carries
            // several tokens, split the range evenly — a cheap approximation
            // that's still accurate enough for word-level playback sync.
            let perToken = tokens.count > 0 ? duration / Double(tokens.count) : 0
            for (i, token) in tokens.enumerated() {
                let wordStart = rangeStart + perToken * Double(i)
                let wordEnd = i == tokens.count - 1 ? rangeEnd : wordStart + perToken
                words.append(WordTiming(start: wordStart, end: wordEnd, text: token))
            }
        }
        let text = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let s = start, let e = end else { return nil }
        return TranscribedSegment(
            start: s.seconds,
            end: e.seconds,
            text: text,
            words: words
        )
    }

    // MARK: - Locale / model management

    /// Resolves the user's preferred locale to one Apple's `SpeechTranscriber` actually
    /// supports. `Locale.current` commonly carries Unicode extensions (e.g.
    /// `en-IE-u-rg-uszzzz` when the user has a US regional-format override), and the
    /// framework only publishes plain language-region identifiers — so we strip the
    /// extensions, then fall back through language-match → English before giving up.
    private static func resolveSupportedLocale(preferred: Locale) async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales

        func match(_ identifier: String) -> Locale? {
            supported.first { $0.identifier(.bcp47).caseInsensitiveCompare(identifier) == .orderedSame }
        }

        // 1) Exact match on the preferred identifier (rare when extensions present).
        if let hit = match(preferred.identifier(.bcp47)) { return hit }

        // 2) Strip Unicode extensions: language + region only.
        let language = preferred.language.languageCode?.identifier
        let region = preferred.region?.identifier
        if let language, let region, let hit = match("\(language)-\(region)") {
            return hit
        }

        // 3) Any supported locale that shares the preferred language.
        if let language,
           let hit = supported.first(where: { $0.language.languageCode?.identifier == language }) {
            return hit
        }

        // 4) Reasonable fallback so users aren't stuck on an obscure region.
        if let hit = match("en-US") { return hit }
        if let hit = supported.first { return hit }

        throw TranscriptionError.localeNotSupported(preferred)
    }

    private static func ensureModelInstalled(
        for transcriber: SpeechTranscriber,
        locale: Locale,
        onProgress: @escaping @Sendable (TranscriberProgress) -> Void
    ) async throws {
        let installed = await SpeechTranscriber.installedLocales
        let installedBCP = Set(installed.map { $0.identifier(.bcp47) })

        if !installedBCP.contains(locale.identifier(.bcp47)) {
            do {
                if let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [transcriber]
                ) {
                    onProgress(.downloadingModel(fraction: nil))
                    let progress = request.progress
                    let observation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
                        onProgress(.downloadingModel(fraction: p.fractionCompleted))
                    }
                    defer { observation.invalidate() }
                    try await request.downloadAndInstall()
                }
            } catch {
                throw TranscriptionError.modelInstallFailed(underlying: error)
            }
        }

        let reserved = await AssetInventory.reservedLocales
        let isReserved = reserved.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        if !isReserved {
            do {
                try await AssetInventory.reserve(locale: locale)
            } catch {
                throw TranscriptionError.modelInstallFailed(underlying: error)
            }
        }
    }
}
