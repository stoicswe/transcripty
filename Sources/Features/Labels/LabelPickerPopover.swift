import SwiftUI
import SwiftData

/// Toggleable checklist of all labels + a shortcut to create a new one,
/// used from a project's context menu.
struct LabelPickerPopover: View {
    let project: TranscriptionProject

    @Query(sort: \ProjectLabel.name) private var allLabels: [ProjectLabel]
    @Environment(\.modelContext) private var modelContext
    @Environment(TranscriptionService.self) private var service

    @State private var showingEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Labels")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if allLabels.isEmpty {
                Text("No labels yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(allLabels) { label in
                            LabelToggleRow(project: project, label: label)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(maxHeight: 220)
            }

            Divider().padding(.vertical, 4)

            Button {
                showingEditor = true
            } label: {
                Label("New Label…", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 8)
        .frame(width: 240)
        .sheet(isPresented: $showingEditor) {
            LabelEditorSheet(existing: nil) { created in
                if !project.labels.contains(where: { $0.id == created.id }) {
                    project.labels.append(created)
                    service.recordEdit(
                        .labelAdded(labelID: created.id),
                        summary: "Added label \"\(created.name)\"",
                        in: project
                    )
                    try? modelContext.save()
                }
            }
        }
    }
}

private struct LabelToggleRow: View {
    let project: TranscriptionProject
    let label: ProjectLabel

    @Environment(\.modelContext) private var modelContext
    @Environment(TranscriptionService.self) private var service

    private var isApplied: Bool {
        project.labels.contains(where: { $0.id == label.id })
    }

    var body: some View {
        Button {
            toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isApplied ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isApplied ? Color(hex: label.colorHex) : .secondary)
                Circle()
                    .fill(Color(hex: label.colorHex))
                    .frame(width: 10, height: 10)
                Text(label.name)
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func toggle() {
        if isApplied {
            project.labels.removeAll { $0.id == label.id }
            service.recordEdit(
                .labelRemoved(labelID: label.id),
                summary: "Removed label \"\(label.name)\"",
                in: project
            )
        } else {
            project.labels.append(label)
            service.recordEdit(
                .labelAdded(labelID: label.id),
                summary: "Added label \"\(label.name)\"",
                in: project
            )
        }
        try? modelContext.save()
    }
}
