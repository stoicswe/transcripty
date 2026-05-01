import SwiftUI
import SwiftData

/// Inline row of applied-label chips with a "+ Label" button that opens
/// `LabelPickerPopover`. Sits at the top of `EditorView`.
struct LabelsBar: View {
    let project: TranscriptionProject

    @Environment(\.modelContext) private var modelContext
    @Environment(TranscriptionService.self) private var service
    @State private var showingPicker = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(project.labels) { label in
                    LabelChip(label: label) { remove(label) }
                }

                Button {
                    showingPicker.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text(project.labels.isEmpty ? "Add Label" : "Label")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().strokeBorder(.secondary.opacity(0.4),
                                               style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                    LabelPickerPopover(project: project)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func remove(_ label: ProjectLabel) {
        guard project.labels.contains(where: { $0.id == label.id }) else { return }
        project.labels.removeAll { $0.id == label.id }
        service.recordEdit(
            .labelRemoved(labelID: label.id),
            summary: "Removed label \"\(label.name)\"",
            in: project
        )
        try? modelContext.save()
    }
}

private struct LabelChip: View {
    let label: ProjectLabel
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(hex: label.colorHex))
                .frame(width: 8, height: 8)
            Text(label.name)
                .font(.caption)
            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove label")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color(hex: label.colorHex).opacity(0.18))
        )
        .overlay(
            Capsule().strokeBorder(Color(hex: label.colorHex).opacity(0.4), lineWidth: 0.5)
        )
        .onHover { isHovered = $0 }
    }
}
