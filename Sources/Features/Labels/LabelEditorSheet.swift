import SwiftUI
import SwiftData

/// Create or rename/recolor a `ProjectLabel`. Pass `label = nil` to create
/// a new one; pass an existing label to edit it in place.
struct LabelEditorSheet: View {
    let existing: ProjectLabel?
    let onDone: (ProjectLabel) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name: String = ""
    @State private var color: Color = Color(hex: LabelPalette.randomPreset())

    private var isEditing: Bool { existing != nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Edit Label" : "New Label")
                .font(.title3.weight(.semibold))

            HStack(spacing: 12) {
                ColorPicker("", selection: $color, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 44, height: 28)

                TextField("Label name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
            }

            Text("Presets")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(LabelPalette.presets, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1)
                        )
                        .onTapGesture { color = Color(hex: hex) }
                }
            }

            Spacer(minLength: 8)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            if let existing {
                name = existing.name
                color = Color(hex: existing.colorHex)
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let hex = color.toHex() ?? LabelPalette.randomPreset()

        let label: ProjectLabel
        if let existing {
            existing.name = trimmed
            existing.colorHex = hex
            label = existing
        } else {
            label = ProjectLabel(name: trimmed, colorHex: hex)
            modelContext.insert(label)
        }
        try? modelContext.save()
        onDone(label)
        dismiss()
    }
}
