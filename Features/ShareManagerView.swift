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
    @State private var selectedShareID: String? = nil
    @State private var columnCount = 2
    @State private var scrollTargetID: String? = nil
    @State private var showArchived = false

    /// Flat list in visual order (public section first, then private section) —
    /// the order arrow-key navigation walks, matching the grid layout.
    private var navigableShares: [ShareRecord] { publicShares + privateShares }

    private var active: [ShareRecord] {
        showArchived ? appState.archivedOutgoingShares : appState.activeOutgoingShares
    }
    private var privateShares: [ShareRecord] { active.filter { !$0.isPublic } }
    private var publicShares: [ShareRecord] { active.filter { $0.isPublic } }

    var body: some View {
        ZStack {
            if active.isEmpty {
                emptyStateView
            } else {
                GeometryReader { geo in
                    let cols = max(2, Int(geo.size.width / cardWidth))
                    ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showArchived.toggle()
                                    }
                                } label: {
                                    Text(showArchived ? "Active" : "Archived")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .frame(width: XTheme.topBarControlsWidth, height: 34)
                                        .contentShape(Capsule())
                                        .glassEffect(.regular.interactive(), in: .capsule)
                                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .help(showArchived ? "Show active shares" : "Show archived shares")

                                Spacer()

                                if !showArchived && appState.activeOutgoingShares.count > 1 {
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
                            }
                            .padding(.top, 16)
                            .padding(.leading, 24)
                            .padding(.trailing, 20)

                            if !publicShares.isEmpty {
                                sectionHeader("Public")
                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols),
                                    spacing: 12
                                ) {
                                    ForEach(publicShares) { share in
                                        ShareGridCard(share: share, isSelected: selectedShareID == share.id) {
                                            selectedShareID = share.id
                                        } onCancel: {
                                            cancelTarget = share
                                        }
                                        .id(share.id)
                                    }
                                }
                                .padding(.horizontal, 24)
                                .padding(.top, 8)
                            }

                            if !privateShares.isEmpty {
                                sectionHeader("Private")
                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols),
                                    spacing: 12
                                ) {
                                    ForEach(privateShares) { share in
                                        ShareGridCard(share: share, isSelected: selectedShareID == share.id) {
                                            selectedShareID = share.id
                                        } onCancel: {
                                            cancelTarget = share
                                        }
                                        .id(share.id)
                                    }
                                }
                                .padding(.horizontal, 24)
                                .padding(.top, 8)
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 80)
                    }
                    .onChange(of: geo.size.width, initial: true) {
                        columnCount = max(2, Int(geo.size.width / cardWidth))
                    }
                    .onChange(of: scrollTargetID) { _, newID in
                        guard let newID else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                    }
                }
                .background {
                    // Arrow keys + Return/Space drive the grid selection exactly
                    // like the file browser's grid (see FileBrowserKeyView).
                    ShareKeyMonitorView(
                        onArrow: { delta, isVertical in
                            navShare(delta, isVertical: isVertical)
                            return true
                        },
                        onOpen: {
                            openSelected()
                            return true
                        }
                    )
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

    /// Arrow-key grid navigation, matching the file browser: left/right move
    /// along the row, up/down move to the same column of the next/previous row.
    /// The flat navigable list is row-major over the grid columns, so the same
    /// math as the file grid applies (both sections share the column count).
    private func navShare(_ delta: Int, isVertical: Bool) {
        let shares = navigableShares
        guard !shares.isEmpty else { return }
        guard let current = shares.firstIndex(where: { $0.id == selectedShareID }) else {
            selectedShareID = shares[0].id
            scrollTargetID = shares[0].id
            return
        }
        let nextIndex: Int
        if isVertical {
            let target = current + (delta * columnCount)
            nextIndex = min(max(target, 0), shares.count - 1)
        } else {
            nextIndex = min(max(current + delta, 0), shares.count - 1)
        }
        selectedShareID = shares[nextIndex].id
        scrollTargetID = shares[nextIndex].id
    }

    /// Return key: reveals the selected share's file, same as double-click.
    private func openSelected() {
        guard let selectedShareID,
              let share = navigableShares.first(where: { $0.id == selectedShareID }) else { return }
        reveal(share)
    }

    /// Finder-style reveal: jumps to the shared file in All Files / Private
    /// Vault, selects it, and flashes its border. Group shares reveal the first
    /// member.
    private func reveal(_ share: ShareRecord) {
        let ids = !share.groupObjectIDs.isEmpty
            ? share.groupObjectIDs.split(separator: ",").map(String.init)
            : [share.objectID]
        guard let first = ids.first else { return }
        Task {
            guard let object = try? await DatabaseManager.shared.object(first) else { return }
            appState.revealObject(object)
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
            Image(systemName: showArchived ? "tray" : "arrow.triangle.swap")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(XTheme.brandGradient)

            Text(showArchived ? "No Archived Shares" : "No Active Shares")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)

            Text(showArchived
                ? "Archived shares are hidden from the main view but their links still work."
                : "Links you share appear here. Private links expire after a day and can be cancelled any time; public links never expire.")
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
    let isSelected: Bool
    let onSelect: () -> Void
    let onCancel: () -> Void

    @Environment(AppState.self) private var appState
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
                .fill(isSelected ? XTheme.accent.opacity(0.18)
                    : (hovering ? Color.white.opacity(0.08) : Color.white.opacity(0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? XTheme.accent : Color.white.opacity(0.06), lineWidth: isSelected ? 1.5 : 1)
        )
        .overlay(alignment: .topLeading) {
            // Kind button, top-left corner: same size and styling as the menu
            // button on the top-right. Orange shield-lock for private, green
            // unlocked lock for public.
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.55))
                Image(systemName: kindIcon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(kindColor)
            }
            .frame(width: 24, height: 24)
            .glassEffect(.regular.interactive(), in: .circle)
            .contentShape(Circle())
            .help(isPublic ? "Public share — never expires" : "Private share — expires, revocable")
            .padding(6)
        }
        .overlay(alignment: .topTrailing) {
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
            .help("Share options")
            .padding(6)
        }
        .contextMenu { shareMenuContent }
        .scaleEffect(hovering ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openSharedFile() }
        .simultaneousGesture(TapGesture(count: 1).onEnded { onSelect() })
        .help("Double-click to show the file")
        .task(id: share.id) { await loadThumbnail() }
    }

    /// Finder-style reveal: jumps to the shared file in All Files / Private
    /// Vault, selects it, and flashes its border. Group shares reveal the first
    /// member.
    private func openSharedFile() {
        let ids = isGroup ? share.groupObjectIDs.split(separator: ",").map(String.init) : [share.objectID]
        guard let first = ids.first else { return }
        Task {
            guard let object = try? await DatabaseManager.shared.object(first) else { return }
            appState.revealObject(object)
        }
    }

    @ViewBuilder
    private var shareMenuContent: some View {
        Button {
            copyLink()
        } label: {
            Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        Divider()
        if share.isArchived {
            Button {
                appState.unarchiveShare(share)
            } label: {
                Label("Unarchive", systemImage: "tray.and.arrow.up")
            }
        } else {
            Button {
                appState.archiveShare(share)
            } label: {
                Label("Archive", systemImage: "tray.and.arrow.down")
            }
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
// MARK: - Keyboard navigation

/// Window-scoped key monitor for the Shared page (same technique as the file
/// browser's FileBrowserKeyView): arrow keys move the grid selection, Return
/// reveals the selected share's file. Never steals keys while the user is
/// typing in a text field, and defers to other windows.
private struct ShareKeyMonitorView: NSViewRepresentable {
    var onArrow: (Int, Bool) -> Bool
    var onOpen: () -> Bool

    func makeNSView(context: Context) -> ShareKeyView {
        let view = ShareKeyView()
        apply(view)
        return view
    }

    func updateNSView(_ nsView: ShareKeyView, context: Context) {
        apply(nsView)
    }

    private func apply(_ view: ShareKeyView) {
        view.onArrow = onArrow
        view.onOpen = onOpen
    }
}

final class ShareKeyView: NSView {
    var onArrow: ((Int, Bool) -> Bool)?
    var onOpen: (() -> Bool)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window != nil else { return event }
                guard event.window === self.window else { return event }
                if let responder = self.window?.firstResponder,
                   responder is NSTextView || responder is NSTextField {
                    return event
                }
                let flags = event.modifierFlags
                let isCmd = flags.contains(.command)
                if isCmd { return event }

                switch event.keyCode {
                case 123: // left
                    if self.onArrow?(-1, false) == true { return nil }
                case 124: // right
                    if self.onArrow?(1, false) == true { return nil }
                case 125: // down
                    if self.onArrow?(1, true) == true { return nil }
                case 126: // up
                    if self.onArrow?(-1, true) == true { return nil }
                case 36, 49: // return, space — open like double-click
                    if self.onOpen?() == true { return nil }
                default:
                    break
                }
                return event
            }
        }
        if window == nil, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
