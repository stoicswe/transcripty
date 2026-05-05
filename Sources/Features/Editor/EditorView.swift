import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers

struct EditorView: View {
    let project: TranscriptionProject

    @Environment(TranscriptionService.self) private var service
    @State private var player: AVPlayer?
    @State private var audioURL: URL?
    @State private var duration: TimeInterval = 0
    @State private var currentTime: TimeInterval = 0
    @State private var isPlaying = false
    @State private var securityAccessHeld = false
    @State private var timeObserverToken: Any?
    @State private var exportDocument: TranscriptTextDocument?
    @State private var isExporterPresented = false
    @State private var isHistoryPresented = false
    @State private var isShowingSettings = false
    @State private var isExportingArchive = false
    @State private var archiveError: String?
    @State private var transcriptImportSummary: TranscriptionService.TranscriptImportSummary?
    @State private var transcriptImportError: String?
    @State private var editingSegmentID: UUID?
    @State private var isRecomputingTimings = false
    @State private var recomputeProgress: Double = 0
    @State private var recomputeError: String?
    @State private var entityGroups: [EntityScanner.Group] = []
    @State private var isEntityScanPresented = false
    @State private var isScanningEntities = false
    @State private var hasRunInitialEntityScan = false
    @State private var isFindBarPresented = false
    @State private var findQuery: String = ""
    @State private var replaceWith: String = ""
    @State private var findCaseSensitive: Bool = false
    @State private var findMatches: [FindMatch] = []
    @State private var currentFindMatchIndex: Int = 0
    /// When false, the active-word/segment highlight and auto-scroll are
    /// suppressed so the user can play audio aloud while editing without the
    /// transcript jumping around. Persisted across sessions and projects.
    @AppStorage("editor.followAlongEnabled") private var followAlongEnabled: Bool = true

    private var job: TranscriptionService.JobState? {
        service.jobs[project.id]
    }

    private var orderedSegments: [SpeakerSegment] {
        project.segments.sorted { $0.startSeconds < $1.startSeconds }
    }

