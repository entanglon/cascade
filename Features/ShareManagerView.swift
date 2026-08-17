import SwiftUI
import AppKit

/// The Shared page (v3): manages the share links this account handed OUT.
/// PRIVATE shares each live in a dedicated pool channel, expire, and are
/// revoked by deleting the channel; PUBLIC shares never expire and live in the
/// persistent public channel. Imports are no longer listed here — they show as
/// "Imports" cards on the Transfers page.
///
/// Cards are the same grid cards as All Files: thumbnail + name/size row, with
/// the kind marked by a small lock badge (orange lock = private, green unlocked
/// lock = public) on the card's corner and Copy Link / Cancel Share inside the
/// ellipsis menu and the right-click menu.
struct ShareManagerView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("xc.cardWidth") private var cardWidth = 200.0
    @State private var cancelTarget: ShareRecord? = nil
    @State private var showCancelAll = false

    private var active: [ShareRecord] { appState.activeOutgoingShares }
    private var privateShares: [ShareRecord] { active.filter { !$0.isPublic } }
    private var publicShares: [ShareRecord] { active.filter { $0.isPublic } }

    var body: some View {
        ZStack {
            if active.isEmpty {
                emptyStateView
            } else {
                GeometryReader { geo in
                    let cols = max(2, Int(geo.size.width / cardWidth))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if active.count > 1 {
                                HStack {
                                    Spacer()
                                    Button {
                                        showCancelAll = true
                                    } label: {
                                        Text("Cancel All")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.85))
                                            .frame(width: XTheme.topBarControlsWidth, height: 34)
                                            .contentShape(Capsule())
                                            .glassEffect(.regular.interactive(), in: .capsule)
                                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Revoke every share link")
                                }
                                .padding(.top, 16)
                                .padding(.leading, 24)
                                .padding(.trailing, 20)
                            }

                            if !publicShares.isEmpty {
                                sectionHeader("Public — never expires")
                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols),
                                    spacing: 12
                                ) {
                                    ForEach(publicShares) { share in
                                        ShareGridCard(share: share, onCancel: { cancelTarget = share })
                                    }
                                }
                                .padding(.horizontal, 24)
                                .padding(.top, 8)
                            }

                            if !privateShares.isEmpty {
                                sectionHeader("Private — expires, revocable")
                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols),
                                    spacing: 12
                                ) {
                                    ForEach(privateShares) { share in
                                        ShareGridCard(share: share, onCancel: { cancelTarget = share })
                                    }
                                }
                                .padding(.horizontal, 24)
                                .padding(.top, 8)
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 80)
                    }
                }
            }
        }
        .alert("Cancel This Share?", isPresented: Binding(
            get: { cancelTarget != nil },
            set: { if !$0 { cancelTarget = nil } }
        ), presenting: cancelTarget) { share in
            Button("Cancel Share", role: .destructive) {
                appState.cancelShare(share)
            }
            Button("Keep", role: .cancel) {}
        } message: { share in
            Text("The link stops working immediately. The file stays in your vault.")
        }
        .alert("Cancel All Shares?", isPresented: $showCancelAll) {
            Button("Cancel All", role: .destructive) {
                appState.cancelAllShares()
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Every share link stops working immediately. The files stay in your vault.")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(XTheme.brandGradient)

            Text("No Active Shares")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)

            Text("Links you share appear here. Private links expire after a week and can be cancelled any time; public links never expire.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(40)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A share card identical in shape to the All Files cards: thumbnail area on
/// top (the shared file's real thumbnail, or a generic icon), name + status
/// row beneath. The share kind sits on the card's top-trailing corner as a
/// small badge — orange lock for private, green unlocked lock for public —
/// next to the ellipsis menu (Copy Link / Cancel Share). Right-click offers
/// the same actions.
struct ShareGridCard: View {
    let share: ShareRecord
    let onCancel: () -> Void

    @State private var thumbURL: URL? = nil
    @State private var object: ObjectRecord? = nil
    @State private var copied = false
    @State private var hovering = false

    private var isGroup: Bool { !share.groupObjectIDs.isEmpty }
    private var isPublic: Bool { share.isPublic }
    private var kindColor: Color { isPublic ? .green : .orange }
    private var kindIcon: String { isPublic ? "lock.open.fill" : "lock.fill" }
    private var fileIcon: String {
        guard !isGroup else { return "folder" }
        let mime = object?.mime ?? ""
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("audio/") { return "music.note" }
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Color.white.opacity(0.03)

                    if let thumbURL, let ns = NSImage(contentsOf: thumbURL) {
                        Image(nsImage: ns)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    } else {
                        Image(systemName: fileIcon)
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(XTheme.textTertiary)
                    }
                }
                .clipped()
            }
            .frame(height: 115)
            .clipped()

            HStack(spacing: 8) {
                Image(systemName: fileIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(kindColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(XTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(expiryText)
                        .font(.system(size: 10))
                        .foregroundStyle(isPublic ? Color.green.opacity(0.9) : XTheme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.08) : Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                // Kind badge: small orange lock (private) / green unlocked lock (public).
                Image(systemName: kindIcon)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Circle().fill(kindColor))

                Menu {
                    shareMenuContent
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.55))
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 24, height: 24)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .contentShape(Circle())
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
            }
            .padding(6)
        }
        .contextMenu { shareMenuContent }
        .scaleEffect(hovering ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .task(id: share.id) { await loadThumbnail() }
    }

    @ViewBuilder
    private var shareMenuContent: some View {
        Button {
            copyLink()
        } label: {
            Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        Button(role: .destructive) {
            onCancel()
        } label: {
            Label("Cancel Share", systemImage: "xmark.circle.fill")
        }
    }

    private var displayName: String {
        if isGroup { return "\(share.groupObjectIDs.split(separator: ",").count) files" }
        return share.fileName
    }

    private var expiryText: String {
        if share.expiry == .distantFuture { return "Never expires" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Expires \(formatter.localizedString(for: share.expiry, relativeTo: .now))"
    }

    private func loadThumbnail() async {
        guard !isGroup,
              let object = try? await DatabaseManager.shared.object(share.objectID) else { return }
        self.object = object
        thumbURL = await ThumbnailService.shared.thumbnailURL(for: object)
    }

    private func copyLink() {
        let link = share.linkBlob ?? ""
        guard !link.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}