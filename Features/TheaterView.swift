import SwiftUI
import AppKit
import AVKit

struct TheaterView: View {
    @Environment(AppState.self) private var appState
    let file: ObjectRecord

    @State private var url: URL?
    @State private var imageScale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var imageOffset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var downloadProgress: Double = 0
    @State private var downloadStatus: String = "Preparing…"
    @State private var errorMessage: String?
    @State private var showControls = true
    @State private var controlsTimer: Timer?

    private var previewKind: PreviewKind {
        let ext = (file.name as NSString).pathExtension.lowercased()
        if file.mime.hasPrefix("image/") { return .image }
        if file.mime.hasPrefix("video/") { return .video }
        if file.mime.contains("pdf") || ext == "pdf" { return .pdf }
        if file.mime.hasPrefix("text/") || ["txt", "md", "json", "log", "csv", "swift"].contains(ext) { return .text }
        return .other
    }

    enum PreviewKind { case image, video, pdf, text, other }

    var body: some View {
        ZStack {
            // Full-bleed background
            Color.black.opacity(0.96).ignoresSafeArea()

            // Content
            Group {
                if let errorMessage {
                    errorView(errorMessage)
                } else if url != nil {
                    contentView
                } else {
                    downloadingView
                }
            }

            // Floating top controls
            VStack {
                if showControls {
                    topControls
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()

                // Bottom info bar
                if showControls, url != nil {
                    bottomInfoBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showControls)

            // Navigation arrows
            if showControls, url != nil {
                navigationOverlay
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onExitCommand {
            appState.theaterFile = nil
        }
        .onKeyPress(.leftArrow) {
            navigateMedia(delta: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            navigateMedia(delta: 1)
            return .handled
        }
        .onKeyPress(.space) {
            if previewKind == .image {
                toggleControls()
            }
            return .handled
        }
        .task(id: file.id) {
            await loadFile()
        }
    }

    // MARK: - Top Controls

    private var topControls: some View {
        HStack(spacing: 14) {
            // Close button
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    appState.theaterFile = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .help("Close (ESC)")

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            // Fullscreen
            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .help("Toggle Full Screen")

            // Open Externally
            Button {
                if let url {
                    NSWorkspace.shared.open(url)
                } else {
                    appState.openFile(file)
                }
            } label: {
                Label("Open Externally", systemImage: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Capsule())
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Bottom Info

    private var bottomInfoBar: some View {
        HStack(spacing: 12) {
            let siblings = mediaFiles
            if let idx = siblings.firstIndex(where: { $0.id == file.id }) {
                Text("\(idx + 1) of \(siblings.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
            }

            Spacer()

            if previewKind == .image {
                Text("\(Int(imageScale * 100))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    // MARK: - Navigation Overlay

    private var navigationOverlay: some View {
        HStack {
            Button { navigateMedia(delta: -1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .opacity(canNavigate(-1) ? 1 : 0.3)
            .disabled(!canNavigate(-1))

            Spacer()

            Button { navigateMedia(delta: 1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .opacity(canNavigate(1) ? 1 : 0.3)
            .disabled(!canNavigate(1))
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch previewKind {
        case .image:
            imageViewer
                .onTapGesture { toggleControls() }
        case .video:
            VideoPlaybackView(object: file)
        default:
            VStack(spacing: 16) {
                Image(systemName: iconForFile)
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(XTheme.accent.opacity(0.6))
                Text(file.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text("This file type can't be previewed.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                Button {
                    if let url {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open with Default App", systemImage: "arrow.up.right.square")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Download Progress

    private var downloadingView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.08), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: downloadProgress)
                    .stroke(
                        XTheme.brandGradient,
                        style: .init(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: downloadProgress)

                VStack(spacing: 2) {
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 80, height: 80)

            VStack(spacing: 6) {
                Text(file.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(downloadStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                    .animation(.easeInOut(duration: 0.15), value: downloadStatus)
            }
        }
        .padding(32)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.red.opacity(0.7))

            VStack(spacing: 6) {
                Text("Failed to Load")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            HStack(spacing: 12) {
                Button {
                    errorMessage = nil
                    downloadProgress = 0
                    downloadStatus = "Preparing…"
                    Task { await loadFile() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)

                Button {
                    appState.theaterFile = nil
                } label: {
                    Text("Close")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(40)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Image Viewer

    @ViewBuilder
    private var imageViewer: some View {
        if let url, let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .scaleEffect(imageScale)
                .offset(imageOffset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            imageScale = lastScale * value
                        }
                        .onEnded { _ in
                            lastScale = imageScale
                            if imageScale < 1.0 {
                                withAnimation(.spring()) {
                                    imageScale = 1.0
                                    lastScale = 1.0
                                    imageOffset = .zero
                                    lastOffset = .zero
                                }
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard imageScale > 1.0 else { return }
                            imageOffset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastOffset = imageOffset
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring()) {
                        if imageScale > 1.0 {
                            imageScale = 1.0
                            lastScale = 1.0
                            imageOffset = .zero
                            lastOffset = .zero
                        } else {
                            imageScale = 2.5
                            lastScale = 2.5
                        }
                    }
                }
                .padding(20)
                .transition(.opacity)
        } else if url != nil {
            ProgressView().tint(.white)
        }
    }

    // MARK: - Helpers

    private var iconForFile: String {
        if file.mime.contains("pdf") { return "doc.richtext" }
        if file.mime.hasPrefix("text/") { return "doc.text" }
        return "doc.fill"
    }

    private var mediaFiles: [ObjectRecord] {
        appState.files.filter { !$0.trashed && !$0.isFolder && $0.parentID == file.parentID }
    }

    private func canNavigate(_ delta: Int) -> Bool {
        let files = mediaFiles
        guard let idx = files.firstIndex(where: { $0.id == file.id }) else { return false }
        let next = idx + delta
        return next >= 0 && next < files.count
    }

    private func navigateMedia(delta: Int) {
        let files = mediaFiles
        guard let currentIndex = files.firstIndex(where: { $0.id == file.id }) else { return }
        let nextIndex = min(max(currentIndex + delta, 0), files.count - 1)
        guard nextIndex != currentIndex else { return }
        appState.theaterFile = files[nextIndex]
    }

    private func toggleControls() {
        withAnimation {
            showControls.toggle()
        }
    }

    private func loadFile() async {
        imageScale = 1.0
        lastScale = 1.0
        imageOffset = .zero
        lastOffset = .zero
        url = nil
        errorMessage = nil
        downloadProgress = 0
        downloadStatus = "Preparing…"

        if DownloadEngine.isCached(file) {
            url = DownloadEngine.cacheURL(for: file)
            return
        }

        do {
            let downloaded = try await DownloadEngine.download(object: file) { status, progress in
                Task { @MainActor in
                    self.downloadStatus = status
                    self.downloadProgress = progress
                }
            }
            withAnimation(.easeOut(duration: 0.3)) {
                url = downloaded
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