    /// The segment currently under the playhead. Computed independently
    /// of `followAlongEnabled` so the drift detector keeps working even
    /// when the user has the follow-along highlight turned off.
    private var activePlaybackSegmentID: UUID? {
        orderedSegments.first(where: { $0.contains(time: currentTime) })?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            LabelsBar(project: project)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
            Divider()
            if let job, job.phase != .finished, project.segments.isEmpty {
                JobProgressView(job: job, audioDuration: duration, audioURL: audioURL)
                    .frame(maxHeight: .infinity)
            } else if project.segments.isEmpty, project.status == .pending {
                PendingTranscriptionView(
                    expectedSpeakerCount: project.expectedSpeakerCount,
                    onStart: { service.start(project: project) },
                    onOpenSettings: { isShowingSettings = true }
                )
                .frame(maxHeight: .infinity)
            } else {
                transcriptPane
                    .frame(maxHeight: .infinity)
            }
            PlaybackBar(
                project: project,
                audioURL: audioURL,
                duration: duration,
                currentTime: currentTime,
                isPlaying: isPlaying,
                followAlongEnabled: $followAlongEnabled,
                onTogglePlay: togglePlay,
                onSkip: { delta in seek(to: currentTime + delta) },
                onScrub: { seek(to: $0) }
            )
            .padding(16)
            .background(.ultraThinMaterial)
        }
        .navigationTitle(project.title)
        .task(id: project.id) { await loadPlayer() }
        .onDisappear { teardownPlayer() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    service.undoLastEdit(in: project)
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(project.edits.isEmpty)
                .help(project.edits.isEmpty
                      ? "Nothing to undo"
                      : "Undo last edit (⌘Z)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleFindBar()
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .help("Find and replace (⌘F)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    runEntityScan()
                } label: {
                    if isScanningEntities {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Scanning…")
                        }
                    } else {
                        Label("Privacy Scan", systemImage: "lock.shield")
                    }
                }
                .help("Find names, places, and organizations in the transcript")
                .disabled(orderedSegments.isEmpty || isScanningEntities)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingSettings = true
                } label: {
                    Label("Transcription Settings", systemImage: "slider.horizontal.3")
                }
                .help("Adjust speaker count, re-transcribe, or clear the transcript")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isHistoryPresented.toggle()
                } label: {
                    Label("Revision History", systemImage: "clock.arrow.circlepath")
                }
                .help("Show revision history")
                .popover(isPresented: $isHistoryPresented, arrowEdge: .bottom) {
                    RevisionHistoryPopover(project: project)
                        .environment(service)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        exportDocument = TranscriptTextDocument(
                            text: TranscriptExporter.plainText(
                                projectTitle: project.title,
                                createdAt: project.createdAt,
                                segments: orderedSegments,
                                displayName: project.displayName(forSpeakerID:)
                            )
                        )
                        isExporterPresented = true
                    } label: {
                        Label("Export Transcript (Plain Text)…", systemImage: "doc.plaintext")
                    }
                    .disabled(orderedSegments.isEmpty)

                    Button {
                        runArchiveExport()
                    } label: {
                        Label("Export Project Archive (.tscripty)…", systemImage: "archivebox")
                    }
                    .disabled(isExportingArchive)
                    Divider()
                    Button {
                        runTranscriptTextReimport()
                    } label: {
                        Label("Re-Import Edited Transcript Text…", systemImage: "doc.text.below.ecg")
                    }
                    .disabled(orderedSegments.isEmpty)
                } label: {
                    if isExportingArchive {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                .help("Export the transcript or a portable project archive")
            }
        }
        .modifier(EditorAlertsModifier(
            isExporterPresented: $isExporterPresented,
            exportDocument: exportDocument,
            projectTitle: project.title,
            archiveError: $archiveError,
            recomputeError: $recomputeError,
            transcriptImportError: $transcriptImportError,
            transcriptImportSummary: $transcriptImportSummary,
            onExportFinished: { exportDocument = nil }
        ))
        .modifier(EditorOnChangeModifier(
            projectID: project.id,
            segmentTexts: project.segments.map(\.text),
            segmentCount: project.segments.count,
            findQuery: findQuery,
            findCaseSensitive: findCaseSensitive,
            onProjectIDChanged: {
                hasRunInitialEntityScan = false
                findMatches = []
                currentFindMatchIndex = 0
                isFindBarPresented = false
                editingSegmentID = nil
            },
            onSegmentsChanged: { rebuildFindMatches() },
            onFindCriteriaChanged: { rebuildFindMatches() },
            onSegmentCountChanged: { scheduleInitialEntityScan(force: true) },
            onTaskRefresh: { scheduleInitialEntityScan(force: false) }
        ))
        // When playback enters a new segment, ask the service whether its
        // word timings look stale or pathological. If so, the service
        // schedules a debounced background recompute on it. Cheap when
        // the segment looks healthy (returns immediately).
        .onChange(of: activePlaybackSegmentID) { _, newID in
            guard let newID,
                  let segment = orderedSegments.first(where: { $0.id == newID }) else { return }
            service.scheduleDriftRecomputeIfNeeded(for: segment, in: project)
        }
        .sheet(isPresented: $isEntityScanPresented) {
            EntityScanSheet(
                groups: entityGroups,
                onCancel: { isEntityScanPresented = false },
                onApply: { actions in
                    applyEntityActions(actions)
                    isEntityScanPresented = false
                }
            )
        }
        .sheet(isPresented: $isShowingSettings) {
            TranscriptionSettingsSheet(
                project: project,
                hasNamedSpeakers: namedSpeakerCount > 0,
                hasTranscript: !project.segments.isEmpty,
                isRecomputingTimings: isRecomputingTimings,
                onCancel: { isShowingSettings = false },
                onClearTranscript: {
                    player?.pause()
                    isPlaying = false
                    service.clearTranscript(in: project)
                    isShowingSettings = false
                },
                onRetranscribe: { speakerCount, useLabels in
                    player?.pause()
                    isPlaying = false
                    service.retranscribe(
                        project: project,
                        expectedSpeakerCount: speakerCount,
                        useLabels: useLabels
                    )
                    isShowingSettings = false
                },
                onRecomputeTimings: {
                    isShowingSettings = false
                    runRecomputeTimings(forceAll: true)
                },
                onDetectMusicBreaks: {
                    isShowingSettings = false
                    service.detectAndInsertNonSpeechBlocks(in: project)
                }
            )
        }
    }

    // MARK: - Transcript pane (extracted for type-checker speed)

    private var transcriptPane: some View {
        ZStack(alignment: .top) {
            TranscriptListView(
                project: project,
                segments: orderedSegments,
                currentTime: currentTime,
                followAlongEnabled: followAlongEnabled,
                editingSegmentID: editingSegmentID,
                currentFindMatch: currentMatchInfo,
                onSeek: { time in seek(to: time) },
                onSplit: { segment, wordIndex in
                    service.splitSegment(segment, atWordIndex: wordIndex, in: project)
                },
                onMerge: { a, b in
                    service.mergeSegments(a, b, in: project)
                },
                onMoveSelection: { segment, range, direction in
                    service.moveWords(
                        from: segment,
                        wordRange: range,
                        direction: direction,
                        in: project
                    )
                },
                onBeginEditing: { id in editingSegmentID = id },
                onCommitEditing: { segment, text in
                    let changed = service.applyTextEdit(to: segment, newText: text, in: project)
                    editingSegmentID = nil
                    if changed { rebuildFindMatches() }
                },
                onCancelEditing: { editingSegmentID = nil }
            )
            transcriptOverlays
        }
    }

    @ViewBuilder
    private var transcriptOverlays: some View {
        if isFindBarPresented {
            FindReplaceBar(
                query: $findQuery,
                replacement: $replaceWith,
                caseSensitive: $findCaseSensitive,
                matchCount: findMatches.count,
                currentIndex: currentFindMatchIndex,
                onClose: { closeFindBar() },
                onNext: { advanceFindMatch(by: 1) },
                onPrevious: { advanceFindMatch(by: -1) },
                onReplaceCurrent: { replaceCurrentMatch() },
                onReplaceAll: { replaceAllMatches() }
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        if service.projectNeedsTimingRecompute(project), !isRecomputingTimings {
            RecomputeTimingsBadge(onRecompute: { runRecomputeTimings() })
                .padding(.top, isFindBarPresented ? 80 : 12)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        if isRecomputingTimings {
            RecomputeProgressBadge(progress: recomputeProgress)
                .padding(.top, isFindBarPresented ? 80 : 12)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: - Recompute timings

    /// `forceAll` aligns every segment, not just the ones flagged
    /// `wasEdited`. The floating badge fires the default scope (edited
    /// segments only); the manual button in Transcription Settings sets
    /// `forceAll = true` so the user can resync playback even when no
    /// edits have been made.
    private func runRecomputeTimings(forceAll: Bool = false) {
        guard !isRecomputingTimings else { return }
        isRecomputingTimings = true
        recomputeProgress = 0
        Task {
            defer {
                isRecomputingTimings = false
            }
            do {
                try await service.recomputeTimings(
                    for: project,
                    includeAll: forceAll
                ) { fraction in
                    Task { @MainActor in recomputeProgress = fraction }
                }
            } catch {
                recomputeError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    // MARK: - Entity scan

    private func scheduleInitialEntityScan(force: Bool) {
        guard !hasRunInitialEntityScan || force else { return }
        guard !orderedSegments.isEmpty else { return }
        hasRunInitialEntityScan = true
        // Snapshot id+text on the main actor so the background task only
        // sees Sendable values — SwiftData @Model types aren't crossable.
        let samples = orderedSegments.filter { !$0.isNonSpeech }.map { EntityScanner.SegmentSample(id: $0.id, text: $0.text) }
        Task.detached(priority: .utility) {
            let groups = EntityScanner.scan(samples: samples)
            await MainActor.run {
                self.entityGroups = groups
            }
        }
    }

    /// Kicks off the user-facing scan in the background and presents the
    /// sheet once it lands. Uses the same Sendable-sample snapshot trick as
    /// the auto-scheduled scan so the SwiftData model never crosses the
    /// actor boundary, and toggles `isScanningEntities` so the toolbar item
    /// can render a spinner while the work is in flight — important on long
    /// transcripts where NLTagger can take a beat.
    private func runEntityScan() {
        guard !isScanningEntities else { return }
        isScanningEntities = true
        let samples = orderedSegments.filter { !$0.isNonSpeech }.map { EntityScanner.SegmentSample(id: $0.id, text: $0.text) }
        Task.detached(priority: .userInitiated) {
            let groups = EntityScanner.scan(samples: samples)
            await MainActor.run {
                self.entityGroups = groups
                self.isScanningEntities = false
                self.isEntityScanPresented = true
            }
        }
    }

    private func applyEntityActions(_ actions: [UUID: EntityAction]) {
        // Group actions by segment so we apply them in segment-bulk and only
        // call applyTextEdit once per segment. Within a segment, replacements
        // are token-level case-insensitive — punctuation attached to the
        // entity word stays put.
        var segmentReplacements: [UUID: [(from: String, to: String)]] = [:]
        for group in entityGroups {
            guard let action = actions[group.id], action.kind != .skip else { continue }
            let replacement: String
            switch action.kind {
            case .censor:
                replacement = "[CENSORED]"
            case .replace:
                let trimmed = action.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                replacement = trimmed
            case .skip:
                continue
            }
            for occurrence in group.occurrences {
                segmentReplacements[occurrence.segmentID, default: []].append(
                    (from: occurrence.text, to: replacement)
                )
            }
        }

        for segment in orderedSegments {
            guard let replacements = segmentReplacements[segment.id], !replacements.isEmpty else { continue }
            var text = segment.text
            for replacement in replacements {
                text = caseInsensitiveReplace(in: text, find: replacement.from, with: replacement.to)
            }
            // Censor + replace are pure text substitutions; they don't make
            // the underlying audio say anything new, so recomputing timings
            // wouldn't help. Keep `wasEdited` untouched so the recompute
            // popup doesn't fire spuriously.
            service.applyTextEdit(to: segment, newText: text, in: project, markEdited: false)
        }

        // The applied edits change the transcript text, so refresh both the
        // entity grouping and the find-bar match index against the new state.
        // The grouping refresh is fire-and-forget on a background task so a
        // long transcript doesn't briefly stall the main thread post-apply.
        let samples = orderedSegments.filter { !$0.isNonSpeech }.map { EntityScanner.SegmentSample(id: $0.id, text: $0.text) }
        Task.detached(priority: .utility) {
            let groups = EntityScanner.scan(samples: samples)
            await MainActor.run { self.entityGroups = groups }
        }
        rebuildFindMatches()
    }

    private func caseInsensitiveReplace(in source: String, find: String, with replacement: String) -> String {
        guard !find.isEmpty else { return source }
        var result = source
        var searchRange = result.startIndex..<result.endIndex
        while let range = result.range(of: find, options: [.caseInsensitive], range: searchRange) {
            result.replaceSubrange(range, with: replacement)
            let advance = result.index(range.lowerBound, offsetBy: replacement.count)
            searchRange = advance..<result.endIndex
        }
        return result
    }

    // MARK: - Find / replace

    private func toggleFindBar() {
        if isFindBarPresented {
            closeFindBar()
        } else {
            isFindBarPresented = true
            rebuildFindMatches()
        }
    }

    private func closeFindBar() {
        isFindBarPresented = false
        findQuery = ""
        replaceWith = ""
        findMatches = []
        currentFindMatchIndex = 0
    }

    private func rebuildFindMatches() {
        guard !findQuery.isEmpty else {
            findMatches = []
            currentFindMatchIndex = 0
            return
        }
        let options: String.CompareOptions = findCaseSensitive ? [] : [.caseInsensitive]
        var matches: [FindMatch] = []
        for segment in orderedSegments where !segment.isNonSpeech {
            var searchRange = segment.text.startIndex..<segment.text.endIndex
            while let range = segment.text.range(of: findQuery, options: options, range: searchRange) {
                matches.append(FindMatch(segmentID: segment.id, range: range))
                searchRange = range.upperBound..<segment.text.endIndex
            }
        }
        findMatches = matches
        currentFindMatchIndex = matches.isEmpty ? 0 : min(currentFindMatchIndex, matches.count - 1)
    }

    private func advanceFindMatch(by delta: Int) {
        guard !findMatches.isEmpty else { return }
        let count = findMatches.count
        currentFindMatchIndex = ((currentFindMatchIndex + delta) % count + count) % count
    }

    private func replaceCurrentMatch() {
        guard !findMatches.isEmpty,
              currentFindMatchIndex < findMatches.count else { return }
        let match = findMatches[currentFindMatchIndex]
        guard let segment = orderedSegments.first(where: { $0.id == match.segmentID }) else { return }
        var newText = segment.text
        newText.replaceSubrange(match.range, with: replaceWith)
        // Find/replace is a pure text substitution — the audio still says
        // the original word — so don't flag the segment for timing
        // recompute. The revision history still records the change.
        service.applyTextEdit(to: segment, newText: newText, in: project, markEdited: false)
        rebuildFindMatches()
        if !findMatches.isEmpty {
            currentFindMatchIndex = min(currentFindMatchIndex, findMatches.count - 1)
        }
    }

    private func replaceAllMatches() {
        guard !findMatches.isEmpty else { return }
        // Group by segment so each segment is rewritten in one pass — that
        // keeps undo/applyTextEdit semantics clean (one edit per segment per
        // replace-all action).
        let bySegment = Dictionary(grouping: findMatches, by: \.segmentID)
        for segment in orderedSegments {
            guard let matches = bySegment[segment.id], !matches.isEmpty else { continue }
            let options: String.CompareOptions = findCaseSensitive ? [] : [.caseInsensitive]
            var text = segment.text
            var searchRange = text.startIndex..<text.endIndex
            while let range = text.range(of: findQuery, options: options, range: searchRange) {
                text.replaceSubrange(range, with: replaceWith)
                let advance = text.index(range.lowerBound, offsetBy: replaceWith.count)
                searchRange = advance..<text.endIndex
            }
            service.applyTextEdit(to: segment, newText: text, in: project, markEdited: false)
        }
        rebuildFindMatches()
    }

    private var currentMatchInfo: FindMatch? {
        guard !findMatches.isEmpty,
              currentFindMatchIndex < findMatches.count else { return nil }
        return findMatches[currentFindMatchIndex]
    }

    // MARK: - Transcript text re-import

    private func runTranscriptTextReimport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Re-Import Edited Transcript Text"
        panel.message = "Choose a plain-text transcript exported from Transcripty. Differences will be applied as inline edits, segment by segment."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let summary = try service.reimportTranscriptText(from: url, into: project)
            transcriptImportSummary = summary
            rebuildFindMatches()
        } catch {
            transcriptImportError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// Spawns the save-panel + zip pipeline for `.tscripty` export. Uses
    /// `NSSavePanel` directly because `fileExporter`'s `FileDocument` route
    /// would force-load the entire archive into memory before write — fine
    /// for small text exports, costly for hundreds of megabytes of audio.
    private func runArchiveExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ProjectArchive.contentType]
        panel.nameFieldStringValue = "\(project.title).\(ProjectArchive.fileExtension)"
        panel.canCreateDirectories = true
        panel.title = "Export Project Archive"
        panel.message = "The archive bundles the audio file, transcript, speaker names, and labels into a single .tscripty file."

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExportingArchive = true
        Task {
            defer { isExportingArchive = false }
            do {
                try await service.exportArchive(project: project, to: destination)
            } catch {
                archiveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private var namedSpeakerCount: Int {
        project.speakerNames
            .values
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    // MARK: - Player lifecycle

    @MainActor
    private func loadPlayer() async {
        teardownPlayer()

        guard let url = project.sourceAudioURL else { return }
        securityAccessHeld = url.startAccessingSecurityScopedResource()
        audioURL = url

        let asset = AVURLAsset(url: url)
        let loadedDuration = (try? await asset.load(.duration).seconds) ?? 0
        duration = loadedDuration.isFinite ? loadedDuration : 0

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        let token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { time in
            Task { @MainActor in
                currentTime = max(0, time.seconds)
            }
        }
        timeObserverToken = token
        self.player = player
    }

    private func teardownPlayer() {
        if let player, let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        if securityAccessHeld, let url = audioURL {
            url.stopAccessingSecurityScopedResource()
        }
        securityAccessHeld = false
        audioURL = nil
    }

    // MARK: - Transport

    private func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            if duration > 0, currentTime >= duration - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
        }
        isPlaying.toggle()
    }

    private func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(duration, time))
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = clamped
    }
}

// MARK: - Transcription settings sheet

/// User-facing knobs for an existing project's pipeline run. Lets the user
/// change the expected speaker count after the fact, choose whether to
/// transfer their existing speaker labels onto the new run, and either
/// re-transcribe or just wipe the transcript clean for a manual restart.
private struct TranscriptionSettingsSheet: View {
    let project: TranscriptionProject
    let hasNamedSpeakers: Bool
    let hasTranscript: Bool
    /// Whether a recompute is already in flight — drives the button's
    /// spinner state so the user can't kick a second pass while one is
    /// running.
    let isRecomputingTimings: Bool
    let onCancel: () -> Void
    let onClearTranscript: () -> Void
    let onRetranscribe: (_ speakerCount: Int?, _ useLabels: Bool) -> Void
    let onRecomputeTimings: () -> Void
    let onDetectMusicBreaks: () -> Void

    @State private var speakerCountSelection: Int?
    @State private var useLabels: Bool
    @State private var isConfirmingClear = false

    init(
        project: TranscriptionProject,
        hasNamedSpeakers: Bool,
        hasTranscript: Bool,
        isRecomputingTimings: Bool,
        onCancel: @escaping () -> Void,
        onClearTranscript: @escaping () -> Void,
        onRetranscribe: @escaping (_ speakerCount: Int?, _ useLabels: Bool) -> Void,
        onRecomputeTimings: @escaping () -> Void,
        onDetectMusicBreaks: @escaping () -> Void
    ) {
        self.project = project
        self.hasNamedSpeakers = hasNamedSpeakers
        self.hasTranscript = hasTranscript
        self.isRecomputingTimings = isRecomputingTimings
        self.onCancel = onCancel
        self.onClearTranscript = onClearTranscript
        self.onRetranscribe = onRetranscribe
        self.onRecomputeTimings = onRecomputeTimings
        self.onDetectMusicBreaks = onDetectMusicBreaks
        _speakerCountSelection = State(initialValue: project.expectedSpeakerCount)
        _useLabels = State(initialValue: hasNamedSpeakers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription Settings")
                    .font(.title3.weight(.semibold))
                Text("Adjust how this project is transcribed and re-run the pipeline.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            speakerCountSection

            if hasNamedSpeakers {
                labelsSection
            }

            if hasTranscript {
                Divider()
                wordTimingSection
                Divider()
                musicBreaksSection
                Divider()
                clearSection
            }

            Spacer(minLength: 8)

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    onRetranscribe(speakerCountSelection, useLabels && hasNamedSpeakers)
                } label: {
                    Label("Re-Transcribe", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .confirmationDialog(
            "Clear this project's transcript?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Transcript", role: .destructive, action: onClearTranscript)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Removes the segments, edit history, and speaker names. The audio file stays in the project so you can transcribe it again.")
        }
    }

    private var speakerCountSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Expected Speakers")
                .font(.subheadline.weight(.semibold))
            Picker("Expected Speakers", selection: $speakerCountSelection) {
                Text("Auto").tag(Int?.none)
                ForEach([1, 2, 3, 4, 5], id: \.self) { n in
                    Text("\(n)").tag(Int?.some(n))
                }
                Text("6+").tag(Int?.some(6))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Pinning the speaker count constrains the diarizer to that many voices, which dramatically improves separation when you know how many people are in the recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var labelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $useLabels) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apply my speaker names")
                        .font(.subheadline.weight(.semibold))
                    Text("Carries the names you've already set onto the new run, using overlap and voice-print matching.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
    }

    /// Re-runs music-gap detection on demand. The pipeline runs this
    /// automatically once at the end of initial transcription, but if
    /// the user merges/splits/moves around segments the gap topology
    /// changes — letting them re-detect catches new music interludes
    /// without forcing a full re-transcribe. Idempotent: existing
    /// `[MUSIC]` blocks are preserved, new ones added only where new
    /// gaps now exist.
    private var musicBreaksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Music & Silence Breaks")
                .font(.subheadline.weight(.semibold))
            Text("Inserts a non-editable [MUSIC] block for any gap longer than three seconds between speech segments. The block anchors playback timings on either side so seeking onto the first word after a music interlude lands on the right syllable.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onDetectMusicBreaks()
            } label: {
                Label("Detect Music Breaks", systemImage: "music.note.list")
            }
            .buttonStyle(.bordered)
        }
    }

    /// Always-available "Recompute Word Timings" affordance. The editor
    /// also shows the floating badge automatically when at least one
    /// segment has been edited, but having a manual button here lets the
    /// user force a fresh forced-alignment pass even when nothing is
    /// flagged — useful when playback feels visually out of sync but the
    /// underlying flags say everything's fine.
    private var wordTimingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Word Timing Alignment")
                .font(.subheadline.weight(.semibold))
            Text("Re-extracts each segment's audio and re-runs the recognizer to refresh per-word playback timings. Use this when the playback highlight feels misaligned with what's being spoken.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onRecomputeTimings()
            } label: {
                if isRecomputingTimings {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Recomputing…")
                    }
                } else {
                    Label("Recompute Word Timings", systemImage: "waveform.path.badge.plus")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isRecomputingTimings)
        }
    }

    private var clearSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reset")
                .font(.subheadline.weight(.semibold))
            HStack {
                Text("Wipe the transcript without re-running the pipeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(role: .destructive) {
                    isConfirmingClear = true
                } label: {
                    Label("Clear Transcript", systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - Pending state CTA

/// Shown when the project has no transcript and no in-flight job — typically
/// after the user has cleared the transcript via Transcription Settings. Lets
/// them kick off a fresh run without leaving the editor.
private struct PendingTranscriptionView: View {
    let expectedSpeakerCount: Int?
    let onStart: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            Text("No Transcript Yet")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button {
                    onOpenSettings()
                } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                Button {
                    onStart()
                } label: {
                    Label("Start Transcription", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var message: String {
        switch expectedSpeakerCount {
        case .none:
            return "The project's audio is ready to transcribe. The diarizer will auto-detect how many speakers are present."
        case .some(let n):
            let suffix = n == 1 ? "" : "s"
            return "The project's audio is ready to transcribe. It's currently set to \(n) speaker\(suffix); change this in Settings if needed."
        }
    }
}

// MARK: - Transcript list

private struct TranscriptListView: View {
    let project: TranscriptionProject
    let segments: [SpeakerSegment]
    let currentTime: TimeInterval
    /// When false, the active-segment / active-word highlight and the
    /// playback-driven auto-scroll are suppressed. Audio still plays — this
    /// only quiets the transcript so the user can edit without the view
    /// chasing the playhead.
    let followAlongEnabled: Bool
    let editingSegmentID: UUID?
    let currentFindMatch: FindMatch?
    let onSeek: (TimeInterval) -> Void
    let onSplit: (SpeakerSegment, Int) -> Void
    let onMerge: (SpeakerSegment, SpeakerSegment) -> Void
    let onMoveSelection: (SpeakerSegment, Range<Int>, TranscriptionService.MergeDirection) -> Void
    let onBeginEditing: (UUID) -> Void
    let onCommitEditing: (SpeakerSegment, String) -> Void
    let onCancelEditing: () -> Void

    /// Minimum gap between intra-segment word scrolls. Every word change would
    /// otherwise stack scrollTo animations (3–5/sec during fast speech), which
    /// reads as jittery. 1.5 s lets long monologues still creep forward while
    /// keeping the scroll visually calm.
    private static let wordScrollInterval: TimeInterval = 1.5

    @State private var lastScrolledSegmentID: UUID?
    @State private var lastWordScrollAt: Date = .distantPast
    /// Range of words the user has selected within a single segment. A
    /// single-word selection is the split point (Return splits there). A
    /// multi-word selection (built up via shift-click) enables the "move
    /// to previous/next speaker" affordances when it forms a clean prefix
    /// or suffix of the segment.
    @State private var wordSelection: WordSelection?
    /// Buffer for text being typed in front of a clicked word. Non-nil only
    /// while the user is mid-insertion: opens on the first printable
    /// keystroke after a single-point selection, closes on commit (Return),
    /// cancel (Escape), or when the selection moves to a different anchor
    /// (auto-commit, like clicking elsewhere in a normal text editor).
    @State private var inlineInsertion: InlineInsertion?
    @FocusState private var transcriptFocused: Bool

    private var activeSegment: SpeakerSegment? {
        guard followAlongEnabled else { return nil }
        return segments.first(where: { $0.contains(time: currentTime) })
    }

    private var activeWordAnchor: String? {
        guard followAlongEnabled,
              let active = activeSegment,
              let idx = active.activeWordIndex(at: currentTime) else { return nil }
        return "\(active.id.uuidString)-word-\(idx)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if segments.isEmpty {
                        ContentUnavailableView(
                            "Transcription Pending",
                            systemImage: "text.append",
                            description: Text("This project has no transcript yet.")
                        )
                        .padding(.top, 60)
                    } else {
                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                            let localSelection = wordSelection?.segmentID == segment.id ? wordSelection : nil
                            let localInsertion = inlineInsertion?.segmentID == segment.id ? inlineInsertion : nil
                            SegmentRow(
                                project: project,
                                segment: segment,
                                // Neighbor lookup skips over [MUSIC] /
                                // non-speech rows so "Merge with previous"
                                // and word-move affordances bridge across
                                // an interlude to the nearest *speech*
                                // segment instead of trying to merge into
                                // a music block.
                                previousSegment: (0..<index).reversed()
                                    .first(where: { !segments[$0].isNonSpeech })
                                    .map { segments[$0] },
                                nextSegment: ((index + 1)..<segments.count)
                                    .first(where: { !segments[$0].isNonSpeech })
                                    .map { segments[$0] },
                                currentTime: currentTime,
                                isActive: followAlongEnabled && segment.contains(time: currentTime),
                                selectionRange: localSelection?.range,
                                splitCaretIndex: localSelection?.splitCaretIndex,
                                inlineInsertion: localInsertion,
                                isEditing: editingSegmentID == segment.id,
                                findHighlightRange: currentFindMatch?.segmentID == segment.id
                                    ? currentFindMatch?.range : nil,
                                onSeek: onSeek,
                                onWordTap: { wordIndex, extending in
                                    handleWordTap(segment: segment, wordIndex: wordIndex, extending: extending)
                                },
                                onMerge: onMerge,
                                onMoveSelection: { direction in
                                    handleMoveSelection(segment: segment, direction: direction)
                                },
                                onBeginEditing: { onBeginEditing(segment.id) },
                                onCommitEditing: { newText in
                                    onCommitEditing(segment, newText)
                                    // Drop any caret/word selection so the
                                    // row visually settles back to "no
                                    // active interaction" once the user's
                                    // edit lands.
                                    wordSelection = nil
                                },
                                onCancelEditing: onCancelEditing
                            )
                            .id(segment.id.uuidString)
                        }
                    }
                }
                .padding()
            }
            .focusable()
            .focused($transcriptFocused)
            // Delete / Forward-Delete go through the AppKit-level monitor
            // because SwiftUI's `.onKeyPress` is intercepted by the AppKit
            // responder chain for those keys (system beep, no event). The
            // SwiftUI `.onKeyPress` hooks below still cover Escape, Return,
            // and printable input.
            .background(
                DeleteKeyMonitor { handleDeleteKey() }
            )
            .modifier(TranscriptKeyHandlers(
                onControlKey: handleEditorKeyPress,
                onPrintable: { keyPress in
                    switch keyPress.key {
                    case .delete, .deleteForward, .escape, .return:
                        return .ignored
                    default:
                        return handleEditorKeyPress(keyPress)
                    }
                }
            ))
            // Auto-commit any in-progress inline insertion when the user
            // moves the selection (clicks a different word, shift-extends,
            // or clears it). Mirrors how clicking elsewhere in a normal
            // text editor commits typing rather than dropping it on the floor.
            .onChange(of: wordSelection) { _, newValue in
                guard let ins = inlineInsertion else { return }
                if let sel = newValue,
                   sel.isPoint,
                   sel.segmentID == ins.segmentID,
                   sel.anchor == ins.beforeWordIndex {
                    return
                }
                commitInlineInsertion()
            }
            // Segment changes scroll immediately — that's the speaker-turn cue
            // the viewer expects to see.
            .onChange(of: activeSegment?.id) { _, newID in
                guard let newID, newID != lastScrolledSegmentID else { return }
                lastScrolledSegmentID = newID
                lastWordScrollAt = .now
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(newID.uuidString, anchor: .center)
                }
            }
            // Word changes scroll at most once per `wordScrollInterval`, so
            // long monologues still creep forward without fighting animations.
            .onChange(of: activeWordAnchor) { _, newValue in
                guard let newValue else { return }
                let now = Date()
                guard now.timeIntervalSince(lastWordScrollAt) >= Self.wordScrollInterval else { return }
                lastWordScrollAt = now
                withAnimation(.easeInOut(duration: 0.5)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func performSplit() -> Bool {
        guard let sel = wordSelection,
              sel.isPoint,
              let segment = segments.first(where: { $0.id == sel.segmentID }),
              let splitIdx = sel.splitCaretIndex,
              splitIdx > 0,
              splitIdx < segment.words.count else { return false }
        onSplit(segment, splitIdx)
        wordSelection = nil
        return true
    }

    /// Routes every key press the transcript area receives. Inline insertion
    /// (Return/Escape/Backspace/printable chars) wins when there's a single-
    /// point selection; otherwise Return falls through to the existing split
    /// behavior, and everything else is ignored so system shortcuts (⌘Z,
    /// ⌘F, …) still reach their handlers.
    private func handleEditorKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        // Don't compete with the per-segment TextField when it's focused.
        guard editingSegmentID == nil else { return .ignored }

        // Escape clears any active buffer; if there's no buffer it's not ours.
        if keyPress.key == .escape {
            guard inlineInsertion != nil else { return .ignored }
            inlineInsertion = nil
            return .handled
        }

        // Return commits when buffer is non-empty, otherwise it falls back to
        // the split behavior so single-click + Return still splits at caret.
        if keyPress.key == .return {
            if inlineInsertion != nil {
                commitInlineInsertion()
                return .handled
            }
            return performSplit() ? .handled : .ignored
        }

        // Backspace (.delete) and Forward-Delete (.deleteForward) have two
        // jobs in this view, prioritized in order:
        //  1. Trim the in-progress inline insertion buffer when active —
        //     same as any other text editor.
        //  2. Otherwise, delete the currently-selected word(s) from the
        //     segment. Single-click selects one word; shift-click extends to
        //     a range. Both delete via `applyTextEdit`, which preserves
        //     surviving word timings via LCS reconciliation.
        // Forward-delete is treated identically to backspace because the
        // buffer's cursor sits at the trailing end and a word selection
        // doesn't have a directional cursor.
        if keyPress.key == .delete || keyPress.key == .deleteForward {
            if var ins = inlineInsertion, !ins.text.isEmpty {
                ins.text.removeLast()
                // Empty buffer collapses back to "no insertion in progress"
                // so a stray Esc doesn't have to fire to leave the mode.
                inlineInsertion = ins.text.isEmpty ? nil : ins
                return .handled
            }
            if deleteSelectedWords() {
                return .handled
            }
            return .ignored
        }

        // Printable input opens (or extends) the buffer. Anchored to the
        // current single-point WordSelection. ⌘ / ⌃ chords are reserved for
        // shortcuts; ⌥ stays through so option-letter unicode (é, etc.)
        // still types as expected.
        if keyPress.modifiers.contains(.command) || keyPress.modifiers.contains(.control) {
            return .ignored
        }
        guard let sel = wordSelection, sel.isPoint else { return .ignored }
        guard !keyPress.characters.isEmpty,
              !keyPress.characters.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else { return .ignored }

        if var ins = inlineInsertion,
           ins.segmentID == sel.segmentID,
           ins.beforeWordIndex == sel.anchor {
            ins.text.append(keyPress.characters)
            inlineInsertion = ins
        } else {
            inlineInsertion = InlineInsertion(
                segmentID: sel.segmentID,
                beforeWordIndex: sel.anchor,
                text: keyPress.characters
            )
        }
        return .handled
    }

    /// AppKit-level Delete handler invoked by `DeleteKeyMonitor`. Same logic
    /// as the Delete branch in `handleEditorKeyPress`, but lives here so the
    /// NSEvent path can run independently of SwiftUI's key-press routing
    /// (which doesn't reliably catch Delete on macOS — see the monitor's
    /// header doc). Returns `true` when the press was consumed so the
    /// monitor can swallow the event and avoid the system beep.
    private func handleDeleteKey() -> Bool {
        guard editingSegmentID == nil else { return false }
        if var ins = inlineInsertion, !ins.text.isEmpty {
            ins.text.removeLast()
            inlineInsertion = ins.text.isEmpty ? nil : ins
            return true
        }
        return deleteSelectedWords()
    }

    /// Removes the currently-selected word range from its segment. Single-
    /// point selections drop one word; shift-extended ranges drop the whole
    /// span. Returns true when a deletion (or the special-case merge below)
    /// was actually applied so the caller can mark the keypress handled.
    ///
    /// Special case: a single-point selection at the very first word of a
    /// segment that isn't the first segment in the project triggers a
    /// **merge with the previous segment** instead of dropping the word.
    /// This mirrors the Backspace-at-start-of-paragraph behavior in
    /// standard word processors — the click + Delete reads as "this turn
    /// shouldn't have been split here, glue it to the previous one." A
    /// shift-extended range starting at word 0 is *not* treated this way
    /// because the user explicitly selected a range and expects a delete.
    @discardableResult
    private func deleteSelectedWords() -> Bool {
        guard let sel = wordSelection,
              let segmentIndex = segments.firstIndex(where: { $0.id == sel.segmentID }) else {
            return false
        }
        let segment = segments[segmentIndex]
        let range = sel.range
        guard !range.isEmpty,
              range.lowerBound >= 0,
              range.upperBound <= segment.words.count else {
            return false
        }

        if sel.isPoint, sel.anchor == 0, segmentIndex > 0 {
            let previous = segments[segmentIndex - 1]
            wordSelection = nil
            onMerge(previous, segment)
            return true
        }

        var newWords = segment.words.map(\.text)
        newWords.removeSubrange(range)
        let newText = newWords.joined(separator: " ")
        // applyTextEdit handles the empty-segment case (segment goes blank
        // but stays in the list — user can merge with a neighbor or undo).
        onCommitEditing(segment, newText)
        wordSelection = nil
        return true
    }

    /// Flushes the in-progress buffer into the segment's text. The buffer is
    /// inserted in front of the anchored word; existing words are unchanged
    /// so LCS reconciliation in `applyTextEdit` preserves their timings.
    /// Clears the word selection on success so the caret-style highlight
    /// goes away — the user has finished interacting with that word.
    private func commitInlineInsertion() {
        guard let ins = inlineInsertion else { return }
        defer { inlineInsertion = nil }
        let trimmed = ins.text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let segment = segments.first(where: { $0.id == ins.segmentID }) else { return }
        let safeIndex = max(0, min(ins.beforeWordIndex, segment.words.count))
        let words = segment.words.map(\.text)
        var newWords: [String] = []
        newWords.append(contentsOf: words.prefix(safeIndex))
        newWords.append(trimmed)
        newWords.append(contentsOf: words.suffix(from: safeIndex))
        let newText = newWords.joined(separator: " ")
        onCommitEditing(segment, newText)
        wordSelection = nil
    }

    /// Click handler shared by every WordTile. `extending` is true when the
    /// click happened with the Shift key held — that grows the existing
    /// selection's anchor/extend pair rather than starting fresh.
    private func handleWordTap(segment: SpeakerSegment, wordIndex: Int, extending: Bool) {
        if extending,
           var current = wordSelection,
           current.segmentID == segment.id {
            current.extend = wordIndex
            wordSelection = current
        } else {
            wordSelection = WordSelection(
                segmentID: segment.id,
                anchor: wordIndex,
                extend: wordIndex
            )
        }
        transcriptFocused = true
    }

    private func handleMoveSelection(segment: SpeakerSegment, direction: MoveSelectionDirection) {
        guard let sel = wordSelection,
              sel.segmentID == segment.id else { return }
        let mapped: TranscriptionService.MergeDirection = direction == .previous ? .previous : .next
        wordSelection = nil
        onMoveSelection(segment, sel.range, mapped)
    }
}

/// Shared word selection model. Anchor/extend mirror NSText's notion so
/// shift-click can grow in either direction. `range` collapses them into a
/// half-open span; `splitCaretIndex` is non-nil only for single-word
/// selections (the same point that Return splits at).
struct WordSelection: Equatable {
    let segmentID: UUID
    var anchor: Int
    var extend: Int

    var isPoint: Bool { anchor == extend }
    var range: Range<Int> {
        let lo = min(anchor, extend)
        let hi = max(anchor, extend)
        return lo..<(hi + 1)
    }
    var splitCaretIndex: Int? { isPoint ? anchor : nil }
}

/// In-progress text being typed in front of a clicked word. Lives only in the
/// editor's transient UI state — committing flushes the buffer through the
/// regular text-edit pipeline (LCS reconciliation preserves all surrounding
/// word timings; the inserted tokens get interpolated timings until the user
/// runs Recompute Timings).
struct InlineInsertion: Equatable {
    let segmentID: UUID
    /// Word index in front of which the buffer will be inserted. Equals the
    /// anchor of the single-point WordSelection that opened the buffer.
    let beforeWordIndex: Int
    var text: String
}

enum MoveSelectionDirection: Equatable {
    case previous
    case next
}

private struct SegmentRow: View {
    let project: TranscriptionProject
    let segment: SpeakerSegment
    /// Segment immediately before this one in the chronological order, when
    /// one exists. Used to offer "Merge with Previous" in the context menu.
    let previousSegment: SpeakerSegment?
    /// Segment immediately after this one, mirror of `previousSegment`.
    let nextSegment: SpeakerSegment?
    let currentTime: TimeInterval
    let isActive: Bool
    /// Word indices currently selected within *this* segment, if any. Drives
    /// the highlight + the floating "Move to previous/next speaker" panel.
    let selectionRange: Range<Int>?
    /// Set when the selection collapses to a single point — that's where
    /// pressing Return splits, and also where the row paints its caret.
    let splitCaretIndex: Int?
    /// In-progress inline insertion buffer for *this* segment (nil otherwise).
    /// Renders as a tinted tile in front of the anchored word so the user
    /// can see what they're typing before they commit.
    let inlineInsertion: InlineInsertion?
    let isEditing: Bool
    /// When non-nil, the row paints this character range with a highlight to
    /// surface the current find/replace match. Restricted to the row whose
    /// segment owns the match — siblings render normally.
    let findHighlightRange: Range<String.Index>?
    let onSeek: (TimeInterval) -> Void
    let onWordTap: (_ wordIndex: Int, _ extending: Bool) -> Void
    let onMerge: (SpeakerSegment, SpeakerSegment) -> Void
    let onMoveSelection: (MoveSelectionDirection) -> Void
    let onBeginEditing: () -> Void
    let onCommitEditing: (String) -> Void
    let onCancelEditing: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(TranscriptionService.self) private var service
    @Environment(SpeakerVoicePrintService.self) private var voicePrintService
    @State private var isEditingName = false
    @State private var draftName = ""
    @State private var draftText = ""
    @FocusState private var textFieldFocused: Bool

    private var displayName: String {
        project.displayName(forSpeakerID: segment.speakerID)
    }

    private var activeWordIndex: Int? {
        isActive ? segment.activeWordIndex(at: currentTime) : nil
    }

    /// Worst (lowest-quality) word-timing grade across the segment's words.
    /// Drives the small inline indicator next to the timestamp; the editor
    /// only renders the dot when this is `.approximate` or `.interpolated`
    /// so a fully-verified segment shows nothing extra.
    private var aggregateAlignmentQuality: WordTimingQuality {
        guard !segment.words.isEmpty else { return .unverified }
        var worst: WordTimingQuality = .verified
        let order: [WordTimingQuality] = [.verified, .approximate, .unverified, .interpolated]
        for word in segment.words {
            if order.firstIndex(of: word.quality) ?? 0 > order.firstIndex(of: worst) ?? 0 {
                worst = word.quality
            }
        }
        return worst
    }

    /// Small inline marker next to the timestamp that signals when this
    /// segment's word timings haven't been (or couldn't be) fully verified.
    /// Shown only when at least one word is `.interpolated` or
    /// `.approximate` — fully `.verified` segments and never-recomputed
    /// segments show nothing, so the indicator stays out of the way.
    @ViewBuilder
    private var alignmentQualityDot: some View {
        switch aggregateAlignmentQuality {
        case .interpolated:
            Circle()
                .fill(.orange.opacity(0.6))
                .frame(width: 5, height: 5)
                .help("Some word timings in this segment are interpolated — seeking on those words may drift. Recompute Word Timings (Settings) often fixes this.")
        case .approximate:
            Circle()
                .fill(.yellow.opacity(0.6))
                .frame(width: 5, height: 5)
                .help("Word timings here are recognizer-based but not fully corroborated by silence-boundary detection. Seeking is usually accurate but may be off by tens of milliseconds on a few words.")
        case .verified, .unverified:
            EmptyView()
        }
    }

    /// The split candidate (if any) that lands *before* the given word
    /// index. Used by the WordFlow render loop to inject inline speaker-
    /// change markers between specific words.
    private func splitCandidate(at wordIndex: Int) -> SpeakerVoicePrintService.SplitCandidate? {
        guard case .results(let candidates) = voicePrintService.detectionState(for: segment.id) else {
            return nil
        }
        return candidates.first(where: { $0.beforeWordIndex == wordIndex })
    }

    var body: some View {
        if segment.isNonSpeech {
            // Non-speech blocks have their own view — no speaker, no edit
            // controls, no word interaction. They sit between speech rows
            // and represent music/silence interludes.
            MusicBlockRow(
                segment: segment,
                onDelete: { service.deleteSegment(segment, in: project) },
                onSeek: { onSeek(segment.startSeconds) }
            )
        } else {
            speakerSegmentBody
        }
    }

    @ViewBuilder
    private var speakerSegmentBody: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                Button {
                    draftName = displayName
                    isEditingName = true
                } label: {
                    Text(displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .underline(isEditingName, color: .secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Rename speaker")
                .popover(isPresented: $isEditingName, arrowEdge: .trailing) {
                    renamePopover
                }
                HStack(spacing: 4) {
                    Text(TranscriptExporter.timestamp(segment.startSeconds))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    alignmentQualityDot
                }
                if segment.wasEdited {
                    Text("edited")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Text was edited; word timings are interpolated until you Recompute Timings.")
                }
                Button {
                    if isEditing {
                        onCancelEditing()
                    } else {
                        draftText = segment.text
                        onBeginEditing()
                    }
                } label: {
                    Image(systemName: isEditing ? "checkmark.circle.fill" : "pencil")
                        .font(.caption)
                        .foregroundStyle(isEditing
                                         ? AnyShapeStyle(.tint)
                                         : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help(isEditing ? "Cancel edit" : "Edit text (⌘E or double-click)")
            }
            .frame(width: 90, alignment: .trailing)

            VStack(alignment: .leading, spacing: 6) {
                transcriptBody
                    .padding(10)
                    .background(isActive ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isEditing ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                                           lineWidth: isEditing ? 1 : 0)
                    )
                    .contextMenu { contextMenuContent }
                moveSelectionBar
                relabelSuggestionBar
                mixedSpeakerBar
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .animation(.easeInOut(duration: 0.15), value: isEditing)
        .onChange(of: isEditing) { _, editing in
            if editing {
                draftText = segment.text
                textFieldFocused = true
            }
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button {
            draftText = segment.text
            onBeginEditing()
        } label: {
            Label("Edit Text…", systemImage: "pencil")
        }
        if segment.originalWords?.isEmpty == false {
            Button {
                service.restoreOriginalWordTimings(for: segment, in: project)
            } label: {
                Label("Restore Original Word Timings", systemImage: "arrow.counterclockwise.circle")
            }
            .help("Roll this segment's word timings back to the recognizer's original output. Useful when an alignment-verification pass produced worse results than the originals.")
        }
        Divider()
        mergeMenuContent
        Divider()
        Button(role: .destructive) {
            service.deleteSegment(segment, in: project)
        } label: {
            Label("Delete Block", systemImage: "trash")
        }
        .help("Delete this entire segment. Undoable from the Undo button or ⌘Z.")
    }

    /// Floating bar offering "Move … to Previous/Next Speaker" when the
    /// user has shift-extended a multi-word selection that forms a clean
    /// prefix or suffix of this segment. Hidden when the selection is a
    /// single point (Return still splits there) or when the prefix/suffix
    /// rule isn't met (a slice from the middle would orphan text).
    @ViewBuilder
    private var moveSelectionBar: some View {
        if let range = selectionRange,
           range.count > 1,
           range.upperBound <= segment.words.count {
            let canMovePrev = range.lowerBound == 0 && previousSegment != nil
            let canMoveNext = range.upperBound == segment.words.count && nextSegment != nil
            if canMovePrev || canMoveNext {
                HStack(spacing: 8) {
                    Image(systemName: "selection.pin.in.out")
                        .foregroundStyle(.tint)
                    Text("\(range.count) words selected")
                        .font(.caption.weight(.medium))
                    Spacer()
                    if canMovePrev, let prev = previousSegment {
                        Button {
                            onMoveSelection(.previous)
                        } label: {
                            Label(
                                "Move to \(project.displayName(forSpeakerID: prev.speakerID))",
                                systemImage: "arrow.up.to.line.compact"
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                    if canMoveNext, let next = nextSegment {
                        Button {
                            onMoveSelection(.next)
                        } label: {
                            Label(
                                "Move to \(project.displayName(forSpeakerID: next.speakerID))",
                                systemImage: "arrow.down.to.line.compact"
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.tint.opacity(0.4), lineWidth: 0.5))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Inline relabel-suggestion pill. Shown when the project's per-speaker
    /// voice-print centroids point at a different speaker more confidently
    /// than this segment's currently-assigned label. Two affordances:
    ///   * **Reassign** — accept the suggestion. Calls
    ///     `service.relabelSegment` which updates the speakerID, records an
    ///     undoable `.segmentSpeakerChanged` edit, and triggers a centroid
    ///     recompute (so adjacent segments re-evaluate against the now-
    ///     slightly-pulled centroids).
    ///   * **Dismiss** — confirm the current label is correct. Calls
    ///     `service.dismissRelabelSuggestion` which suppresses the pill for
    ///     this segment and weights it 2× toward the current speaker on
    ///     the next centroid recompute. That positive evidence tightens
    ///     the centroid for future suggestions on *other* segments.
    /// Editing modes hide the pill so it doesn't compete with the edit
    /// affordances; a suggestion pill while typing would be visually busy.
    @ViewBuilder
    private var relabelSuggestionBar: some View {
        if !isEditing,
           selectionRange == nil,
           inlineInsertion == nil,
           let suggestion = voicePrintService.suggestion(for: segment, in: project) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.tint)
                Text("Sounds more like \(suggestion.suggestedDisplayName)?")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    service.relabelSegment(segment, toSpeakerID: suggestion.suggestedSpeakerID, in: project)
                } label: {
                    Label("Reassign", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .help(String(format: "Reassign this segment to %@ (similarity %.2f vs. %.2f).",
                             suggestion.suggestedDisplayName,
                             suggestion.suggestedSimilarity,
                             suggestion.currentSimilarity))
                Button {
                    service.dismissRelabelSuggestion(for: segment, in: project)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .help("Dismiss — keep this segment as \(project.displayName(forSpeakerID: segment.speakerID)). The voice-print model will weight this segment toward the current speaker.")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.tint.opacity(0.3), lineWidth: 0.5))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Mid-segment speaker-change pill (Path B). Has four states the user
    /// can land in:
    ///   1. **Idle flag** — voice-print heuristic flagged this segment as
    ///      potentially mixed. User can click "Detect" to run the diarizer
    ///      on the segment's audio range, or dismiss the flag.
    ///   2. **Running** — diarizer is loading + processing. Spinner only;
    ///      no buttons. Worth a beat: the diarizer reloads its CoreML
    ///      models per call (FluidAudio doesn't expose a public cache),
    ///      so the first few seconds are model-load.
    ///   3. **No changes found** — diarizer didn't see a second speaker
    ///      inside this segment. User can dismiss to mark the segment
    ///      as checked.
    ///   4. **Failed** — audio missing, diarizer error, etc. Dismissable.
    ///
    /// The "results" state is *not* shown as a pill — split candidates
    /// render as inline markers between words inside the WordFlow itself
    /// so the user picks the actual split point inline.
    /// Hidden during edit / selection / typing modes for the same reason
    /// as the other pills: no point competing with the user's active
    /// interaction.
    @ViewBuilder
    private var mixedSpeakerBar: some View {
        if !isEditing,
           selectionRange == nil,
           inlineInsertion == nil {
            let detectionState = voicePrintService.detectionState(for: segment.id)
            switch detectionState {
            case .running:
                mixedSpeakerPill {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Analyzing speakers in this segment…")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                }
            case .noChangesFound:
                mixedSpeakerPill {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.tint)
                        Text("No speaker changes detected.")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Button {
                            voicePrintService.clearDetectionState(for: segment.id)
                            service.markMixedSpeakerSegmentChecked(segment, in: project)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.bordered)
                        .help("Dismiss")
                    }
                }
            case .failed(let message):
                mixedSpeakerPill {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Couldn't analyze: \(message)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            voicePrintService.clearDetectionState(for: segment.id)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.bordered)
                        .help("Dismiss")
                    }
                }
            case .results, .none:
                // Idle flag only when no detection has run. Suppress when
                // results are present (those render as inline markers
                // inside the WordFlow instead).
                if detectionState == nil,
                   voicePrintService.mixedSpeakerCandidate(for: segment, in: project) {
                    mixedSpeakerPill {
                        HStack(spacing: 8) {
                            Image(systemName: "person.2.wave.2")
                                .foregroundStyle(.tint)
                            Text("This segment may contain multiple speakers.")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            Button {
                                Task {
                                    await voicePrintService.detectSpeakerChanges(for: segment, in: project)
                                    // After detection settles, mark the
                                    // segment as checked so the idle flag
                                    // doesn't reappear if the user dismisses
                                    // results without splitting. Only mark
                                    // checked on success; failure leaves
                                    // the flag available so they can retry.
                                    if let state = voicePrintService.detectionState(for: segment.id),
                                       case .failed = state {
                                        return
                                    }
                                    service.markMixedSpeakerSegmentChecked(segment, in: project)
                                }
                            } label: {
                                Label("Detect", systemImage: "waveform.badge.magnifyingglass")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.bordered)
                            .help("Run a focused diarization pass on this segment's audio. Takes a few seconds — the speaker-detection model has to load before analyzing.")
                            Button {
                                service.markMixedSpeakerSegmentChecked(segment, in: project)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.bordered)
                            .help("Dismiss — don't ask again on this segment.")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func mixedSpeakerPill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.tint.opacity(0.3), lineWidth: 0.5))
            .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Context-menu items for combining this segment with a neighbor. The
    /// menu hides entirely when the segment has no neighbors (single-segment
    /// projects), so right-clicking doesn't show an empty menu.
    @ViewBuilder
    private var mergeMenuContent: some View {
        if previousSegment != nil || nextSegment != nil {
            if let prev = previousSegment {
                Button {
                    onMerge(prev, segment)
                } label: {
                    Label(
                        "Merge with Previous (\(project.displayName(forSpeakerID: prev.speakerID)))",
                        systemImage: "arrow.up.to.line.compact"
                    )
                }
            }
            if let next = nextSegment {
                Button {
                    onMerge(segment, next)
                } label: {
                    Label(
                        "Merge with Next (\(project.displayName(forSpeakerID: next.speakerID)))",
                        systemImage: "arrow.down.to.line.compact"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if isEditing {
            editorBody
        } else if findHighlightRange != nil || segment.words.isEmpty {
            // Find/replace shows the segment as plain text so the highlight
            // can land on the exact character range. Empty `words` (legacy
            // import or post-edit row with no aligned timings) also falls
            // through here — the seek-on-tap still jumps to segment start.
            highlightedText
                .font(.body)
                .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    draftText = segment.text
                    onBeginEditing()
                }
                .onTapGesture { onSeek(segment.startSeconds) }
        } else {
            WordFlow(spacing: 4, lineSpacing: 6) {
                ForEach(Array(segment.words.enumerated()), id: \.offset) { index, word in
                    if let ins = inlineInsertion, ins.beforeWordIndex == index {
                        InlineInsertionTile(text: ins.text)
                    }
                    if let candidate = splitCandidate(at: index) {
                        SplitCandidateMarker(
                            candidate: candidate,
                            onAccept: {
                                _ = service.acceptSpeakerChangeCandidate(
                                    wordIndex: candidate.beforeWordIndex,
                                    suggestedSpeakerID: candidate.suggestedSpeakerID,
                                    in: segment,
                                    in: project
                                )
                                // The split rewrites segment.id territory;
                                // clear cached results so the post-split
                                // halves can be re-evaluated independently.
                                voicePrintService.clearDetectionState(for: segment.id)
                            },
                            onDismiss: {
                                voicePrintService.dismissCandidate(candidate, for: segment.id)
                            }
                        )
                    }
                    if isCensoredToken(word.text) {
                        // iMessage-style "invisible ink": animated particle
                        // veil obscures the [CENSORED] core, but any suffix
                        // the entity replacement left behind ("'s", "s",
                        // sentence-ending punctuation, …) renders as plain
                        // text right after the bubble so the grammar still
                        // reads. Click-to-seek covers the whole composite.
                        let parts = splitCensoredToken(word.text)
                        HStack(spacing: 0) {
                            CensoredInkBubble(placeholder: parts.bubble)
                            if !parts.suffix.isEmpty {
                                Text(parts.suffix)
                                    .font(.body)
                                    .foregroundStyle(isActive
                                                     ? AnyShapeStyle(.primary)
                                                     : AnyShapeStyle(.secondary))
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onSeek(word.start) }
                        .id("\(segment.id.uuidString)-word-\(index)")
                    } else {
                        WordTile(
                            text: word.text,
                            isActive: index == activeWordIndex,
                            isSelected: selectionRange?.contains(index) ?? false,
                            isCaret: splitCaretIndex == index && index > 0,
                            isDimmed: !isActive,
                            canSplit: index > 0
                        ) {
                            // Shift-click extends the selection so the user
                            // can grab a multi-word run for the move-to-
                            // previous/next-speaker affordance. Plain click
                            // is the existing seek + split-point selection.
                            let extending = NSEvent.modifierFlags.contains(.shift)
                            if !extending { onSeek(word.start) }
                            onWordTap(index, extending)
                        }
                        .id("\(segment.id.uuidString)-word-\(index)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                draftText = segment.text
                onBeginEditing()
            }
        }
    }

    /// Renders the segment's text with the current find/replace match (if
    /// any) drawn in a highlight color so the user can see where Replace
    /// will hit. When there's no match in this segment it just falls back
    /// to plain text so layout/hit-testing doesn't change.
    private var highlightedText: Text {
        guard let range = findHighlightRange else {
            return Text(segment.text)
        }
        let text = segment.text
        var attr = AttributedString(text)
        let lowerOffset = text.distance(from: text.startIndex, to: range.lowerBound)
        let upperOffset = text.distance(from: text.startIndex, to: range.upperBound)
        let lowerIdx = attr.index(attr.startIndex, offsetByCharacters: lowerOffset)
        let upperIdx = attr.index(attr.startIndex, offsetByCharacters: upperOffset)
        attr[lowerIdx..<upperIdx].backgroundColor = .yellow
        attr[lowerIdx..<upperIdx].foregroundColor = .black
        return Text(attr)
    }

    @ViewBuilder
    private var editorBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Edited text", text: $draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($textFieldFocused)
                .lineLimit(1...20)
                .onSubmit { onCommitEditing(draftText) }
                .onExitCommand { onCancelEditing() }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary.opacity(0.5))
                )
            HStack(spacing: 6) {
                Text("Press ⌘↩ to save, Esc to cancel.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onCancelEditing() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onCommitEditing(draftText) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var renamePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename Speaker")
                .font(.subheadline.weight(.semibold))
            TextField("Display name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { save() }
            HStack {
                Button("Reset") { reset() }
                    .disabled(project.speakerNames[segment.speakerID] == nil)
                Spacer()
                Button("Cancel") { isEditingName = false }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
    }

    private func save() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = project.speakerNames[segment.speakerID]
        let newValue = trimmed.isEmpty ? nil : trimmed
        guard newValue != previous else {
            isEditingName = false
            return
        }
        if let newValue {
            project.speakerNames[segment.speakerID] = newValue
        } else {
            project.speakerNames.removeValue(forKey: segment.speakerID)
        }
        let summary = newValue.map { "Renamed speaker to \"\($0)\"" }
            ?? "Cleared speaker name"
        // Tag the edit with this segment's id so re-transcription enrollment
        // can weight the segment the user actually inspected over the others
        // that inherited the rename transitively.
        service.recordEdit(
            .speakerNameChanged(speakerID: segment.speakerID, previousName: previous),
            summary: summary,
            in: project,
            contextSegmentID: segment.id
        )
        try? modelContext.save()
        isEditingName = false
    }

    private func reset() {
        let previous = project.speakerNames[segment.speakerID]
        guard previous != nil else {
            isEditingName = false
            return
        }
        project.speakerNames.removeValue(forKey: segment.speakerID)
        service.recordEdit(
            .speakerNameChanged(speakerID: segment.speakerID, previousName: previous),
            summary: "Reset speaker name",
            in: project,
            contextSegmentID: segment.id
        )
        try? modelContext.save()
        isEditingName = false
    }

    /// Recognizes the censored marker even when the entity replacement left
    /// a grammatical suffix attached — `[CENSORED]'s` (possessive), `[CENSORED]s`
    /// (plural), `[CENSORED].` / `[CENSORED],` etc. The bubble + plain-suffix
    /// renderer reads the same token and decides where to split.
    fileprivate func isCensoredToken(_ token: String) -> Bool {
        let upper = token.uppercased()
        return upper.contains("[CENSORED]")
    }

    /// Splits a censored-marker word into the part the ink bubble obscures
    /// (the literal `[CENSORED]` core) and the trailing characters that
    /// stay visible as plain text. Lowercase variants of the marker are
    /// honored — we case-insensitive-match but slice from the original
    /// token so the bubble's invisible sizing string keeps the user's
    /// chosen casing.
    fileprivate func splitCensoredToken(_ token: String) -> (bubble: String, suffix: String) {
        let upper = token.uppercased()
        guard let upperRange = upper.range(of: "[CENSORED]") else {
            return (token, "")
        }
        // [CENSORED] is ASCII so character offsets line up between the
        // uppercased view and the original — we can rebuild the slice
        // safely from offsets without losing the user's casing.
        let lowerOffset = upper.distance(from: upper.startIndex, to: upperRange.lowerBound)
        let upperOffset = upper.distance(from: upper.startIndex, to: upperRange.upperBound)
        let lo = token.index(token.startIndex, offsetBy: lowerOffset)
        let hi = token.index(token.startIndex, offsetBy: upperOffset)
        let bubble = String(token[lo..<hi])
        let suffix = String(token[hi..<token.endIndex])
        return (bubble, suffix)
    }
}

// MARK: - Invisible ink

/// Inline capsule that obscures a censored word with the iMessage-style
/// "invisible ink" effect — an animated cloud of fine particles drifting
/// across a tinted bubble. Sized by an invisible copy of the placeholder
/// text so the bubble matches what the censored word would have occupied,
/// keeping line wrapping and tap targets close to the original layout.
private struct CensoredInkBubble: View {
    let placeholder: String

    var body: some View {
        Text(placeholder)
            .font(.body)
            .foregroundStyle(.clear)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background {
                ZStack {
                    Capsule()
                        .fill(Color(red: 0.0, green: 0.48, blue: 1.0))
                    InvisibleInkParticles()
                        .clipShape(Capsule())
                        .blendMode(.screen)
                }
            }
            .overlay(
                Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .help("Censored content")
    }
}

/// Animated particle veil. A `Canvas` redrawn every frame by
/// `TimelineView(.animation)`. Particles are deterministically seeded from
/// their index so successive frames stay coherent (no popping in/out), and
/// they drift along their own velocity vectors with edge wrap-around so the
/// veil never thins out.
private struct InvisibleInkParticles: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            Canvas { gc, size in
                let t = context.date.timeIntervalSinceReferenceDate
                // Particle density scaled to the bubble's footprint so a
                // long phrase still feels covered rather than pixelated.
                let pixelArea = max(40, Int(size.width * size.height / 6))
                let count = min(pixelArea, 320)
                for i in 0..<count {
                    let seed = Double(i) + 1.0
                    let baseX = pseudoRandom(seed * 12.345) * size.width
                    let baseY = pseudoRandom(seed * 34.567) * size.height
                    // Slow, varied drift in a random direction. Speeds in
                    // points/second; a 50-point bubble takes a few seconds
                    // to traverse.
                    let speedX = (pseudoRandom(seed * 78.912) - 0.5) * 18
                    let speedY = (pseudoRandom(seed * 43.210) - 0.5) * 12
                    let rawX = baseX + speedX * t
                    let rawY = baseY + speedY * t
                    let x = wrap(rawX, in: size.width)
                    let y = wrap(rawY, in: size.height)
                    let phase = pseudoRandom(seed * 9.876) * .pi * 2
                    // Twinkle: brightness oscillates with each particle's
                    // own phase so the field shimmers rather than pulsing
                    // in lockstep.
                    let twinkle = (sin(t * 3 + phase) + 1) / 2
                    let alpha = 0.35 + twinkle * 0.55
                    let radius = 0.55 + pseudoRandom(seed * 15.5) * 0.85
                    let rect = CGRect(
                        x: x - radius,
                        y: y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    gc.fill(
                        Path(ellipseIn: rect),
                        with: .color(.white.opacity(alpha))
                    )
                }
            }
        }
    }

    private func wrap(_ value: CGFloat, in extent: CGFloat) -> CGFloat {
        guard extent > 0 else { return 0 }
        let r = value.truncatingRemainder(dividingBy: extent)
        return r < 0 ? r + extent : r
    }

    /// Stable [0,1) pseudo-random from a real-valued seed. The classic
    /// `fract(sin(x) * 43758.5453)` trick — fast and good enough for
    /// distributing visual particles, never used as a security primitive.
    private func pseudoRandom(_ seed: Double) -> Double {
        let s = sin(seed) * 43758.5453
        return s - floor(s)
    }
}

private struct WordTile: View {
    let text: String
    let isActive: Bool
    /// True when this word is part of the selection range (single-word or
    /// multi-word). Drives the highlight background.
    let isSelected: Bool
    /// True only on the single-word collapsed selection — paints the leading
    /// "split caret" bar, the same affordance as before.
    let isCaret: Bool
    let isDimmed: Bool
    /// False for the first word of a segment — there's nothing before it to
    /// split off, so we hide the split affordance and let the click act as a
    /// plain seek.
    let canSplit: Bool
    let onTap: () -> Void

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(background)
            )
            .overlay(alignment: .leading) {
                if isCaret {
                    // Caret-style bar on the leading edge marks where Return
                    // will insert a new speaker boundary.
                    Rectangle()
                        .fill(.tint)
                        .frame(width: 2)
                        .offset(x: -4)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .help(canSplit ? "Click to select; Shift-click to extend a range. Return splits, Move buttons relocate the selection." : "")
            .animation(.easeInOut(duration: 0.12), value: isActive)
            .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.tint.opacity(0.28)) }
        if isActive { return AnyShapeStyle(.tint.opacity(0.35)) }
        return AnyShapeStyle(.clear)
    }

    private var foregroundStyle: HierarchicalShapeStyle {
        if isActive { return .primary }
        return isDimmed ? .secondary : .primary
    }
}

/// Inline marker rendered between two words inside `WordFlow` when the
/// mid-segment detector finds a speaker change at that boundary. Visual:
/// a vertical seam + tappable badge "→ Alice ✓✕". Accept performs the
/// split + relabel; dismiss removes just this candidate from the cached
/// results without touching the others.
private struct SplitCandidateMarker: View {
    let candidate: SpeakerVoicePrintService.SplitCandidate
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(.tint)
                .frame(width: 1, height: 16)
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(candidate.suggestedDisplayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Button(action: onAccept) {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.tint.opacity(0.18), in: Capsule())
                .foregroundStyle(.tint)
                .help(String(format: "Split here and label as %@ (confidence %.2f).",
                             candidate.suggestedDisplayName,
                             candidate.confidence))
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.18), in: Capsule())
                .foregroundStyle(.secondary)
                .help("Dismiss this suggestion. The voice-print model keeps learning from your other choices.")
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.tint.opacity(0.4), lineWidth: 0.5)
            )
        }
    }
}

/// Renders a non-speech ([MUSIC]) segment row. Replaces the entire
/// `SegmentRow` body when `segment.isNonSpeech` is true — the user
/// shouldn't be able to assign a speaker, edit text, or interact with
/// "words" inside a music interlude. The row is non-interactive other
/// than tap-to-seek and right-click → delete.
///
/// The visual is a row of music-note glyphs that drift upward and fade,
/// driven by `TimelineView` so the animation runs without per-frame view
/// rebuilds. Three notes spaced across the duration of the gap give the
/// row enough motion to read as "something is happening" without being
/// distracting on long transcripts.
private struct MusicBlockRow: View {
    let segment: SpeakerSegment
    let onDelete: () -> Void
    let onSeek: () -> Void

    private var durationLabel: String {
        let seconds = max(0, segment.endSeconds - segment.startSeconds)
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return m > 0 ? String(format: "%d:%02d", m, s) : String(format: "0:%02d", s)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Same 90 px lead column as speech rows so block alignment
            // reads like part of the same chronological list.
            VStack(alignment: .trailing, spacing: 2) {
                Text("Music")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text(TranscriptExporter.timestamp(segment.startSeconds))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 90, alignment: .trailing)

            HStack(spacing: 8) {
                MusicNotesAnimation()
                Text("[MUSIC]")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospaced()
                Text(durationLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.tint.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.tint.opacity(0.18), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onSeek() }
            .help("Non-speech interlude. Tap to seek to its start. Right-click to delete if it was detected by mistake.")
            .contextMenu {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Music Block", systemImage: "trash")
                }
            }
        }
    }
}

/// Three music-note glyphs that drift upward and fade in a loop, driven
/// by `TimelineView` so the animation doesn't force the parent view to
/// re-render on every frame. Visual flair only — keeps the row feeling
/// like an active musical break instead of dead space.
private struct MusicNotesAnimation: View {
    private let glyphs: [String] = ["music.note", "music.quarternote.3", "music.note"]
    private let cycleSeconds: Double = 2.4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<glyphs.count, id: \.self) { index in
                    let phase = (t / cycleSeconds + Double(index) / Double(glyphs.count))
                        .truncatingRemainder(dividingBy: 1)
                    Image(systemName: glyphs[index])
                        .font(.callout)
                        .foregroundStyle(.tint)
                        .opacity(noteOpacity(phase: phase))
                        .offset(y: noteOffset(phase: phase))
                }
            }
            .frame(width: 64, height: 22)
        }
    }

    /// Triangular fade-in/out: opaque mid-cycle, transparent at ends.
    /// Avoids notes "popping" in/out at the wrap-around.
    private func noteOpacity(phase: Double) -> Double {
        let centered = abs(phase - 0.5) * 2  // 0 at center, 1 at ends
        return max(0, 1.0 - centered) * 0.85
    }

    /// Drifts upward across the cycle (phase 0 → low, phase 1 → high).
    /// Combined with the opacity envelope, notes appear, rise, and fade.
    private func noteOffset(phase: Double) -> CGFloat {
        CGFloat(-(phase - 0.5) * 14)
    }
}

/// Inline tile for the in-progress insertion buffer. Renders as a tinted
/// chip with a trailing caret stripe so the user can see what's being
/// typed and where the cursor sits relative to the surrounding words.
private struct InlineInsertionTile: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            // Empty buffer (just opened) shows a placeholder caret only —
            // an empty Text would collapse to zero width and disappear.
            Text(text.isEmpty ? " " : text)
                .font(.body)
                .foregroundStyle(.tint)
            Rectangle()
                .fill(.tint)
                .frame(width: 1)
                .padding(.vertical, 2)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.tint.opacity(0.5), lineWidth: 0.5)
        )
        .help("Type to insert text before the selected word. Return commits, Esc cancels.")
    }
}

// MARK: - Revision history

/// Newest-first list of edits the user has made to this project. The top edit
/// can be popped via the Undo button or ⌘Z; older edits stay visible so the
/// user can audit what they changed and roll back the most recent step at any
/// time. Stepping further back means undoing the chain entry-by-entry.
private struct RevisionHistoryPopover: View {
    let project: TranscriptionProject

    @Environment(TranscriptionService.self) private var service

    private var sortedEdits: [ProjectEdit] {
        project.edits.sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Revision History")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !sortedEdits.isEmpty {
                    Button("Clear") {
                        service.clearEditHistory(in: project)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Forget the edit history (current state is kept)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if sortedEdits.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No edits yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Renames, label changes, and speaker splits will appear here.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 18)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(sortedEdits.enumerated()), id: \.element.id) { index, edit in
                            RevisionRow(
                                edit: edit,
                                isMostRecent: index == 0,
                                onUndo: {
                                    service.undoLastEdit(in: project)
                                }
                            )
                            if index < sortedEdits.count - 1 {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 320)
        .padding(.bottom, 6)
    }
}

private struct RevisionRow: View {
    let edit: ProjectEdit
    let isMostRecent: Bool
    let onUndo: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.tint)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(edit.summary)
                    .font(.callout)
                    .lineLimit(2)
                Text(edit.timestamp.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if isMostRecent {
                Button(action: onUndo) {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly)
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .help("Undo this edit")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isMostRecent ? AnyShapeStyle(.tint.opacity(0.06)) : AnyShapeStyle(.clear))
    }

    private var icon: String {
        switch edit.kind {
        case "title": "textformat"
        case "speakerName": "person.fill"
        case "labelAdded": "tag.fill"
        case "labelRemoved": "tag.slash"
        case "split": "scissors"
        case "merge": "arrow.merge"
        case "textChanged": "pencil.and.outline"
        case "speakerReassigned": "person.crop.circle.badge.checkmark"
        case "segmentDeleted": "trash"
        case "wordsMoved": "arrow.left.arrow.right"
        default: "pencil"
        }
    }
}

/// Text-flow layout that wraps word tiles like paragraph text. Keeps each word
/// as a real, id'd view so `ScrollViewReader` can target them individually —
/// which is how the editor follows playback through long monologues.
private struct WordFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        var hasRow = false
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            let next = hasRow ? rowWidth + spacing + size.width : size.width
            if hasRow, next > maxWidth {
                totalHeight += rowHeight + lineSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = next
                rowHeight = max(rowHeight, size.height)
                hasRow = true
            }
        }
        if hasRow { totalHeight += rowHeight }
        let width = proposal.width ?? rowWidth
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        var hasRow = false
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            let next = hasRow ? (x - bounds.minX) + spacing + size.width : size.width
            if hasRow, next > maxWidth {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
                hasRow = false
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += (hasRow ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
            hasRow = true
        }
    }
}

// MARK: - Export

struct TranscriptTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let decoded = String(data: data, encoding: .utf8) {
            self.text = decoded
        } else {
            self.text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

enum TranscriptExporter {
    static func timestamp(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "--:--" }
        let total = Int(t.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    static func plainText(projectTitle: String,
                          createdAt: Date,
                          segments: [SpeakerSegment],
                          displayName: (String) -> String) -> String {
        let dateString = createdAt.formatted(date: .long, time: .shortened)
        var lines: [String] = []
        lines.append(projectTitle)
        lines.append(dateString)
        lines.append(String(repeating: "─", count: 40))
        lines.append("")
        for segment in segments {
            lines.append("[\(timestamp(segment.startSeconds))] \(displayName(segment.speakerID))")
            lines.append(segment.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Job progress overlay

private struct JobProgressView: View {
    let job: TranscriptionService.JobState
    let audioDuration: TimeInterval
    let audioURL: URL?

    @State private var peaks: [Float] = []
    @State private var startedAt: Date = .now
    @State private var factoidIndex: Int = 0

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            AnimatedWaveform(peaks: peaks, isFailed: isFailed)
                .frame(height: 120)
                .padding(.horizontal, 48)

            VStack(spacing: 6) {
                Text(phaseLabel)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(factoid)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .transition(.opacity)
                    .id(factoidIndex)
                    .animation(.easeInOut(duration: 0.35), value: factoidIndex)
            }

            if job.phase == .downloadingTranscriberModel, let fraction = job.modelDownloadFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 280)
            }

            statsRow

            if case .failed = job.phase, let message = job.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .task(id: audioURL) { await loadPeaks() }
        .task(id: job.phase) { await rotateFactoids() }
    }

    private var isFailed: Bool {
        if case .failed = job.phase { return true }
        return false
    }

    private var statsRow: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { ctx in
            let elapsed = max(0, ctx.date.timeIntervalSince(startedAt))
            HStack(spacing: 10) {
                StatPill(icon: "clock", label: "Elapsed", value: formatDuration(elapsed))
                if audioDuration > 0 {
                    StatPill(icon: "waveform", label: "Audio", value: formatDuration(audioDuration))
                }
                StatPill(icon: "gauge.with.dots.needle.67percent",
                         label: "Phase",
                         value: shortPhaseLabel)
            }
        }
    }

    private var phaseLabel: String {
        switch job.phase {
        case .queued: "Queued"
        case .preparingDiarizer: "Preparing speaker models…"
        case .preparingTranscriber: "Preparing speech model…"
        case .downloadingTranscriberModel: "Downloading speech model…"
        case .analyzing: "Transcribing and separating speakers…"
        case .saving: "Saving transcript…"
        case .finished: "Finished"
        case .failed: "Transcription failed"
        }
    }

    private var shortPhaseLabel: String {
        switch job.phase {
        case .queued: "Queued"
        case .preparingDiarizer: "Speakers"
        case .preparingTranscriber: "Speech"
        case .downloadingTranscriberModel: "Download"
        case .analyzing: "Analyzing"
        case .saving: "Saving"
        case .finished: "Done"
        case .failed: "Failed"
        }
    }

    private var factoids: [String] {
        switch job.phase {
        case .queued:
            ["Warming up the engines…", "Getting your audio ready…"]
        case .preparingDiarizer:
            ["Teaching the app to tell voices apart.",
             "Loading the speaker diarization model.",
             "Calibrating ears for multiple speakers."]
        case .preparingTranscriber:
            ["Loading on-device speech recognition.",
             "No audio leaves your Mac — this is all local.",
             "Spinning up Apple's speech model."]
        case .downloadingTranscriberModel:
            ["Fetching the speech model — one-time download.",
             "After this, transcription runs entirely offline.",
             "Almost there — models get cached for next time."]
        case .analyzing:
            ["Listening to every word…",
             "Separating overlapping voices.",
             "Enhancing soft speech for better accuracy.",
             "Matching each sentence to its speaker.",
             "Running two models in parallel on your audio."]
        case .saving:
            ["Stitching everything together.",
             "Writing the transcript to your library."]
        case .finished:
            ["All set!"]
        case .failed:
            ["Something went wrong. See details below."]
        }
    }

    private var factoid: String {
        let list = factoids
        guard !list.isEmpty else { return "" }
        return list[factoidIndex % list.count]
    }

    private func rotateFactoids() async {
        factoidIndex = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3.5))
            if Task.isCancelled { break }
            factoidIndex += 1
        }
    }

    private func loadPeaks() async {
        guard let url = audioURL else { return }
        let result = await Task.detached(priority: .utility) {
            WaveformExtractor.extractPeaks(from: url, targetCount: 96)
        }.value
        peaks = result
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "--:--" }
        let total = Int(t.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

private struct StatPill: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.secondary.opacity(0.15)))
    }
}

/// Animated waveform that reflects the original audio. Peaks come from
/// `WaveformExtractor` (so silence stays quiet and speech stays tall), and a
/// gentle per-bar sine modulation + sweeping highlight makes it feel alive
/// while the pipeline runs.
private struct AnimatedWaveform: View {
    let peaks: [Float]
    let isFailed: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            Canvas { gc, size in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let bars = peaks.isEmpty ? Array(repeating: Float(0.25), count: 60) : peaks
                let count = bars.count
                let spacing: CGFloat = 2
                let barWidth = max(1.5, (size.width - CGFloat(count - 1) * spacing) / CGFloat(count))
                let midY = size.height / 2
                let sweep = (sin(t * 1.2) + 1) / 2  // 0…1
                let sweepX = CGFloat(sweep) * size.width

                for (i, peak) in bars.enumerated() {
                    let phase = Double(i) * 0.22 + t * 4.0
                    let modulation = 0.55 + 0.45 * (sin(phase) * 0.5 + 0.5)
                    let base = CGFloat(peak)
                    let h = max(3, base * (size.height - 6) * CGFloat(modulation))
                    let x = CGFloat(i) * (barWidth + spacing)
                    let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)

                    let distance = abs((x + barWidth / 2) - sweepX)
                    let glow = max(0, 1 - distance / 80)
                    let shading: GraphicsContext.Shading
                    if isFailed {
                        shading = .color(.red.opacity(0.55 + 0.25 * glow))
                    } else {
                        shading = .color(.accentColor.opacity(0.45 + 0.45 * glow))
                    }
                    gc.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: shading)
                }
            }
        }
    }
}

