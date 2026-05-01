import SwiftUI
import SwiftData

enum SidebarDestination: Hashable {
    case projectsGrid
    case project(UUID)
    case label(UUID)
    case privacy
}

struct RootView: View {
    @Query(sort: \TranscriptionProject.createdAt, order: .reverse)
    private var projects: [TranscriptionProject]

    @Query(sort: \ProjectLabel.name)
    private var labels: [ProjectLabel]

    @Environment(TranscriptionService.self) private var service
    @Environment(\.modelContext) private var modelContext

    @State private var selection: SidebarDestination?
    @State private var isImporting = false
    @State private var pendingDeletion: TranscriptionProject?
    @State private var renamingProject: TranscriptionProject?
    @State private var renameDraft = ""
    @State private var editingLabel: ProjectLabel?
    @State private var creatingLabel = false
    @State private var labelPickerTarget: TranscriptionProject?
    @State private var pendingLabelDeletion: ProjectLabel?
    @State private var searchText = ""

    // MARK: - Derived lists

    private var chronologicalProjects: [TranscriptionProject] {
        projects.sorted { $0.createdAt < $1.createdAt }
    }

    private var activeLabel: ProjectLabel? {
        if case .label(let id) = selection {
            return labels.first(where: { $0.id == id })
        }
        return nil
    }

    /// Projects matching the current search + (if present) the active label
    /// filter, sorted by relevance when searching and by creation date
    /// otherwise.
    private var searchResults: [ProjectSearchResult] {
        let base: [TranscriptionProject]
        if let activeLabel {
            base = projects.filter { project in
                project.labels.contains { $0.id == activeLabel.id }
            }
        } else {
            base = projects
        }

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return base.map { ProjectSearchResult(project: $0, score: 0, snippet: nil) }
        }

        let isLabelOnly = trimmed.hasPrefix("#")
        let query = (isLabelOnly ? String(trimmed.dropFirst()) : trimmed)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !query.isEmpty else {
            return base.map { ProjectSearchResult(project: $0, score: 0, snippet: nil) }
        }

