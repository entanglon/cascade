import SwiftUI

/// Review sheet for a staged share file: the chunks are already forwarded
/// into the recipient's own vault channel (streamable/previewable), but the
/// file is NOT in the catalog until the user picks Import. Cancel deletes the
/// forwarded copies from the vault channel — the file never shows in Cascade.
struct PendingImportView: View {
    @Environment(AppState.self) private var appState
    let object: ObjectRecord
    @State private var isResolving = false
    @State private var thumbImage: NSImage? = nil

    private var kindIcon: String {
        if object.isVideo { return "play.rectangle.fill" }
        if object.isAudio { return "music.note" }
        if object.isPhoto { return "photo.fill" }
        if object.isBook { return "book.closed.fill" }
        return "doc.fill"
    }

    private var kindName: String {
        if object.isVideo { return "Video" }
        if object.isAudio { return "Audio" }
        if object.isPhoto { return "Image" }
        if object.isBook { return "Book" }
        return "Document"
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: object.size, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Shared File")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    appState.discardPendingImport()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(6)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Discard — the copy is deleted from your cloud")
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Content
            VStack(spacing: 16) {
                ZStack {
                    if let thumbImage {
                        Image(nsImage: thumbImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 96, maxHeight: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                    } else {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 96, height: 96)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                            )
                            .overlay(
                                Image(systemName: kindIcon)
                                    .font(.system(size: 40))
                                    .foregroundStyle(XTheme.accent)
                            )
                            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 3)
                    }
                }
                .frame(width: 96, height: 96)

                Text(object.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)

                HStack(spacing: 14) {
                    Label(sizeText, systemImage: "internaldrive")
                    Text("•")
                        .foregroundStyle(.white.opacity(0.25))
                    Label(kindName, systemImage: "tag")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.8)
                        )
                )
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 12)

            Spacer(minLength: 0)

            // Footer / Actions
            HStack(spacing: 12) {
                Spacer()

                Button {
                    appState.discardPendingImport()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Deletes the copy from your cloud — it never shows in Cascade")

                Button {
                    isResolving = true
                    appState.confirmPendingImport()
                } label: {
                    HStack(spacing: 6) {
                        if isResolving {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        Text("Import")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(XTheme.accent)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    )
                    .shadow(color: XTheme.accent.opacity(0.35), radius: 8, x: 0, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(isResolving)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
        .frame(width: 440, height: 330)
        .background {
            ZStack {
                Color(red: 0.06, green: 0.08, blue: 0.12)
                Rectangle()
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.22),
                            Color.white.opacity(0.08),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .preferredColorScheme(.dark)
        .task {
            if let dir = try? UploadEngine.thumbnailsDirectory() {
                let candidates = ["\(object.id)-tg.jpg", "\(object.id)-tg.png", "\(object.id).png", "\(object.id)-up.jpg"]
                for c in candidates {
                    let u = dir.appendingPathComponent(c)
                    if let img = NSImage(contentsOf: u) {
                        thumbImage = img
                        break
                    }
                }
            }
            if thumbImage == nil {
                if let url = await ThumbnailService.shared.thumbnailURL(for: object),
                   let img = NSImage(contentsOf: url) {
                    thumbImage = img
                }
            }
        }
    }
}