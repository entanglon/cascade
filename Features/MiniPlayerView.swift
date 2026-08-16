import SwiftUI
import AppKit

struct MiniPlayerView: View {
    @Environment(AppState.self) private var appState
    @Bindable var audioEngine = AudioPlayerEngine.shared
    @State private var thumbURL: URL? = nil

    var body: some View {
        Group {
            // The mini player is the AUDIO player's compact form: it only exists
            // for audio tracks (videos stop when the theater closes — no background
            // playback), and only while the theater is closed (the full player
            // replaces it there — never two players for the same track).
            if let track = audioEngine.currentTrack,
               !track.isVideo,
               appState.theaterFile == nil {
                miniBar(track: track)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Minimize (theater → mini) springs the bar in as the theater fades out.
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: appState.theaterFile?.id)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: audioEngine.currentTrack?.id)
        .task(id: audioEngine.currentTrack?.id) {
            guard let track = audioEngine.currentTrack, !track.isVideo else { return }
            thumbURL = await ThumbnailService.shared.thumbnailURL(for: track)
        }
    }

    // MARK: - Mini Bar

    private func miniBar(track: ObjectRecord) -> some View {
        HStack(spacing: 14) {
            // Album Art Badge with Equalizer (Round Circle)
            ZStack {
                if let thumbURL, let nsImage = NSImage(contentsOf: thumbURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                        .shadow(color: XTheme.accent.opacity(0.4), radius: 6, y: 3)
                } else {
                    Circle()
                        .fill(XTheme.brandGradient)
                        .frame(width: 44, height: 44)
                        .shadow(color: XTheme.accent.opacity(0.4), radius: 6, y: 3)

                    EqualizerWaveformView(barCount: 4, isPlaying: audioEngine.isPlaying)
                        .frame(width: 20, height: 20)
                }
            }

            // Info & Scrub Slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(track.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer()

                    Text(timeString(audioEngine.currentTime) + " / " + timeString(audioEngine.duration))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }

                // Progress slider
                Slider(
                    value: Binding(
                        get: { audioEngine.currentTime },
                        set: { audioEngine.seek(to: $0) }
                    ),
                    in: 0...max(1, audioEngine.duration)
                )
                .tint(XTheme.accent)
                .controlSize(.mini)
            }
            .frame(width: 240)

            // Playback Controls
            HStack(spacing: 8) {
                Button { audioEngine.skipPrevious() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                Button { audioEngine.togglePlayPause() } label: {
                    ZStack {
                        Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: audioEngine.isPlaying ? 0 : 1)
                    }
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)

                Button { audioEngine.skipNext() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 24).overlay(.white.opacity(0.15))

            // Expand to Full Screen
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    appState.theaterFile = track
                }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Expand Player")

            // Close Button
            Button {
                audioEngine.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close Player")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.bottom, 20)
    }

    private func timeString(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Equalizer Waveform Animation

struct EqualizerWaveformView: View {
    let barCount: Int
    var isPlaying: Bool = true

    var body: some View {
        TimelineView(.animation) { timeline in
            let date = timeline.date.timeIntervalSince1970
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    let factor: Double = {
                        guard isPlaying else { return 0.08 }
                        let phase = Double(index) * 0.85
                        let speed = 4.5 + Double(index % 3) * 1.5
                        let primary = sin(date * speed + phase) * 0.45 + 0.55
                        let secondary = sin(date * 8.5 + phase * 2.2) * 0.25
                        return max(0.18, min(1.0, primary + secondary))
                    }()

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white, XTheme.accent.opacity(0.85)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 4, height: CGFloat(factor * 44))
                        .shadow(color: XTheme.accent.opacity(0.4), radius: 2)
                }
            }
        }
    }
}
