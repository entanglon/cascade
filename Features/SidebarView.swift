import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Binding var selection: SidebarDestination
    @Environment(AppState.self) private var appState

    /// Pinned folders, resolved to live records (deleted/trashed pins vanish).
    private var pinnedFolders: [ObjectRecord] { appState.pinnedSidebarFolders }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Top-level entries sit headerless (Finder-style); only
                    // genuine groups get headings.
                    VStack(spacing: 4) {
                        ForEach(SidebarDestination.topLevelItems) { item in
                            SidebarRow(
                                item: item,
                                isSelected: selection == item
                            ) {
                                appState.isSidebarFocused = true
                                selection = item
                            }
                        }
                    }
                    sidebarSection(title: "Collections", items: SidebarDestination.collectionItems)
                    sidebarSection(title: "Utilities", items: SidebarDestination.vaultItems)
                    if !pinnedFolders.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            sectionHeader("Pinned")
                            VStack(spacing: 4) {
                                ForEach(pinnedFolders) { folder in
                                    PinnedFolderRow(folder: folder)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, appState.isWindowFullScreen ? 14 : 40)
            }
            .safeAreaInset(edge: .bottom) {
                SidebarProfileCard()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .ignoresSafeArea(.all, edges: .top)
    }

    private func sidebarSection(title: String, items: [SidebarDestination]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader(title)
            VStack(spacing: 4) {
                ForEach(items) { item in
                    SidebarRow(
                        item: item,
                        isSelected: selection == item
                    ) {
                        appState.isSidebarFocused = true
                        selection = item
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(0.40))
            .textCase(.uppercase)
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
    }
}

/// A user-pinned folder under the sidebar's Pinned heading. Selected when the
/// browser shows that exact folder; activates via openSidebarPin (vault pins
/// honor the PIN gate through the Private Vault destination).
struct PinnedFolderRow: View {
    @Environment(AppState.self) private var appState
    let folder: ObjectRecord

    private var isSelected: Bool {
        appState.currentFolderID == folder.id
            && appState.selectedDestination == (folder.isPrivate ? .privateVault : .allFiles)
    }

    var body: some View {
        Button {
            appState.isSidebarFocused = true
            appState.openSidebarPin(folder)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : XTheme.accent)
                    .frame(width: 20, alignment: .center)

                Text(folder.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.85))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if folder.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? XTheme.accent.opacity(0.22) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? XTheme.accent.opacity(0.4) : .clear, lineWidth: 1)
        )
        .contextMenu {
            Button {
                appState.toggleSidebarPin(folder)
            } label: {
                Label("Unpin from Sidebar", systemImage: "sidebar.left.slash")
            }
        }
    }
}

