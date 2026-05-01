import SwiftUI
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
    @State private var isConfirmingRetranscribe = false

    private var job: TranscriptionService.JobState? {
        service.jobs[project.id]
    }

    private var orderedSegments: [SpeakerSegment] {
        project.segments.sorted { $0.startSeconds < $1.startSeconds }
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
            } else {
                TranscriptListView(
                    project: project,
                    segments: orderedSegments,
                    currentTime: currentTime,
                    onSeek: { time in seek(to: time) },
                    onSplit: { segment, wordIndex in
                        service.splitSegment(segment, atWordIndex: wordIndex, in: project)
                    },
                    onMerge: { a, b in
                        service.mergeSegments(a, b, in: project)
                    }
                )
                .frame(maxHeight: .infinity)
            }
            PlaybackBar(
                project: project,
                audioURL: audioURL,
                duration: duration,
                currentTime: currentTime,
                isPlaying: isPlaying,
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
            if canRetranscribeWithHints {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isConfirmingRetranscribe = true
                    } label: {
                        Label("Re-Transcribe with Labels", systemImage: "wand.and.stars")
                    }
                    .help("Re-run transcription using your speaker names as supervision")
                }
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
                    Label("Export Transcript", systemImage: "square.and.arrow.up")
                }
                .disabled(orderedSegments.isEmpty)
                .help("Export transcript as a plain text file")
            }
        }
        .fileExporter(
            isPresented: $isExporterPresented,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: project.title
        ) { _ in
            exportDocument = nil
        }
        .confirmationDialog(
            "Re-transcribe with your labels?",
            isPresented: $isConfirmingRetranscribe,
            titleVisibility: .visible
        ) {
            Button("Re-Transcribe") {
                player?.pause()
                isPlaying = false
                service.retranscribe(project: project)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This replaces the current transcript. The new run uses \(namedSpeakerCount) speaker\(namedSpeakerCount == 1 ? "" : "s") and re-applies your speaker names where they overlap the new turns.")
        }
    }

    /// Show the Re-Transcribe action only when the user has done meaningful
    /// labeling work — at least one speaker has a custom name. With nothing
    /// to transfer the action would just re-run the pipeline blindly, which
    /// is what the import flow already handles.
    private var canRetranscribeWithHints: Bool {
        guard project.status == .ready else { return false }
        return namedSpeakerCount > 0
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

// MARK: - Transcript list

private struct TranscriptListView: View {
    let project: TranscriptionProject
    let segments: [SpeakerSegment]
    let currentTime: TimeInterval
    let onSeek: (TimeInterval) -> Void
    let onSplit: (SpeakerSegment, Int) -> Void
    let onMerge: (SpeakerSegment, SpeakerSegment) -> Void

    /// Minimum gap between intra-segment word scrolls. Every word change would
    /// otherwise stack scrollTo animations (3–5/sec during fast speech), which
    /// reads as jittery. 1.5 s lets long monologues still creep forward while
    /// keeping the scroll visually calm.
    private static let wordScrollInterval: TimeInterval = 1.5

    @State private var lastScrolledSegmentID: UUID?
    @State private var lastWordScrollAt: Date = .distantPast
    /// Word the user clicked most recently — the split point used when they
    /// press Return. `nil` when nothing is selected or the selection was
    /// invalidated by a split/delete.
    @State private var selectedSplit: SplitSelection?
    @FocusState private var transcriptFocused: Bool

    private var activeSegment: SpeakerSegment? {
        segments.first(where: { $0.contains(time: currentTime) })
    }

    private var activeWordAnchor: String? {
        guard let active = activeSegment,
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
                            SegmentRow(
                                project: project,
                                segment: segment,
                                previousSegment: index > 0 ? segments[index - 1] : nil,
                                nextSegment: index < segments.count - 1 ? segments[index + 1] : nil,
                                currentTime: currentTime,
                                isActive: segment.contains(time: currentTime),
                                selectedWordIndex: selectedSplit?.segmentID == segment.id
                                    ? selectedSplit?.wordIndex : nil,
                                onSeek: onSeek,
                                onSelectSplit: { wordIndex in
                                    selectedSplit = SplitSelection(segmentID: segment.id, wordIndex: wordIndex)
                                    transcriptFocused = true
                                },
                                onMerge: onMerge
                            )
                            .id(segment.id.uuidString)
                        }
                    }
                }
                .padding()
            }
            .focusable()
            .focused($transcriptFocused)
            .onKeyPress(.return) {
                performSplit() ? .handled : .ignored
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
        guard let sel = selectedSplit,
              let segment = segments.first(where: { $0.id == sel.segmentID }),
              sel.wordIndex > 0,
              sel.wordIndex < segment.words.count else { return false }
        onSplit(segment, sel.wordIndex)
        selectedSplit = nil
        return true
    }

    private struct SplitSelection: Equatable {
        let segmentID: UUID
        let wordIndex: Int
    }
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
    let selectedWordIndex: Int?
    let onSeek: (TimeInterval) -> Void
    let onSelectSplit: (Int) -> Void
    let onMerge: (SpeakerSegment, SpeakerSegment) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(TranscriptionService.self) private var service
    @State private var isEditingName = false
    @State private var draftName = ""

    private var displayName: String {
        project.displayName(forSpeakerID: segment.speakerID)
    }

    private var activeWordIndex: Int? {
        isActive ? segment.activeWordIndex(at: currentTime) : nil
    }

    var body: some View {
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
                Text(TranscriptExporter.timestamp(segment.startSeconds))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 90, alignment: .trailing)

            transcriptBody
                .padding(10)
                .background(isActive ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 8))
                .contextMenu { mergeMenuContent }
        }
        .animation(.easeInOut(duration: 0.15), value: isActive)
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
        if segment.words.isEmpty {
            Text(segment.text)
                .font(.body)
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onSeek(segment.startSeconds) }
        } else {
            WordFlow(spacing: 4, lineSpacing: 6) {
                ForEach(Array(segment.words.enumerated()), id: \.offset) { index, word in
                    WordTile(
                        text: word.text,
                        isActive: index == activeWordIndex,
                        isSelected: index == selectedWordIndex,
                        isDimmed: !isActive,
                        canSplit: index > 0
                    ) {
                        onSeek(word.start)
                        if index > 0 { onSelectSplit(index) }
                    }
                    .id("\(segment.id.uuidString)-word-\(index)")
                }
            }
        }
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
}

private struct WordTile: View {
    let text: String
    let isActive: Bool
    let isSelected: Bool
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
                if isSelected {
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
            .help(canSplit ? "Click to select — press Return to start a new speaker here" : "")
            .animation(.easeInOut(duration: 0.12), value: isActive)
            .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.tint.opacity(0.22)) }
        if isActive { return AnyShapeStyle(.tint.opacity(0.35)) }
        return AnyShapeStyle(.clear)
    }

    private var foregroundStyle: HierarchicalShapeStyle {
        if isActive { return .primary }
        return isDimmed ? .secondary : .primary
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
