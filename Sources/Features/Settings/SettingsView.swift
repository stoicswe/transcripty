import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
            WordTimingsSettings()
                .tabItem { Label("Word Timings", systemImage: "waveform.path.badge.plus") }
            StorageSettings()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 480, height: 340)
    }
}

/// Preferences for the always-on idle-time word-timing healer (Option C).
/// The toggle is observed by `TranscriptyApp`, which wires it into the
/// `TranscriptionService.setBackgroundHealingEnabled(_:)` method —
/// flipping it on starts a long-lived background task that walks the
/// project store and re-aligns the oldest-validated segments first; off
/// cancels the task. Default is off so users opt in deliberately.
private struct WordTimingsSettings: View {
    @Environment(TranscriptionService.self) private var service
    @AppStorage("editor.backgroundTimingHealing") private var backgroundHealing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Word Timing Self-Healing")
                .font(.headline)

            Toggle(isOn: $backgroundHealing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Continuously refine word timings in the background")
                        .font(.subheadline.weight(.semibold))
                    Text("When idle, Transcripty re-runs forced alignment on the oldest-validated segments across all projects, one at a time, so playback highlighting stays in sync with the audio. Pauses automatically while transcription or a manual recompute is running. Off by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: backgroundHealing) { _, enabled in
                service.setBackgroundHealingEnabled(enabled)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("How auto-alignment works")
                    .font(.subheadline.weight(.semibold))
                Text("Word timings always update automatically after edits, splits, merges, and word moves — no toggle required. Playback also re-validates segments as you reach them. The setting above is for the slower, deeper pass that runs when nothing else is going on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct StorageSettings: View {
    private var projectsDirectory: URL? {
        guard let audio = try? AudioStorage.audioDirectory() else { return nil }
        return audio.deletingLastPathComponent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Projects on Disk")
                .font(.headline)

            Text("Transcripty stores imported audio and transcripts inside its app sandbox.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let url = projectsDirectory {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Location")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(url.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.quaternary.opacity(0.4))
                        )
                }

                HStack {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    Spacer()
                }
            } else {
                Text("Couldn't locate the storage directory.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)

            if let icon = NSApp?.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
            }

            Text(appName)
                .font(.title.weight(.semibold))

            VStack(spacing: 2) {
                Text("Version \(version)")
                    .font(.subheadline)
                Text("Build \(build)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Private, offline audio transcription for macOS.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Spacer()

            Text(copyright)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appName: String {
        bundleString("CFBundleDisplayName")
            ?? bundleString("CFBundleName")
            ?? "Transcripty"
    }

    private var version: String { bundleString("CFBundleShortVersionString") ?? "0.0" }
    private var build: String { bundleString("CFBundleVersion") ?? "0" }
    private var copyright: String { bundleString("NSHumanReadableCopyright") ?? "" }

    private func bundleString(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