struct SidebarRow: View {
    @Environment(AppState.self) private var appState
    let item: SidebarDestination
    let isSelected: Bool
    let action: () -> Void
    @State private var isTargeted = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isTargeted && item == .trash ? .red : (isSelected ? .white : XTheme.accent))
                    .frame(width: 20, alignment: .center)

                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.85))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isTargeted && item == .trash ? Color.red.opacity(0.25) : (isSelected ? XTheme.accent.opacity(0.22) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isTargeted && item == .trash ? Color.red.opacity(0.8) : (isSelected ? XTheme.accent.opacity(0.4) : .clear), lineWidth: 1)
        )
        .onDrop(of: [.text, .plainText, .item], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let dest = item
        guard dest == .trash || dest == .favorites else { return false }
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let str = object as? String else { return }
                let ids = str.split(separator: "\n").map(String.init)
                guard !ids.isEmpty else { return }
                Task { @MainActor in
                    for id in ids {
                        if let file = appState.files.first(where: { $0.id == id }) {
                            if dest == .trash {
                                appState.setTrashed(file, true)
                            } else if dest == .favorites && !file.isFavorite {
                                appState.toggleFavorite(file)
                            }
                        }
                    }
                }
            }
            handled = true
        }
        return handled
    }

    private var badgeColor: Color {
        isSelected ? XTheme.accent : Color.white.opacity(0.6)
    }

    private var categoryCount: Int {
        let files = appState.files.filter { !$0.isArchived }
        switch item {
        case .allFiles:
            return files.filter { !$0.trashed && !$0.isPrivate && $0.parentID == nil }.count
        case .privateVault:
            return files.filter { !$0.trashed && $0.isPrivate }.count
        case .recent:
            return files.filter { !$0.trashed && !$0.isFolder }.count
        case .favorites:
            return files.filter { $0.isFavorite && !$0.trashed }.count
        case .photos:
            return files.filter { f in
                guard !f.trashed && !f.isFolder else { return false }
                if f.mime.hasPrefix("image/") { return true }
                let ext = (f.name as NSString).pathExtension.lowercased()
                return ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg"].contains(ext)
            }.count
        case .video:
            return files.filter { !$0.trashed && !$0.isFolder && (
                $0.mime.hasPrefix("video/") || ["mp4", "mov", "m4v", "mkv", "avi", "webm", "3gp", "mpg", "mpeg"].contains(($0.name as NSString).pathExtension.lowercased())
            ) }.count
        case .audio:
            return files.filter { !$0.trashed && !$0.isFolder && (
                $0.mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "aac", "ogg"].contains(($0.name as NSString).pathExtension.lowercased())
            ) }.count
        case .documents:
            return files.filter { f in
                guard !f.trashed && !f.isFolder else { return false }
                return f.mime.contains("pdf") || f.mime.hasPrefix("text/") || f.mime.contains("msword") || f.mime.contains("officedocument")
            }.count
        case .library:
            return files.filter { !$0.trashed && $0.isBook }.count
        case .transfers:
            return TransferCenter.shared.items.filter { $0.state == .active }.count
        case .shared:
            // The Shared page manages outgoing share links — badge the live ones.
            return appState.activeOutgoingShares.count
        case .archive:
            return appState.files.filter { $0.isArchived }.count
        case .trash:
            return appState.files.filter { $0.trashed }.count
        }
    }
}

struct SidebarProfileCard: View {
    @Environment(AppState.self) private var appState
    private var tg: TelegramClient { TelegramClient.shared }
    @State private var showLogoutConfirm = false

    var body: some View {
        // Vault size lives in Settings → Storage Dashboard (Wave 2 item 6).
        Group {
            if tg.isAuthorized {
                Menu {
                    Button {
                        appState.showSettings = true
                    } label: {
                        Label("Settings...", systemImage: "gearshape")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    cardContent
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
            } else {
                Button {
                    tg.isConnected ? (appState.showLogin = true) : (appState.showSetup = true)
                } label: {
                    cardContent
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .confirmationDialog(
            "Log out of Telegram? Your local index stays, but uploads/downloads stop until you sign back in.",
            isPresented: $showLogoutConfirm, titleVisibility: .visible
        ) {
            Button("Log Out", role: .destructive) {
                Task { await appState.logout() }
            }
        }
    }

    private var cardContent: some View {
        HStack(spacing: 10) {
            avatar

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer()

            // Sync status lives at the card's trailing edge, away from the name.
            if appState.isSyncing {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(XTheme.accent)
                    .help("Syncing catalog…")
            } else if appState.lastSyncDate != nil {
                Image(systemName: "checkmark.icloud.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green.opacity(0.8))
                    .help("Synced with cloud")
            }
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .contentShape(.rect(cornerRadius: 16))
    }

    @ViewBuilder
    private var avatar: some View {
        if let data = appState.profilePhotoData, let ns = NSImage(data: data) {
            Image(nsImage: ns)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(XTheme.brandGradient)
                Text(initials)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
        }
    }

    private var displayName: String {
        guard let id = appState.identity else { return "Telegram Vault" }
        let full = "\(id.firstName) \(id.lastName)".trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? "Telegram Vault" : full
    }

    private var subtitle: String {
        if tg.isAuthorized {
            if let u = appState.identity, !u.username.isEmpty { return "@\(u.username)" }
            return "Connected"
        }
        if tg.isConnected { return "Awaiting auth" }
        return "Not connected"
    }

    private var initials: String {
        let parts = displayName.split(separator: " ")
        let s = parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return s.isEmpty ? "X" : s
    }

    private var statusColor: Color {
        if tg.isAuthorized { return .green }
        if tg.isConnected { return .orange }
        return .orange
    }
}
