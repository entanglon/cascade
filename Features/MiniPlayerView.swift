import SwiftUI
import AppKit

struct MiniPlayerView: View {
    @Environment(AppState.self) private var appState
    @Bindable var audioEngine = AudioPlayerEngine.shared
    @State private var thumbURL: URL? = nil

    var body: some View {
        if let track = audioEngine.currentTrack {
            VStack(spacing: 0) {
                if audioEngine.isFullScreen {
                    audioTheaterOverlay(track: track)
                } else {
                    miniBar(track: track)
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: audioEngine.isFullScreen)
            .task(id: track.id) {
                thumbURL = await ThumbnailService.shared.thumbnailURL(for: track)
            }
        }
    }

    // MARK: - Mini Bar

    private func miniBar(track: ObjectRecord) -> some View {
        HStack(spacing: 14) {
            // Album Art Badge with Equalizer
            ZStack {
                if let thumbURL, let nsImage = NSImage(contentsOf: thumbURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: XTheme.accent.opacity(0.4), radius: 6, y: 3)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(XTheme.brandGradient)
                        .frame(width: 44, height: 44)
                        .shadow(color: XTheme.accent.opacity(0.4), radius: 6, y: 3)

                    if audioEngine.isPlaying {
                        EqualizerWaveformView(barCount: 4)
                            .frame(width: 20, height: 18)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }
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
                        Circle().fill(XTheme.accent)
                            .frame(width: 34, height: 34)
                            .shadow(color: XTheme.accent.opacity(0.4), radius: 4, y: 2)
                        Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: audioEngine.isPlaying ? 0 : 1)
                    }
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
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

    // MARK: - Full Screen Audio Theater

    private func audioTheaterOverlay(track: ObjectRecord) -> some View {
        ZStack {
            // Full screen backdrop with rounded corners
            Color.black.opacity(0.96)

            VStack(spacing: 32) {
                // Top Header
                HStack {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            audioEngine.isFullScreen = false
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 36, height: 36)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("NOW PLAYING")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(XTheme.accent)

                    Spacer()

                    Button { audioEngine.stop() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 36, height: 36)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)

                Spacer()

                // Large Album Art Badge with Equalizer Spectrum
                ZStack {
                    Circle()
                        .fill(XTheme.brandGradient)
                        .frame(width: 220, height: 220)
                        .shadow(color: XTheme.accent.opacity(0.5), radius: 30, y: 10)

                    if audioEngine.isPlaying {
                        EqualizerWaveformView(barCount: 7)
                            .frame(width: 100, height: 90)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 80, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

                // Track Title & Info
                VStack(spacing: 6) {
                    Text(track.name)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    Text(ByteCountFormatter.string(fromByteCount: track.size, countStyle: .file))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 40)

                // Scrub Bar
                VStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { audioEngine.currentTime },
                            set: { audioEngine.seek(to: $0) }
                        ),
                        in: 0...max(1, audioEngine.duration)
                    )
                    .tint(XTheme.accent)

                    HStack {
                        Text(timeString(audioEngine.currentTime))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Text(timeString(audioEngine.duration))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 40)

                // Playback Controls
                HStack(spacing: 36) {
                    Button { audioEngine.skipPrevious() } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 50, height: 50)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Button { audioEngine.togglePlayPause() } label: {
                        ZStack {
                            Circle().fill(XTheme.accent)
                                .frame(width: 68, height: 68)
                                .shadow(color: XTheme.accent.opacity(0.6), radius: 14, y: 6)
                            Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: audioEngine.isPlaying ? 0 : 2)
                        }
                        .frame(width: 68, height: 68)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Button { audioEngine.skipNext() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 50, height: 50)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }

            KeyMonitorView {
                withAnimation(.easeOut(duration: 0.2)) {
                    audioEngine.isFullScreen = false
                }
            }
            .frame(width: 0, height: 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onKeyPress(.space) {
            audioEngine.togglePlayPause()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            audioEngine.skipPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            audioEngine.skipNext()
            return .handled
        }
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

    var body: some View {
        TimelineView(.animation) { timeline in
            let date = timeline.date.timeIntervalSince1970
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    let phase = Double(index) * 0.85
                    let speed = 4.5 + Double(index % 3) * 1.5
                    let primary = sin(date * speed + phase) * 0.45 + 0.55
                    let secondary = sin(date * 8.5 + phase * 2.2) * 0.25
                    let factor = max(0.18, min(1.0, primary + secondary))

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
