import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportView: View {
    let onCreated: (UUID) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(TranscriptionService.self) private var transcriptionService
    @State private var isTargeted = false
    @State private var showingPicker = false
    @State private var importError: String?
    /// `nil` means auto-detect. 1…5 are concrete hints; 6 represents "6+"
    /// and is passed through as-is so VBx still treats it as a cap.
    @State private var expectedSpeakerCount: Int? = nil

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
            Text("Drop an audio file to begin")
                .font(.title2)
                .foregroundStyle(.secondary)

            speakerCountPicker

            Button("Choose File…") { showingPicker = true }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(isTargeted ? Color.accentColor : .secondary.opacity(0.3),
                              style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(20)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: Self.isSupportedAudio) else { return false }
            createProject(from: url)
            return true
        } isTargeted: { isTargeted = $0 }
        .fileImporter(isPresented: $showingPicker,
                      allowedContentTypes: Self.allowedTypes,
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                createProject(from: url)
            }
        }
        .navigationTitle("New Transcription")
        .alert("Couldn't import audio",
               isPresented: Binding(
                   get: { importError != nil },
                   set: { if !$0 { importError = nil } }
               ),
               presenting: importError) { _ in
            Button("OK", role: .cancel) { importError = nil }
        } message: { message in
            Text(message)
        }
    }

    private var speakerCountPicker: some View {
        VStack(spacing: 6) {
            Text("Expected Speakers")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Expected Speakers", selection: $expectedSpeakerCount) {
                Text("Auto").tag(Int?.none)
                ForEach([1, 2, 3, 4, 5], id: \.self) { n in
                    Text("\(n)").tag(Int?.some(n))
                }
                Text("6+").tag(Int?.some(6))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            Text("Telling Transcripty how many speakers to expect dramatically improves separation accuracy.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
    }

    private static let allowedTypes: [UTType] = [
        .audio, .mp3, .mpeg4Audio, .wav, .aiff, .appleProtectedMPEG4Audio
    ]

    private static func isSupportedAudio(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return ["mp3", "m4a", "wav", "aiff", "aif", "caf", "flac"].contains(url.pathExtension.lowercased())
        }
        return type.conforms(to: .audio)
    }

    private func createProject(from url: URL) {
        let project = TranscriptionProject(
            title: url.deletingPathExtension().lastPathComponent
        )
        project.expectedSpeakerCount = expectedSpeakerCount
        modelContext.insert(project)

        do {
            let filename = try AudioStorage.importAudio(from: url, projectID: project.id)
            project.storedAudioFilename = filename
            try? modelContext.save()
        } catch {
            modelContext.delete(project)
            try? modelContext.save()
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }

        transcriptionService.start(project: project)
        onCreated(project.id)
    }
}
