import SwiftUI

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Header()
                InfoCard(
                    icon: "cpu",
                    title: "Everything runs on your Mac",
                    detail: "Transcripty uses Apple's on-device Speech framework and bundled machine-learning models to transcribe audio and identify different speakers. No audio, transcripts, or metadata are ever sent over the network."
                )
                InfoCard(
                    icon: "apple.logo",
                    title: "Apple's on-device intelligence",
                    detail: "Apple Intelligence refers to the foundation models Apple ships as part of macOS. These models run on your Mac's Neural Engine, not in the cloud. Transcripty uses these local capabilities alongside the on-device Speech framework to deliver private transcription."
                )
                InfoCard(
                    icon: "lock.shield",
                    title: "Sandboxed storage",
                    detail: "Your projects, audio files, and transcripts are stored in Transcripty's app sandbox on this Mac. The app has no permission to reach the network, and it requests only the file access you grant."
                )
                InfoCard(
                    icon: "network.slash",
                    title: "No accounts, no telemetry",
                    detail: "There is no sign-in, no analytics, and no telemetry. Transcripty has no servers."
                )
                InfoCard(
                    icon: "arrow.down.circle",
                    title: "One-time model download",
                    detail: "The first time you transcribe, two things are downloaded so they can run on your Mac forever after: Apple's signed speech model for your language (fetched by macOS from Apple), and the open-source FluidAudio speaker-diarization Core ML models (fetched from the FluidInference repository on Hugging Face). Only the models are downloaded — no audio or personal data leaves your Mac. After the first run, transcription is fully offline."
                )
                InfoCard(
                    icon: "person.2.wave.2",
                    title: "On-device speaker separation",
                    detail: "Telling speakers apart uses FluidAudio — an open-source Swift package that runs pyannote segmentation and WeSpeaker embeddings through Apple's Neural Engine. Like Apple's speech model, it executes entirely on your Mac."
                )
                Spacer(minLength: 20)
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("About Application Privacy")
    }
}

private struct Header: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Your audio never leaves this Mac.")
                .font(.largeTitle.weight(.semibold))
            Text("Transcripty is designed so that the only machine that ever sees your recordings is yours.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }
}

private struct InfoCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
