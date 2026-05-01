import SwiftUI
import SwiftData

@main
struct TranscriptyApp: App {
    let container: ModelContainer
    @State private var transcriptionService: TranscriptionService

    init() {
        do {
            let container = try ModelContainer(
                for: TranscriptionProject.self,
                SpeakerSegment.self,
                ProjectLabel.self,
                ProjectEdit.self
            )
            self.container = container
            _transcriptionService = State(
                initialValue: TranscriptionService(modelContext: container.mainContext)
            )
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(transcriptionService)
        }
        .modelContainer(container)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
        }
    }
}