        return base.compactMap { project -> ProjectSearchResult? in
            var score = 0
            var snippet: String?

            let labelHit = project.labels.contains { $0.name.lowercased().contains(query) }
            if labelHit { score += 75 }

            if !isLabelOnly {
                let titleLower = project.title.lowercased()
                if titleLower.contains(query) {
                    score += 100
                    if titleLower.hasPrefix(query) { score += 50 }
                }

                for segment in project.segments {
                    let lower = segment.text.lowercased()
                    var cursor = lower.startIndex
                    var hits = 0
                    while let range = lower.range(of: query, range: cursor..<lower.endIndex) {
                        hits += 1
                        if snippet == nil {
                            snippet = Self.excerpt(from: segment.text, around: range.lowerBound, in: lower)
                        }
                        cursor = range.upperBound
                    }
                    score += hits
                }
            }

            guard score > 0 else { return nil }
            return ProjectSearchResult(project: project, score: score, snippet: snippet)
        }
        .sorted { $0.score > $1.score }
    }

    private static func excerpt(from text: String, around hitStart: String.Index, in lower: String) -> String {
        let lead = 24
        let tail = 40
        let startOffset = max(0, lower.distance(from: lower.startIndex, to: hitStart) - lead)
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let maxEnd = text.distance(from: start, to: text.endIndex)
        let end = text.index(start, offsetBy: min(lead + tail, maxEnd))
        var result = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if startOffset > 0 { result = "…" + result }
        if end < text.endIndex { result += "…" }
        return result
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            GlobalStatusBar()
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            } detail: {
                detail
                    .overlay(alignment: .topTrailing) {
                        if case .privacy = selection {
                            EmptyView()
                        } else {
                            FloatingSearchField(text: $searchText)
                                .padding(.top, 12)
                                .padding(.trailing, 20)
                        }
                    }
            }
        }
        .sheet(isPresented: $isImporting) {
            NavigationStack {
                ImportView { id in
                    isImporting = false
                    selection = .project(id)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isImporting = false }
                    }
                }
            }
            .frame(minWidth: 520, minHeight: 420)
        }
        .sheet(item: $editingLabel) { label in
            LabelEditorSheet(existing: label) { _ in }
        }
        .sheet(isPresented: $creatingLabel) {
            LabelEditorSheet(existing: nil) { _ in }
        }
        .confirmationDialog(
            pendingDeletion.map { "Delete \"\($0.title)\"?" } ?? "Delete project?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { project in
            Button("Delete Project", role: .destructive) {
                if selection == .project(project.id) { selection = nil }
                service.delete(project: project)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("The transcript and its audio copy will be removed. The original file on disk is not affected.")
        }
        .confirmationDialog(
            pendingLabelDeletion.map { "Delete label \"\($0.name)\"?" } ?? "Delete label?",
            isPresented: Binding(
                get: { pendingLabelDeletion != nil },
                set: { if !$0 { pendingLabelDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingLabelDeletion
        ) { label in
            Button("Delete Label", role: .destructive) {
                if selection == .label(label.id) { selection = nil }
                modelContext.delete(label)
                try? modelContext.save()
                pendingLabelDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingLabelDeletion = nil }
        } message: { _ in
            Text("Projects that use this label will keep their transcripts but lose this tag.")
        }
        .alert(
            "Rename Project",
            isPresented: Binding(
                get: { renamingProject != nil },
                set: { if !$0 { renamingProject = nil } }
            ),
            presenting: renamingProject
        ) { project in
            TextField("Title", text: $renameDraft)
            Button("Save") { commitRename(for: project) }
            Button("Cancel", role: .cancel) { renamingProject = nil }
        } message: { _ in
            Text("Choose a new name for this transcription project.")
        }
    }

    private func commitRename(for project: TranscriptionProject) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != project.title {
            let previous = project.title
            project.title = trimmed
            service.recordEdit(
                .titleChanged(previousTitle: previous),
                summary: "Renamed to \"\(trimmed)\"",
                in: project
            )
        }
        try? modelContext.save()
        renamingProject = nil
    }

    private func beginRename(_ project: TranscriptionProject) {
        renameDraft = project.title
        renamingProject = project
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                if projects.isEmpty {
                    Text("No projects yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                } else if searchResults.isEmpty {
                    Text("No matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                } else {
                    ForEach(searchResults, id: \.project.id) { result in
                        ProjectRow(
                            title: result.project.title,
                            snippet: result.snippet,
                            labels: result.project.labels
                        )
                        .tag(SidebarDestination.project(result.project.id))
                        .contextMenu {
                            Button {
                                beginRename(result.project)
                            } label: {
                                Label("Rename…", systemImage: "pencil")
                            }
                            Menu {
                                LabelPickerPopover(project: result.project)
                            } label: {
                                Label("Labels…", systemImage: "tag")
                            }
                            Divider()
                            Button(role: .destructive) {
                                pendingDeletion = result.project
                            } label: {
                                Label("Delete Project", systemImage: "trash")
                            }
                        }
                    }
                }
            }

        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        selection = .projectsGrid
                    } label: {
                        Label("Projects", systemImage: "square.grid.2x2.fill")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        isImporting = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .frame(maxHeight: .infinity)
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("New Transcription")
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                Divider()
            }
            .background(.bar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                labelsPanel
                Divider()
                Button {
                    selection = .privacy
                } label: {
                    Label("About Application Privacy", systemImage: "lock.shield")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(
                    selection == .privacy
                        ? AnyShapeStyle(.tint.opacity(0.2))
                        : AnyShapeStyle(.clear)
                )
            }
            .background(.bar)
        }
    }

    // MARK: - Pinned labels panel

    private var labelsPanel: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "tag")
                    .font(.caption2)
                Text("Labels")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    creatingLabel = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Label")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 5)
            .padding(.bottom, 2)

            if labels.isEmpty {
                Text("No labels yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 5)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(labels) { label in
                            LabelSidebarRow(
                                label: label,
                                isSelected: selection == .label(label.id),
                                onTap: { selection = .label(label.id) },
                                onEdit: { editingLabel = label },
                                onDelete: { pendingLabelDeletion = label }
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 140)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .project(let id):
            if let project = projects.first(where: { $0.id == id }) {
                EditorView(project: project)
            } else {
                WelcomeView { isImporting = true }
            }
        case .projectsGrid:
            ProjectsGridView(
                projects: gridProjects(for: nil),
                activeLabel: nil,
                onSelect: { selection = .project($0) },
                onRename: beginRename,
                onDelete: { pendingDeletion = $0 }
            )
        case .label(let id):
            if let label = labels.first(where: { $0.id == id }) {
                ProjectsGridView(
                    projects: gridProjects(for: label),
                    activeLabel: label,
                    onSelect: { selection = .project($0) },
                    onRename: beginRename,
                    onDelete: { pendingDeletion = $0 }
                )
            } else {
                WelcomeView { isImporting = true }
            }
        case .privacy:
            PrivacyView()
        case .none:
            WelcomeView { isImporting = true }
        }
    }

    /// Projects to show in the grid. When a search is active we honor the
    /// relevance order; otherwise we show chronological (oldest → newest).
    private func gridProjects(for label: ProjectLabel?) -> [TranscriptionProject] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let scoped = searchResults.map(\.project)
            if let label {
                return scoped.filter { p in p.labels.contains { $0.id == label.id } }
            }
            return scoped
        }
        let pool: [TranscriptionProject]
        if let label {
            pool = projects.filter { p in p.labels.contains { $0.id == label.id } }
        } else {
            pool = projects
        }
        return pool.sorted { $0.createdAt < $1.createdAt }
    }
}

private struct LabelSidebarRow: View {
    let label: ProjectLabel
    let isSelected: Bool
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: label.colorHex))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                Text(label.name)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                if label.projects.count > 0 {
                    Text("\(label.projects.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.clear))
        )
        .contextMenu {
            Button(action: onEdit) {
                Label("Edit Label…", systemImage: "pencil")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete Label", systemImage: "trash")
            }
        }
    }
}

private struct ProjectSearchResult {
    let project: TranscriptionProject
    let score: Int
    let snippet: String?
}

private struct ProjectRow: View {
    let title: String
    let snippet: String?
    let labels: [ProjectLabel]

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "waveform")
                .font(.callout)
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .lineLimit(1)
                    if !labels.isEmpty {
                        HStack(spacing: 2) {
                            ForEach(labels.prefix(4)) { label in
                                Circle()
                                    .fill(Color(hex: label.colorHex))
                                    .frame(width: 6, height: 6)
                            }
                        }
                    }
                }
                if let snippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 1)
    }
}

private struct FloatingSearchField: View {
    @Binding var text: String
    @State private var isExpanded = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if isExpanded {
                    if text.isEmpty {
                        collapse()
                    } else {
                        isFocused = true
                    }
                } else {
                    expand()
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.medium))
                    .foregroundStyle(isExpanded ? .primary : .secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                TextField("Search or #label", text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .frame(width: 200)
                    .onSubmit { if text.isEmpty { collapse() } }

                if !text.isEmpty {
                    Button {
                        text = ""
                        isFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isExpanded)
        .onChange(of: isFocused) { _, focused in
            if !focused && text.isEmpty {
                collapse()
            }
        }
    }

    private func expand() {
        isExpanded = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isFocused = true
        }
    }

    private func collapse() {
        isFocused = false
        isExpanded = false
    }
}
