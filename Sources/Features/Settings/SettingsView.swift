import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 340)
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