// MARK: - Playback bar

private struct PlaybackBar: View {
    let project: TranscriptionProject
    let audioURL: URL?
    let duration: TimeInterval
    let currentTime: TimeInterval
    let isPlaying: Bool
    @Binding var followAlongEnabled: Bool
    let onTogglePlay: () -> Void
    let onSkip: (TimeInterval) -> Void
    let onScrub: (TimeInterval) -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: { onSkip(-10) }) {
                Image(systemName: "gobackward.10")
                    .font(.title3)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(audioURL == nil)

            Button(action: onTogglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
                    .frame(width: 44, height: 44)
                    .background(.tint.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(audioURL == nil)

            Button(action: { onSkip(10) }) {
                Image(systemName: "goforward.10")
                    .font(.title3)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(audioURL == nil)

            Button {
                followAlongEnabled.toggle()
            } label: {
                Image(systemName: followAlongEnabled ? "eye" : "eye.slash")
                    .font(.title3)
                    .foregroundStyle(followAlongEnabled
                                     ? AnyShapeStyle(.tint)
                                     : AnyShapeStyle(.secondary))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help(followAlongEnabled
                  ? "Follow Along is on — playback highlights and scrolls to the active word. Click to turn off."
                  : "Follow Along is off — playback runs without highlighting or scrolling. Click to turn on.")

            Text(Self.format(currentTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            Group {
                if audioURL != nil {
                    WaveformView(
                        project: project,
                        duration: duration,
                        currentTime: currentTime,
                        onScrub: onScrub
                    )
                } else {
                    Rectangle().fill(.secondary.opacity(0.1))
                }
            }
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(Self.format(duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
        }
    }

    private static func format(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "--:--" }
        let total = Int(t.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Editor view modifiers

/// Bundles the editor's alert + file-exporter chain into a single modifier
/// so SwiftUI's type-checker doesn't have to flatten the entire stack each
/// time the body is built. Cuts compile time on the editor view from "too
/// complex" to a few hundred ms.
private struct EditorAlertsModifier: ViewModifier {
    @Binding var isExporterPresented: Bool
    let exportDocument: TranscriptTextDocument?
    let projectTitle: String
    @Binding var archiveError: String?
    @Binding var recomputeError: String?
    @Binding var transcriptImportError: String?
    @Binding var transcriptImportSummary: TranscriptionService.TranscriptImportSummary?
    let onExportFinished: () -> Void

    func body(content: Content) -> some View {
        content
            .fileExporter(
                isPresented: $isExporterPresented,
                document: exportDocument,
                contentType: .plainText,
                defaultFilename: projectTitle
            ) { _ in
                onExportFinished()
            }
            .alert(
                "Couldn't export project archive",
                isPresented: Binding(
                    get: { archiveError != nil },
                    set: { if !$0 { archiveError = nil } }
                ),
                presenting: archiveError
            ) { _ in
                Button("OK", role: .cancel) { archiveError = nil }
            } message: { message in
                Text(message)
            }
            .alert(
                "Couldn't recompute timings",
                isPresented: Binding(
                    get: { recomputeError != nil },
                    set: { if !$0 { recomputeError = nil } }
                ),
                presenting: recomputeError
            ) { _ in
                Button("OK", role: .cancel) { recomputeError = nil }
            } message: { message in
                Text(message)
            }
            .alert(
                "Couldn't import transcript",
                isPresented: Binding(
                    get: { transcriptImportError != nil },
                    set: { if !$0 { transcriptImportError = nil } }
                ),
                presenting: transcriptImportError
            ) { _ in
                Button("OK", role: .cancel) { transcriptImportError = nil }
            } message: { message in
                Text(message)
            }
            .alert(
                "Transcript Re-Import Complete",
                isPresented: Binding(
                    get: { transcriptImportSummary != nil },
                    set: { if !$0 { transcriptImportSummary = nil } }
                ),
                presenting: transcriptImportSummary
            ) { _ in
                Button("OK", role: .cancel) { transcriptImportSummary = nil }
            } message: { summary in
                Text(importSummaryMessage(summary))
            }
    }

    private func importSummaryMessage(_ summary: TranscriptionService.TranscriptImportSummary) -> String {
        var lines: [String] = []
        let updated = summary.updatedSegmentCount
        let unchanged = summary.unchangedSegmentCount
        if updated == 0 && unchanged == 0 {
            lines.append("No matching segments were found in the file.")
        } else {
            lines.append("\(updated) segment\(updated == 1 ? "" : "s") updated, \(unchanged) unchanged.")
            lines.append("Each text change was recorded in the revision history and can be undone individually.")
        }
        if summary.skippedSegmentCount > 0 {
            lines.append("\(summary.skippedSegmentCount) project segment\(summary.skippedSegmentCount == 1 ? "" : "s") had no counterpart in the file and were left untouched.")
        }
        if summary.extraSegmentCount > 0 {
            lines.append("The file contained \(summary.extraSegmentCount) extra segment\(summary.extraSegmentCount == 1 ? "" : "s") that don't map to existing project segments; those weren't applied.")
        }
        return lines.joined(separator: "\n\n")
    }
}

/// Encapsulates the editor's `onChange` + `task` reactions. Like
/// `EditorAlertsModifier`, this exists purely to keep the body short enough
/// for the type-checker.
private struct EditorOnChangeModifier: ViewModifier {
    let projectID: UUID
    let segmentTexts: [String]
    let segmentCount: Int
    let findQuery: String
    let findCaseSensitive: Bool
    let onProjectIDChanged: () -> Void
    let onSegmentsChanged: () -> Void
    let onFindCriteriaChanged: () -> Void
    let onSegmentCountChanged: () -> Void
    let onTaskRefresh: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: projectID) { _, _ in onProjectIDChanged() }
            .onChange(of: segmentTexts) { _, _ in onSegmentsChanged() }
            .onChange(of: findQuery) { _, _ in onFindCriteriaChanged() }
            .onChange(of: findCaseSensitive) { _, _ in onFindCriteriaChanged() }
            .onChange(of: segmentCount) { _, _ in onSegmentCountChanged() }
            .task(id: segmentCount) { onTaskRefresh() }
    }
}

/// Bulletproof catch for the Delete / Forward-Delete keys on macOS.
///
/// SwiftUI's `.onKeyPress` (both the catch-all and the explicit `keys:`
/// form) loses races against AppKit's responder chain for keys that have
/// built-in action selectors — Backspace maps to `deleteBackward:` and is
/// intercepted before any SwiftUI hook fires on a non-text-input
/// `.focusable()` view. The user-visible symptom is a system beep on every
/// Delete press. Solution: install an application-local NSEvent keyDown
/// monitor, which runs *before* the responder chain.
///
/// The Coordinator class lives across SwiftUI view rebuilds and owns the
/// monitor handle (so we never leak monitors). `updateNSView` re-binds the
/// callback on every render so the closure captures fresh `@State` values
/// — without this the callback would freeze the state at install time.
private struct DeleteKeyMonitor: NSViewRepresentable {
    /// Returns `true` when the press was handled (event will be swallowed)
    /// or `false` to let the system continue normal handling.
    let onDelete: () -> Bool

    final class Coordinator {
        var monitor: Any?
        var onDelete: (() -> Bool)?
        weak var owningView: NSView?

        init() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // 51 = Delete (Backspace on Mac), 117 = Forward Delete.
                guard event.keyCode == 51 || event.keyCode == 117 else { return event }
                // Hands off when a real text input owns the focus —
                // segment-edit TextField, find bar, rename popover, etc.
                if let window = NSApp.keyWindow,
                   window.firstResponder is NSTextView {
                    return event
                }
                // Multi-window safety: only intercept events for the window
                // this representable lives in.
                if let owningWindow = self.owningView?.window,
                   let eventWindow = event.window,
                   owningWindow !== eventWindow {
                    return event
                }
                return self.onDelete?() == true ? nil : event
            }
        }

        deinit {
            if let m = monitor {
                NSEvent.removeMonitor(m)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.owningView = view
        context.coordinator.onDelete = onDelete
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDelete = onDelete
    }
}

/// Wraps the transcript ScrollView's keyboard hooks. Kept as its own
/// `ViewModifier` so the `TranscriptListView` body stays small enough for
/// SwiftUI's type-checker — stacking five `.onKeyPress` modifiers inline
/// alongside the existing `.onChange` chain pushes the body over the edge.
///
/// Two handlers are wired:
///  * **Control keys** (Delete, Forward-Delete, Escape, Return): bound via
///    the explicit `keys:` form so they actually fire on macOS. The
///    catch-all `.onKeyPress(action:)` loses races against AppKit's
///    responder chain for keys with built-in action selectors (e.g.
///    `deleteBackward:`).
///  * **Printable input**: catch-all that's expected to suppress the
///    control keys itself (they already had their chance above).
private struct TranscriptKeyHandlers: ViewModifier {
    let onControlKey: (KeyPress) -> KeyPress.Result
    let onPrintable: (KeyPress) -> KeyPress.Result

    func body(content: Content) -> some View {
        content
            .onKeyPress(
                keys: [.delete, .deleteForward, .escape, .return],
                phases: [.down, .repeat]
            ) { onControlKey($0) }
            .onKeyPress(phases: [.down, .repeat]) { onPrintable($0) }
    }
}

// MARK: - Find / replace types

/// One hit from the find bar's substring search. Identifies the segment and
/// the exact character range so the editor can highlight + replace at that
/// location without re-running the regex.
struct FindMatch: Equatable, Identifiable {
    let id = UUID()
    let segmentID: UUID
    let range: Range<String.Index>

    static func == (lhs: FindMatch, rhs: FindMatch) -> Bool {
        lhs.segmentID == rhs.segmentID && lhs.range == rhs.range
    }
}

/// User's per-entity choice from the privacy-scan sheet.
struct EntityAction: Equatable {
    enum Kind: Equatable {
        case skip
        case censor
        case replace
    }
    var kind: Kind = .skip
    var replacement: String = ""
}

// MARK: - Find / replace bar

private struct FindReplaceBar: View {
    @Binding var query: String
    @Binding var replacement: String
    @Binding var caseSensitive: Bool
    let matchCount: Int
    let currentIndex: Int
    let onClose: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onReplaceCurrent: () -> Void
    let onReplaceAll: () -> Void

    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($queryFocused)
                    .onSubmit { onNext() }
                Text(matchCount == 0 ? "0 matches" : "\(currentIndex + 1) / \(matchCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .trailing)
                Toggle("Aa", isOn: $caseSensitive)
                    .toggleStyle(.button)
                    .help("Match case")
                Button {
                    onPrevious()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(matchCount == 0)
                Button {
                    onNext()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("g", modifiers: .command)
                .disabled(matchCount == 0)
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("Replace with", text: $replacement)
                    .textFieldStyle(.roundedBorder)
                Button("Replace") { onReplaceCurrent() }
                    .disabled(matchCount == 0)
                Button("Replace All") { onReplaceAll() }
                    .disabled(matchCount == 0)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .onAppear { queryFocused = true }
    }
}

// MARK: - Recompute timings badges

private struct RecomputeTimingsBadge: View {
    let onRecompute: () -> Void

    var body: some View {
        Button(action: onRecompute) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.badge.plus")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Edits Pending Alignment")
                        .font(.caption.weight(.semibold))
                    Text("Recompute Timings")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.tint.opacity(0.4), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .help("Re-extract each edited segment's audio and align word timings against the recognizer.")
    }
}

private struct RecomputeProgressBadge: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 0) {
                Text("Recomputing Timings…")
                    .font(.caption.weight(.semibold))
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

// MARK: - Privacy scan sheet

private struct EntityScanSheet: View {
    let groups: [EntityScanner.Group]
    let onCancel: () -> Void
    let onApply: ([UUID: EntityAction]) -> Void

    @State private var actions: [UUID: EntityAction] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Privacy Scan")
                    .font(.title3.weight(.semibold))
                Text("Transcripty looked for personal names, places, and organizations in the transcript. Choose what to do with each one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if groups.isEmpty {
                ContentUnavailableView(
                    "Nothing Detected",
                    systemImage: "checkmark.shield",
                    description: Text("No personal names, places, or organizations were found in this transcript.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(groups) { group in
                            EntityRow(
                                group: group,
                                action: Binding(
                                    get: { actions[group.id] ?? EntityAction() },
                                    set: { actions[group.id] = $0 }
                                )
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 360)
            }

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    onApply(actions)
                } label: {
                    Label("Apply", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(groups.isEmpty || appliedActionCount == 0)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private var appliedActionCount: Int {
        actions.values.filter { action in
            switch action.kind {
            case .skip: return false
            case .censor: return true
            case .replace:
                return !action.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }.count
    }
}

private struct EntityRow: View {
    let group: EntityScanner.Group
    @Binding var action: EntityAction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: group.kind.systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.text)
                        .font(.body.weight(.semibold))
                    Text("\(group.kind.displayName) · \(group.occurrences.count) occurrence\(group.occurrences.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Action", selection: $action.kind) {
                    Text("Skip").tag(EntityAction.Kind.skip)
                    Text("Censor").tag(EntityAction.Kind.censor)
                    Text("Replace…").tag(EntityAction.Kind.replace)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            if action.kind == .replace {
                TextField("Replacement text", text: $action.replacement)
                    .textFieldStyle(.roundedBorder)
                    .padding(.leading, 30)
            }
            if action.kind == .censor {
                Text("Will be replaced with [CENSORED] in all \(group.occurrences.count) occurrences.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 30)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.3))
        )
    }
}
