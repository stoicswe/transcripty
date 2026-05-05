import SwiftUI
import SwiftData

@main
struct TranscriptyApp: App {
    let container: ModelContainer
    @State private var transcriptionService: TranscriptionService
    @State private var voicePrintService: SpeakerVoicePrintService
    /// Mirrors the toggle in Preferences → Word Timings. Read here so the
    /// background healer comes back on automatically on app launch when
    /// the user previously enabled it; the actual start/stop call lives
    /// in a `task` modifier on the root view below.
    @AppStorage("editor.backgroundTimingHealing") private var backgroundHealing: Bool = false

    init() {
        do {
            let container = try ModelContainer(
                for: TranscriptionProject.self,
                SpeakerSegment.self,
                ProjectLabel.self,
                ProjectEdit.self
            )
            self.container = container
            // Share one Diarizer instance across both services. The diarizer
            // is `Sendable` and stateless across calls (each invocation
            // builds its own `OfflineDiarizerManager`), so passing the
            // same reference everywhere is fine and keeps configuration
            // tweaks in one place.
            let diarizer: any Diarizer = FluidAudioDiarizer()
            _transcriptionService = State(
                initialValue: TranscriptionService(
                    modelContext: container.mainContext,
                    diarizer: diarizer
                )
            )
            _voicePrintService = State(
                initialValue: SpeakerVoicePrintService(diarizer: diarizer)
            )
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(transcriptionService)
                .environment(voicePrintService)
                // Sync the background-healer task with the user's
                // preference: launch it if they had it on last session,
                // and follow toggles inside the Preferences pane.
                .task(id: backgroundHealing) {
                    transcriptionService.setBackgroundHealingEnabled(backgroundHealing)
                }
        }
        .modelContainer(container)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
        }
    }
}
