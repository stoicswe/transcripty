import SwiftUI
import SwiftData

struct ProjectsGridView: View {
    /// Already-filtered, chronologically-ordered projects to render.
    let projects: [TranscriptionProject]
    /// Non-nil when the grid is scoped to a single label filter.
    let activeLabel: ProjectLabel?
    let onSelect: (UUID) -> Void
    let onRename: (TranscriptionProject) -> Void
    let onDelete: (TranscriptionProject) -> Void

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 16)]

    var body: some View {
        ScrollView {
            if projects.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(activeLabel == nil ? "No projects yet" : "No projects with this label")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(projects) { project in
                        ProjectTile(project: project)
                            .onTapGesture { onSelect(project.id) }
                            .contextMenu {
                                Button {
                                    onRename(project)
                                } label: {
                                    Label("Rename…", systemImage: "pencil")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    onDelete(project)
                                } label: {
                                    Label("Delete Project", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle(activeLabel?.name ?? "Projects")
    }
}

private struct ProjectTile: View {
    let project: TranscriptionProject

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WaveformThumbnail(project: project)
                .frame(height: 84)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.quaternary.opacity(0.4))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(project.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(project.createdAt, format: .dateTime.month().day().year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !project.labels.isEmpty {
                labelChips
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.separator.opacity(isHovered ? 0.7 : 0.3), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(isHovered ? 0.15 : 0.08), radius: isHovered ? 10 : 4, y: 2)
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var labelChips: some View {
        HStack(spacing: 4) {
            ForEach(project.labels.prefix(4)) { label in
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color(hex: label.colorHex))
                        .frame(width: 7, height: 7)
                    Text(label.name)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Color(hex: label.colorHex).opacity(0.15))
                )
            }
            if project.labels.count > 4 {
                Text("+\(project.labels.count - 4)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
