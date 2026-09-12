#if os(iOS)
import SwiftUI

// MARK: - Vault Storage Breakdown (Matching macOS "About This Mac" / Vault Usage)

private enum StorageCategory: String, CaseIterable, Identifiable {
    case images, videos, audio, documents, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .images: return "Images"
        case .videos: return "Videos"
        case .audio: return "Audio"
        case .documents: return "Documents"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .images: return "photo"
        case .videos: return "film"
        case .audio: return "music.note"
        case .documents: return "doc.text"
        case .other: return "shippingbox"
        }
    }

    var color: Color {
        switch self {
        case .images: return XTheme.categoryPink
        case .videos: return XTheme.categoryBlue
        case .audio: return XTheme.categoryPurple
        case .documents: return XTheme.categoryYellow
        case .other: return Color.white.opacity(0.35)
        }
    }
}

private struct StorageBreakdownItem: Identifiable {
    let category: StorageCategory
    let bytes: Int64
    let total: Int64

    var id: String { category.id }

    var fraction: Double {
        total <= 0 ? 0 : min(1, Double(bytes) / Double(total))
    }

    var percent: Int {
        Int((fraction * 100).rounded())
    }

    var percentText: String {
        if bytes > 0 && percent == 0 { return "<1%" }
        return "\(percent)%"
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var showClearCacheAlert = false
    @State private var showSignOutAlert = false
    @State private var cacheSize: Int64 = 0
    @State private var biometricEnabled: Bool = BiometricUnlock.isEnabled

    private var identity: TelegramClient.AccountIdentity? { appState.identity }

    private var stats: (files: Int, folders: Int, size: Int64) {
        let files = appState.allFiles.filter { !$0.isFolder && !$0.trashed }
        let folders = appState.allFiles.filter { $0.isFolder && !$0.trashed }
        let size = files.reduce(0) { $0 + $1.size }
        return (files.count, folders.count, size)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.05, green: 0.06, blue: 0.08).ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // MARK: - User Account Section
                        accountCard

                        // MARK: - Cloud Sync Section
                        cloudSyncCard

                        // MARK: - Private Vault & Security Section
                        securityCard

                        // MARK: - Vault Usage / Storage Breakdown Section
                        vaultUsageCard

                        // MARK: - Local Storage / Cache Section
                        localStorageCard

                        // MARK: - About Section
                        aboutCard

                        // MARK: - Sign Out Section
                        if appState.isAuthorized {
                            signOutCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 36)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(XTheme.accent)
                }
            }
            .task {
                updateCacheSize()
                await appState.fetchProfilePhotoIfNeeded()
            }
            .alert("Clear Local Cache?", isPresented: $showClearCacheAlert) {
                Button("Clear", role: .destructive) {
                    appState.clearLocalCache()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        updateCacheSize()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove downloaded files and cached thumbnails from your device. Your cloud files will not be affected.")
            }
            .alert("Sign Out?", isPresented: $showSignOutAlert) {
                Button("Sign Out", role: .destructive) {
                    appState.logout()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to sign out? You will need to log in again with Telegram to access your files.")
            }
        }
    }

    // MARK: - Section Components

    private var accountCard: some View {
        HStack(spacing: 16) {
            ZStack {
                if let photoData = appState.profilePhotoData,
                   let uiImage = UIImage(data: photoData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 58, height: 58)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(XTheme.brandGradient)
                        .frame(width: 58, height: 58)
                        .overlay {
                            Text(initials)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                        }
                }
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)

                Text(accountLine)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))

                HStack(spacing: 5) {
                    Circle()
                        .fill(appState.isAuthorized ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(appState.isAuthorized ? "Telegram Connected" : "Not Authorized")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(appState.isAuthorized ? Color.green : Color.orange)
                }
                .padding(.top, 2)
            }

            Spacer()
        }
        .padding(16)
        .frostedGlassCard(cornerRadius: 16)
    }

    private var cloudSyncCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("CLOUD SYNC")
            VStack(spacing: 0) {
                HStack {
                    Label("Last Synced", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.white)
                    Spacer()
                    Text(lastSyncText)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()
                    .background(Color.white.opacity(0.06))
                    .padding(.leading, 16)

                HStack {
                    Label("Sync Now", systemImage: "arrow.clockwise")
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        Task {
                            await appState.syncNow()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if appState.isSyncing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(appState.isSyncing ? "Syncing…" : "Sync")
                                .font(.subheadline.bold())
                                .foregroundStyle(XTheme.accent)
                        }
                    }
                    .disabled(appState.isSyncing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .frostedGlassCard(cornerRadius: 16)
        }
    }

    private var securityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("PRIVATE VAULT & SECURITY")
            VStack(spacing: 0) {
                HStack {
                    Label("Vault Status", systemImage: "lock.shield")
                        .foregroundStyle(.white)
                    Spacer()
                    if let error = appState.databaseError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.trailing)
                    } else if appState.isVaultConnected {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Connected")
                                .foregroundStyle(.green)
                        }
                    } else if appState.isAuthorized {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Setting up…")
                                .foregroundStyle(.orange)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text("Not Connected")
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()
                    .background(Color.white.opacity(0.06))
                    .padding(.leading, 16)

                HStack {
                    Label("Vault Key", systemImage: "key.fill")
                        .foregroundStyle(.white)
                    Spacer()
                    if appState.isVaultLocked {
                        Button("Unlock with PIN") {
                            appState.showVaultUnlockSheet = true
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(XTheme.accent)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.open.fill")
                                .foregroundStyle(.green)
                            Text("Unlocked")
                                .foregroundStyle(.green)
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if BiometricUnlock.isAvailable() {
                    Divider()
                        .background(Color.white.opacity(0.06))
                        .padding(.leading, 16)

                    Toggle(isOn: Binding(
                        get: { biometricEnabled },
                        set: { newValue in
                            biometricEnabled = newValue
                            BiometricUnlock.setEnabled(newValue)
                        }
                    )) {
                        Label(
                            "Unlock with \(BiometricUnlock.biometryName)",
                            systemImage: BiometricUnlock.biometryName == "Face ID" ? "faceid" : "touchid"
                        )
                        .foregroundStyle(.white)
                    }
                    .tint(XTheme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            .frostedGlassCard(cornerRadius: 16)
        }
    }

    private var vaultUsageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("VAULT USAGE")
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    storageBar

                    VStack(spacing: 8) {
                        ForEach(storageBreakdown) { item in
                            if item.bytes > 0 {
                                HStack(spacing: 8) {
                                    Image(systemName: item.category.icon)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(item.category.color)
                                        .frame(width: 20)
                                    Text(item.category.title)
                                        .font(.subheadline)
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Text("\(XTheme.formatBytes(item.bytes)) · \(item.percentText)")
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                            }
                        }
                    }
                }
                .padding(16)

                Divider()
                    .background(Color.white.opacity(0.06))
                    .padding(.leading, 16)

                HStack {
                    Label("Files", systemImage: "doc.fill")
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(stats.files)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()
                    .background(Color.white.opacity(0.06))
                    .padding(.leading, 16)

                HStack {
                    Label("Folders", systemImage: "folder.fill")
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(stats.folders)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()
                    .background(Color.white.opacity(0.06))
                    .padding(.leading, 16)

                HStack {
                    Label("Cloud Storage Used", systemImage: "icloud.fill")
                        .foregroundStyle(.white)
                    Spacer()
                    Text(XTheme.formatBytes(stats.size))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frostedGlassCard(cornerRadius: 16)
        }
    }

    private var localStorageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("LOCAL STORAGE")
            VStack(spacing: 0) {
                HStack {
                    Label("Cache Size", systemImage: "internaldrive")
                        .foregroundStyle(.white)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()
                    .background(Color.white.opacity(0.06))
                    .padding(.leading, 16)

                Button {
                    showClearCacheAlert = true
                } label: {
                    HStack {
                        Label("Clear Local Cache", systemImage: "trash")
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }
            .frostedGlassCard(cornerRadius: 16)
        }
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("ABOUT")
            HStack(spacing: 14) {
                Image("CascadeLogo")
                    .resizable()
                    .renderingMode(.original)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Cascade")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Version 1.0 (iOS)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Telegram-powered cloud drive")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                }

                Spacer()
            }
            .padding(16)
            .frostedGlassCard(cornerRadius: 16)
        }
    }

    private var signOutCard: some View {
        Button {
            showSignOutAlert = true
        } label: {
            HStack {
                Spacer()
                Text("Sign Out")
                    .fontWeight(.semibold)
                    .foregroundStyle(.red)
                Spacer()
            }
            .padding(.vertical, 14)
            .frostedGlassCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.white.opacity(0.40))
            .tracking(0.6)
            .padding(.horizontal, 4)
    }

    private func updateCacheSize() {
        cacheSize = appState.calculateCacheSize()
    }

    private var displayName: String {
        guard let id = identity else { return "Telegram User" }
        let full = "\(id.firstName) \(id.lastName)".trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? "Telegram User" : full
    }

    private var initials: String {
        let parts = displayName.split(separator: " ")
        let s = parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return s.isEmpty ? "T" : s
    }

    private var accountLine: String {
        guard let id = identity else { return "Telegram account" }
        if !id.username.isEmpty { return "@\(id.username)" }
        if !id.phone.isEmpty { return "+\(id.phone)" }
        return "Telegram account"
    }

    private var lastSyncText: String {
        guard let date = appState.lastSyncDate else { return "Never synced" }
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "Just now" }
        if elapsed < 3600 {
            let m = Int(elapsed / 60)
            return "\(m)m ago"
        }
        if elapsed < 86400 {
            let h = Int(elapsed / 3600)
            return "\(h)h ago"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func category(of file: FileItem) -> StorageCategory {
        let ext = (file.name as NSString).pathExtension.lowercased()
        if file.isImage { return .images }
        if file.isVideo { return .videos }
        if file.isAudio { return .audio }
        if file.isDocument || file.isBook || file.isBookFile { return .documents }
        return .other
    }

    private var storageBreakdown: [StorageBreakdownItem] {
        var buckets: [StorageCategory: Int64] = [:]
        for file in appState.allFiles where !file.isFolder && !file.trashed {
            buckets[category(of: file), default: 0] += max(0, file.size)
        }
        let total = stats.size
        return StorageCategory.allCases.map {
            StorageBreakdownItem(category: $0, bytes: buckets[$0] ?? 0, total: total)
        }
    }

    private var storageBar: some View {
        let items = storageBreakdown.filter { $0.bytes > 0 }
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.08))

            if stats.size > 0 {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { _, item in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(item.category.color)
                                .frame(width: max(2, geo.size.width * item.fraction - 2))
                        }
                    }
                }
            }
        }
        .frame(height: 10)
    }
}
#endif
