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
    // Wave 2 item 9 — activity sheet + password protection control.
    @State private var activityTarget: ShareRecord? = nil
    @State private var passwordTarget: ShareRecord? = nil
    @State private var newPassword = ""

    /// Flat list in visual order (public section first, then private section) —
    /// the order arrow-key navigation walks, matching the grid layout.
    private var navigableShares: [ShareRecord] { publicShares + privateShares }

    private var active: [ShareRecord] {
        showArchived ? appState.archivedOutgoingShares : appState.activeOutgoingShares
    }
    private var privateShares: [ShareRecord] { active.filter { !$0.isPublic } }
    private var publicShares: [ShareRecord] { active.filter { $0.isPublic } }

    var body: some View {
        VStack(spacing: 0) {
            // Toggle + Cancel All header — always visible regardless of share count
            HStack {
                Spacer()

                if !showArchived && appState.activeOutgoingShares.count > 1 {
                    Button {
                        showCancelAll = true
                    } label: {
                        Label("Cancel All", systemImage: "xmark.circle")
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

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showArchived.toggle()
                    }
                } label: {
                    Label(showArchived ? "Active" : "Archived", systemImage: showArchived ? "arrow.left" : "tray")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: XTheme.topBarControlsWidth, height: 34)
                        .contentShape(Capsule())
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(showArchived ? "Show active shares" : "Show archived shares")
            }
            .padding(.top, 16)
            .padding(.leading, 24)
            .padding(.trailing, 20)

            if active.isEmpty {
                emptyStateView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    let cols = max(2, Int(geo.size.width / cardWidth))
                    ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if !publicShares.isEmpty {
                                sectionHeader("Public")
                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: cols),
                                    spacing: 28
                                ) {
                                    ForEach(publicShares) { share in
                                        ShareGridCard(share: share, isSelected: selectedShareID == share.id) {
                                            selectedShareID = share.id
                                        } onCancel: {
                                            cancelTarget = share
                                        } onActivity: {
                                            activityTarget = share
                                        } onAddPassword: {
                                            newPassword = ""
                                            passwordTarget = share
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
                                    columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: cols),
                                    spacing: 28
                                ) {
                                    ForEach(privateShares) { share in
                                        ShareGridCard(share: share, isSelected: selectedShareID == share.id) {
                                            selectedShareID = share.id
                                        } onCancel: {
                                            cancelTarget = share
                                        } onActivity: {
                                            activityTarget = share
                                        } onAddPassword: {
                                            newPassword = ""
                                            passwordTarget = share
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
        // Wave 2 item 9 — importer visibility / activity log per share.
        .sheet(isPresented: Binding(
            get: { activityTarget != nil },
            set: { if !$0 { activityTarget = nil } }
        )) {
            if let target = activityTarget {
                ShareActivitySheet(share: target)
                    .environment(appState)
            }
        }
        // Re-share control: protect an unprotected private link with a password.
        // Re-mints the blob (same channel/messages/expiry); old link dies.
        .alert("Add Password", isPresented: Binding(
            get: { passwordTarget != nil },
            set: { if !$0 { passwordTarget = nil } }
        ), presenting: passwordTarget) { share in
            TextField("Password", text: $newPassword)
            Button("Protect & Copy New Link") {
                Task { await addPassword(to: share) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The link is re-minted with this password. The previous link stops working immediately; the new one is copied to your clipboard.")
        }
    }

    @MainActor
    private func addPassword(to share: ShareRecord) async {
        guard !newPassword.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            let newLink = try await ShareEngine.addPasswordToShare(share, password: newPassword)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(newLink, forType: .string)
            appState.notify(title: "Password set — new link copied", kind: .success, duration: 5.0)
        } catch {
            appState.notify(title: "Couldn't add password", message: error.localizedDescription, kind: .error, duration: 6.0)
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
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.40))
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

/// A share glass card: thumbnail zone on top (aspect-fit thumb, vector folder
/// for group shares, glyph otherwise), name + expiry block beneath. The kind
/// reads as a small lock badge top-trailing (orange = private, green =
/// public) — status, not a button. No hover effects, no menu button
/// (right-click covers it), glass selection border like the transfer cards.
struct ShareGridCard: View {
    let share: ShareRecord
    let isSelected: Bool
    let onSelect: () -> Void
    let onCancel: () -> Void
    var onActivity: () -> Void = {}
    var onAddPassword: () -> Void = {}

    @Environment(AppState.self) private var appState
    @State private var thumbURL: URL? = nil
    @State private var object: ObjectRecord? = nil
    @State private var copied = false
    /// Wave 2 item 9 — observed imports (join events) for this share.
    @State private var importCount = 0

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
        VStack(spacing: 0) {
            ZStack {
                if isGroup {
                    AppleFolderIcon(width: 84, height: 66)
                        .shadow(color: .black.opacity(0.15), radius: 2.5, x: 0, y: 1.5)
                } else if let thumbURL, let ns = NSImage(contentsOf: thumbURL) {
                    Image(nsImage: ns)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 2.5, x: 0, y: 1.5)
                } else {
                    Image(systemName: fileIcon)
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(XTheme.textTertiary)
                }
            }
            .frame(height: 115)
            .clipped()

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(XTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 5) {
                        Text(expiryText)
                            .foregroundStyle(isPublic ? Color.green.opacity(0.9) : XTheme.textTertiary)
                        if importCount > 0 {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(XTheme.accent)
                                .help("\(importCount) import\(importCount == 1 ? "" : "s") — see Activity")
                        }
                    }
                    .font(.system(size: 11))
                    .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? XTheme.accent : Color.white.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
        )
        .overlay(alignment: .topTrailing) {
            Image(systemName: kindIcon)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(4)
                .background(Circle().fill(kindColor))
                .padding(6)
                .help(isPublic ? "Public share — never expires" : "Private share — expires, revocable")
        }
        .contentShape(Rectangle())
        .contextMenu { shareMenuContent }
        .onTapGesture(count: 2) { openSharedFile() }
        .simultaneousGesture(TapGesture(count: 1).onEnded { onSelect() })
        .help("Double-click to show the file")
        .task(id: share.id) {
            await loadThumbnail()
            await loadImportCount()
        }
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
        // Wave 2 item 9 — importer visibility / activity timeline.
        Button {
            onActivity()
        } label: {
            Label("Activity…", systemImage: "list.bullet.rectangle")
        }
        // Re-share control: password-protect an unprotected private link.
        if !share.isPublic && share.state == "active" && share.groupObjectIDs.isEmpty && !share.shareKey.isEmpty {
            Button {
                onAddPassword()
            } label: {
                Label("Add Password…", systemImage: "lock.badge.clock")
            }
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

    private func loadImportCount() async {
        let events = (try? await DatabaseManager.shared.shareActivity(
            shareID: share.id, channelID: share.channelID
        )) ?? []
        importCount = events.filter { $0.kind == "join" }.count
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

// MARK: - Activity sheet (Wave 2 item 9)

/// Timeline of observed events for one share: creation, importer joins
/// (private links attribute the Telegram user; public links are channel-level
/// since every public link shares one channel), password additions, revocations.
private struct ShareActivitySheet: View {
    let share: ShareRecord
    @Environment(\.dismiss) private var dismiss
    @State private var events: [ShareActivityRecord] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share Activity")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(XTheme.textPrimary)
                    Text(share.fileName)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            Divider().overlay(Color.white.opacity(0.1))

            if isLoading {
                ProgressView().controlSize(.large).tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if events.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(XTheme.accent)
                    Text("No activity yet")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Imports appear here when a recipient opens the link and joins the share channel.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(events) { event in
                            eventRow(event)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
        }
        .frame(width: 480, height: 440)
        .background(AppBackground())
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .task {
            events = (try? await DatabaseManager.shared.shareActivity(
                shareID: share.id, channelID: share.channelID
            )) ?? []
            isLoading = false
        }
    }

    private func eventRow(_ event: ShareActivityRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Self.icon(for: event.kind))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Self.color(for: event.kind))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(for: event))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                if let uid = event.userID {
                    Text("Telegram user \(uid)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            Spacer()
            Text(event.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private static func icon(for kind: String) -> String {
        switch kind {
        case "join": return "person.crop.circle.badge.plus"
        case "created": return "link"
        case "revoked": return "xmark.circle"
        case "expired": return "clock.badge.xmark"
        case "password_added": return "lock.fill"
        default: return "circle.dashed"
        }
    }

    private static func color(for kind: String) -> Color {
        switch kind {
        case "join": return XTheme.accent
        case "created": return .green
        case "revoked", "expired": return .orange
        case "password_added": return .yellow
        default: return .gray
        }
    }

    private static func title(for event: ShareActivityRecord) -> String {
        if !event.detail.isEmpty { return event.detail }
        return event.kind
    }
}
