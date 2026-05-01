import SwiftUI
import SwiftData
import AVFoundation

/// Static mini-waveform used in the projects grid. Non-interactive. Pulls
/// peaks from `ProjectWaveformCache` so the audio file is scanned at most
/// once per project across the app's lifetime.
struct WaveformThumbnail: View {
    let project: TranscriptionProject?

    @Environment(\.modelContext) private var modelContext
    @State private var peaks: [Float] = []
    @State private var isLoading = true

    var body: some View {
        ZStack {
            if isLoading {
                ProgressView().controlSize(.small)
            } else if peaks.isEmpty {
                Image(systemName: "waveform")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary.opacity(0.5))
            } else {
                Canvas { ctx, size in
                    let count = peaks.count
                    let spacing: CGFloat = 1
                    let barWidth = max(1, (size.width - CGFloat(count - 1) * spacing) / CGFloat(count))
                    let midY = size.height / 2
                    for (i, peak) in peaks.enumerated() {
                        let x = CGFloat(i) * (barWidth + spacing)
                        let h = max(1.2, CGFloat(peak) * (size.height - 2))
                        let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                 with: .color(.accentColor.opacity(0.75)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: project?.id) { await load() }
    }

    private func load() async {
        guard let project else {
            peaks = []
            isLoading = false
            return
        }
        isLoading = true
        let result = await ProjectWaveformCache.peaks(
            for: project,
            targetCount: 140,
            modelContext: modelContext
        )
        peaks = result
        isLoading = false
    }
}
