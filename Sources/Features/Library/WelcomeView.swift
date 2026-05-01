import SwiftUI

struct WelcomeView: View {
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.tint)
            Text("Transcripty")
                .font(.largeTitle.weight(.semibold))
            Text("Select a project from the sidebar, or import an audio file to create a new one.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button(action: onImport) {
                Label("New Transcription", systemImage: "plus.circle.fill")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
