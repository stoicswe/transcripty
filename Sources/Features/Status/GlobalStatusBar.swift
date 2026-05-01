import SwiftUI

/// Thin banner pinned to the top of the window that surfaces long-running
/// setup work — primarily the first-launch model downloads for speech and
/// diarization. Hides itself as soon as every active job has moved past its
/// preparation phases.
struct GlobalStatusBar: View {
    @Environment(TranscriptionService.self) private var service

    var body: some View {
        Group {
            if let status = currentStatus {
                banner(status)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: currentStatus)
    }

    private func banner(_ status: Status) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.subheadline.weight(.semibold))
                Text(status.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let fraction = status.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 140)
                    .tint(.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.separator)
                .frame(height: 0.5)
        }
    }

    private var currentStatus: Status? {
        for job in service.jobs.values {
            switch job.phase {
            case .preparingDiarizer:
                return Status(
                    title: "Preparing speaker models",
                    subtitle: "One-time download of the on-device diarization models.",
                    fraction: nil
                )
            case .downloadingTranscriberModel:
                return Status(
                    title: "Downloading speech model",
                    subtitle: "Apple's on-device model for your language. Happens once.",
                    fraction: job.modelDownloadFraction
                )
            case .preparingTranscriber:
                return Status(
                    title: "Preparing speech model",
                    subtitle: "Getting the on-device speech model ready…",
                    fraction: nil
                )
            default:
                continue
            }
        }
        return nil
    }

    private struct Status: Equatable {
        let title: String
        let subtitle: String
        let fraction: Double?
    }
}
