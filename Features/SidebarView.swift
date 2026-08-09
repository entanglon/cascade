import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarDestination
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: XTheme.spaceXS) {
                    Text("Library")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.40))
                        .textCase(.uppercase)
                        .padding(.horizontal, 14)
                        .padding(.top, 40)
                        .padding(.bottom, 4)

                    VStack(spacing: 4) {
                        ForEach(SidebarDestination.allCases) { item in
                            SidebarRow(
                                item: item,
                                isSelected: selection == item
                            ) {
                                selection = item
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
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
}

struct SidebarRow: View {
    @Environment(AppState.self) private var appState
    let item: SidebarDestination
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : XTheme.accent)
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
                .fill(isSelected ? XTheme.accent.opacity(0.22) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? XTheme.accent.opacity(0.4) : .clear, lineWidth: 1)
        )
    }

    private var badgeColor: Color {
        isSelected ? XTheme.accent : Color.white.opacity(0.6)
    }

    private var categoryCount: Int {
        let files = appState.files
        switch item {
        case .allFiles:
            return files.filter { !$0.trashed && !$0.isPrivate && $0.parentID == nil }.count
        case .privateVault:
            return files.filter { !$0.trashed && $0.isPrivate }.count
        case .recent:
            return files.filter { !$0.trashed && !$0.isFolder }.count
        case .favorites:
            return files.filter { $0.isFavorite && !$0.trashed }.count
        case .video:
            return files.filter { !$0.trashed && !$0.isFolder && $0.mime.hasPrefix("video/") }.count
        case .audio:
            return files.filter { !$0.trashed && !$0.isFolder && $0.mime.hasPrefix("audio/") }.count
        case .documents:
            return files.filter { !$0.trashed && !$0.isFolder &&
                ($0.mime.contains("pdf") || $0.mime.hasPrefix("text/") ||
                 $0.mime.contains("msword") || $0.mime.contains("officedocument")) }.count
        case .transfers:
            return TransferCenter.shared.items.filter { $0.state == .active }.count
        case .trash:
            return files.filter { $0.trashed }.count
        }
    }
}

struct SidebarProfileCard: View {
    @Environment(AppState.self) private var appState
    private var tg: TelegramClient { TelegramClient.shared }
    @State private var showLogoutConfirm = false
    @State private var cardHovered = false

    private var totalVaultBytes: Int64 {
        appState.files.filter { !$0.isFolder && !$0.trashed }.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 10) {
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

            if tg.isAuthorized {
                HStack {
                    Text("Vault Storage")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: totalVaultBytes, countStyle: .file))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(XTheme.accent)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
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

            ZStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.8), radius: 4, x: 0, y: 0)
            }
        }
        .padding(10)
        .glassEffect(cardHovered ? .regular.interactive() : .regular, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(cardHovered ? XTheme.accent.opacity(0.5) : Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: cardHovered ? XTheme.accent.opacity(0.25) : .clear, radius: 8, y: 0)
        .scaleEffect(cardHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: cardHovered)
        .onHover { cardHovered = $0 }
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
                .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        } else {
            ZStack {
                Circle().fill(XTheme.brandGradient)
                Text(initials)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
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
