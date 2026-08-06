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
            Color.black.opacity(0.96).ignoresSafeArea()

            VStack(spacing: 0) {
                // Header Bar
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(file.isFolder ? "Folder" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    Spacer()

                    // Fullscreen Toggle
                    Button {
                        NSApp.keyWindow?.toggleFullScreen(nil)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
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
                    }
                    .buttonStyle(.xGlass)

                    // Close Button
                    Button {
                        appState.theaterFile = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Close (ESC)")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Divider().overlay(.white.opacity(0.12))

                // Content View
                ZStack {
                    switch previewKind {
                    case .image:
                        imageViewer
                    case .video:
                        VideoPlaybackView(object: file)
                    default:
                        if let url {
                            VStack(spacing: 12) {
                                Image(systemName: "doc.fill")
                                    .font(.system(size: 48, weight: .light))
                                    .foregroundStyle(XTheme.textTertiary)
                                Text(file.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        } else {
                            ProgressView().tint(.white)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .task(id: file.id) {
            imageScale = 1.0
            lastScale = 1.0
            imageOffset = .zero
            lastOffset = .zero

            if DownloadEngine.isCached(file) {
                url = DownloadEngine.cacheURL(for: file)
            } else if let downloaded = try? await DownloadEngine.download(object: file, progress: { _, _ in }) {
                url = downloaded
            }
        }
    }

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
                        imageScale = 1.0
                        lastScale = 1.0
                        imageOffset = .zero
                        lastOffset = .zero
                    }
                }
                .padding(20)
        } else if url != nil {
            ProgressView()
                .tint(.white)
        } else {
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Loading high-res preview…")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func navigateMedia(delta: Int) {
        let mediaFiles = appState.files.filter { !$0.trashed && !$0.isFolder && $0.parentID == file.parentID }
        guard !mediaFiles.isEmpty, let currentIndex = mediaFiles.firstIndex(where: { $0.id == file.id }) else { return }
        let nextIndex = min(max(currentIndex + delta, 0), mediaFiles.count - 1)
        appState.theaterFile = mediaFiles[nextIndex]
    }
}
