import SwiftUI
import SwiftData
import AVFoundation

/// Vertical-bar waveform of the source audio that doubles as a scrub target.
/// Peaks come from `ProjectWaveformCache`, so the audio file is scanned once
/// per project and reused across renders, views, and app launches.
struct WaveformView: View {
    let project: TranscriptionProject
    let duration: TimeInterval
    let currentTime: TimeInterval
    let onScrub: (TimeInterval) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var peaks: [Float] = []
    @State private var isLoading = true

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    WaveformBars(peaks: peaks, progress: progress)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    scrub(x: value.location.x, width: geo.size.width)
                                }
                        )
                }
            }
        }
        .task(id: project.id) { await loadPeaks() }
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, currentTime / duration))
    }

    private func scrub(x: CGFloat, width: CGFloat) {
        guard width > 0, duration > 0 else { return }
        let fraction = max(0, min(1, x / width))
        onScrub(fraction * duration)
    }

    private func loadPeaks() async {
        isLoading = true
        let result = await ProjectWaveformCache.peaks(
            for: project,
            targetCount: 400,
            modelContext: modelContext
        )
        peaks = result
        isLoading = false
    }
}

private struct WaveformBars: View {
    let peaks: [Float]
    let progress: Double

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty else { return }
            let count = peaks.count
            let spacing: CGFloat = 1
            let barWidth = max(1, (size.width - CGFloat(count - 1) * spacing) / CGFloat(count))
            let progressX = size.width * CGFloat(progress)
            let midY = size.height / 2
            let glowRadius: CGFloat = 28

            let playedGradient = Gradient(colors: [
                .accentColor,
                .accentColor.opacity(0.55)
            ])

            for (i, peak) in peaks.enumerated() {
                let x = CGFloat(i) * (barWidth + spacing)
                let centerX = x + barWidth / 2
                let h = max(1.5, CGFloat(peak) * (size.height - 2))
                let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)

                let distance = abs(centerX - progressX)
                let glow = max(0, 1 - distance / glowRadius)
                let played = centerX < progressX

                let shading: GraphicsContext.Shading
                if played {
                    shading = .linearGradient(
                        playedGradient,
                        startPoint: CGPoint(x: 0, y: rect.minY),
                        endPoint: CGPoint(x: 0, y: rect.maxY)
                    )
                } else {
                    // Upcoming bars sit in a muted accent tone, with a soft
                    // tint boost right at the edge of playback so the
                    // "where we are" sweet-spot reads at a glance.
                    let opacity = 0.28 + 0.35 * glow
                    shading = .color(.accentColor.opacity(opacity))
                }
                ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: shading)
            }

            // Playhead: thin vertical accent line with a subtle halo behind it.
            let haloRect = CGRect(x: progressX - 6, y: 0, width: 12, height: size.height)
            ctx.fill(
                Path(roundedRect: haloRect, cornerRadius: 6),
                with: .color(.accentColor.opacity(0.12))
            )
            let lineRect = CGRect(x: progressX - 0.75, y: 0, width: 1.5, height: size.height)
            ctx.fill(
                Path(roundedRect: lineRect, cornerRadius: 0.75),
                with: .color(.accentColor.opacity(0.9))
            )
        }
    }
}

enum WaveformExtractor {
    /// Reads `audioURL` into PCM and returns `targetCount` normalized amplitude
    /// buckets in [0, 1]. Safe to call off the main actor. Returns `[]` on
    /// failure.
    ///
    /// The shape is designed to read well in a UI:
    ///   * Each bucket blends its RMS (body) with its peak (transient snap),
    ///     so bars retain the "crack" of consonants without being dictated by
    ///     one-sample spikes.
    ///   * Normalization targets the 95th percentile instead of the absolute
    ///     max, so a single loud door-slam doesn't flatten the rest of an
    ///     hour of speech.
    ///   * An expanding gamma (> 1.0) widens the visual dynamic range — quiet
    ///     passages stay genuinely short, loud peaks reach the ceiling.
    static func extractPeaks(from audioURL: URL, targetCount: Int) -> [Float] {
        let accessed = audioURL.startAccessingSecurityScopedResource()
        defer { if accessed { audioURL.stopAccessingSecurityScopedResource() } }

        guard let file = try? AVAudioFile(forReading: audioURL) else { return [] }
        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { return [] }

        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard channels > 0 else { return [] }

        let bucketSize = max(1, totalFrames / targetCount)
        let chunkFrames: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            return []
        }

        var buckets: [Float] = []
        buckets.reserveCapacity(targetCount + 1)
        var bucketPeak: Float = 0
        var bucketSumSquares: Double = 0
        var framesInBucket = 0

        func flushBucket() {
            guard framesInBucket > 0 else { return }
            let rms = Float((bucketSumSquares / Double(framesInBucket)).squareRoot())
            // RMS gives the visual "body" of the signal; peak adds transient
            // snap. 65/35 favours RMS for smoother envelopes.
            let combined = 0.65 * rms + 0.35 * bucketPeak
            buckets.append(combined)
            bucketPeak = 0
            bucketSumSquares = 0
            framesInBucket = 0
        }

        while file.framePosition < file.length {
            do { try file.read(into: buffer) } catch { break }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channelData = buffer.floatChannelData else { break }

            for j in 0..<frames {
                var sample: Float = 0
                for c in 0..<channels {
                    let v = abs(channelData[c][j])
                    if v > sample { sample = v }
                }
                if sample > bucketPeak { bucketPeak = sample }
                bucketSumSquares += Double(sample) * Double(sample)
                framesInBucket += 1
                if framesInBucket >= bucketSize { flushBucket() }
            }
        }
        flushBucket()

        guard !buckets.isEmpty else { return [] }

        let sorted = buckets.sorted()
        let percentileIndex = min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
        let reference = max(sorted[percentileIndex], 1e-5)

        return buckets.map { value in
            let normalized = min(1, value / reference)
            // gamma > 1 expands contrast: quiet stays quiet, loud hits full
            // height. The low floor lets genuine silences render as almost
            // nothing instead of a visible sliver.
            let shaped = pow(normalized, 1.35)
            return max(0.015, shaped)
        }
    }
}
