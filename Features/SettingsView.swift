import SwiftUI
import AppKit

// MARK: - Vault storage breakdown (Apple-style "About This Mac" categories)

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
        case .other: return Color.white.opacity(0.30)
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
    @State private var showClearCacheConfirm = false
    @State private var showClearTdlibConfirm = false
    @State private var tdlibCacheSize: Int64?
    @State private var isExporting = false
    @State private var exportProgressText = ""
    @AppStorage("xc.audioPassthrough") private var audioPassthrough = false
    @AppStorage("xc.backupSendCopy") private var backupSendCopy = false
    @AppStorage(DownloadEngine.cacheCapKey) private var cacheCapGB = 5

    private var identity: TelegramClient.AccountIdentity? { appState.identity }
    private var tg: TelegramClient { TelegramClient.shared }

    private var stats: (files: Int, folders: Int, size: Int64) {
        let files = appState.files.filter { !$0.isFolder && !$0.trashed }
        let folders = appState.files.filter { $0.isFolder && !$0.trashed }
        let size = files.reduce(0) { $0 + $1.size }
        return (files.count, folders.count, size)
    }

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                header
                Divider().overlay(Color.white.opacity(0.1))

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        accountSection
                        syncSection
                        playbackSection
                        statsSection
                        storageSection
                        footer
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .padding(.bottom, 30)
                }
            }
        }
        .frame(width: 520, height: 660)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .confirmationDialog(
            "Clear local cache? This deletes downloaded previews and thumbnails. Your files in Telegram are safe.",
            isPresented: $showClearCacheConfirm, titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) { appState.clearLocalCache() }
        }
        .confirmationDialog(
            "Delete Telegram's download store (\(tdlibSizeLabel))? Anything you open later re-downloads from your channel.",
            isPresented: $showClearTdlibConfirm, titleVisibility: .visible
        ) {
            Button("Delete Telegram Cache", role: .destructive) {
                appState.clearTdlibFileCache()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { refreshTdlibSize() }
            }
        }
        .task { refreshTdlibSize() }
        .onReceive(NotificationCenter.default.publisher(for: .tdlibCacheChanged)) { _ in
            refreshTdlibSize()
        }
    }

    private var tdlibSizeLabel: String {
        tdlibCacheSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…"
    }

    private func refreshTdlibSize() {
        Task.detached(priority: .utility) {
            let size = await TelegramClient.shared.tdlibFilesSize()
            await MainActor.run { tdlibCacheSize = size }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Settings")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    // MARK: - Account

    private var accountSection: some View {
        HStack(spacing: 14) {
            ZStack {
                if let data = appState.profilePhotoData, let ns = NSImage(data: data) {
                    Image(nsImage: ns)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(Circle())
                } else {
                    Circle().fill(XTheme.brandGradient)
                    Text(initials)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)

                Text(accountLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var accountLine: String {
        guard let id = identity else { return "Telegram account" }
        if !id.username.isEmpty { return "@\(id.username)" }
        if !id.phone.isEmpty { return "+\(id.phone)" }
        return "Telegram account"
    }

    // MARK: - Cloud Sync

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Cloud Sync")
            settingsCard {
                settingsRow(title: "Last Synced", subtitle: "Catalog published to your vault") {
                    Text(lastSyncText)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                }
                settingsDivider
                settingsRow(title: "Sync Now", subtitle: "Rebuild the catalog from Telegram") {
                    Button {
                        Task { await appState.syncNow() }
                    } label: {
                        HStack(spacing: 5) {
                            if appState.isSyncing {
                                ProgressView().controlSize(.small)
                            }
                            Text(appState.isSyncing ? "Syncing…" : "Sync")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(XTheme.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isSyncing)
                    .help("Rebuild the catalog from the cloud and publish a fresh snapshot")
                }
                settingsDivider
                settingsRow(
                    title: "Independent Backup Copies",
                    subtitle: "Create true independent document clones in the backup channel instead of reference forwards (uses sendCopy)."
                ) {
                    Toggle("", isOn: $backupSendCopy)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(XTheme.accent)
                }
            }
        }
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

    // MARK: - Playback

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Playback")
            settingsCard {
                settingsRow(
                    title: "Audio Passthrough",
                    subtitle: "Bitstream Dolby/DTS to an HDMI receiver or soundbar instead of decoding to PCM. Requires compatible hardware; applies to new playback."
                ) {
                    Toggle("", isOn: $audioPassthrough)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(XTheme.accent)
                }
            }
        }
    }

    // MARK: - Vault Usage

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Vault Usage")
            settingsCard {
                VStack(spacing: 0) {
                    storageBar
                        .padding(.top, 14)
                        .padding(.bottom, 6)

                    ForEach(storageBreakdown) { item in
                        if item.bytes > 0 {
                            storageRow(item)
                        }
                    }

                    settingsDivider
                        .padding(.top, 6)

                    statRow("Files", value: "\(stats.files)")
                    settingsDivider
                    statRow("Folders", value: "\(stats.folders)")
                    settingsDivider
                    statRow("Cloud Storage Used", value: XTheme.formatBytes(stats.size))
                }
            }
        }
    }

    /// Apple-style stacked usage bar — each segment's width is that category's
    /// share of the total vault bytes.
    private var storageBar: some View {
        let items = storageBreakdown.filter { $0.bytes > 0 }
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.white.opacity(0.06))

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
        .frame(height: 8)
    }

    private func storageRow(_ item: StorageBreakdownItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.category.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(item.category.color)
                .frame(width: 18)
            Text(item.category.title)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
            Spacer()
            Text("\(XTheme.formatBytes(item.bytes)) · \(item.percentText)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.vertical, 8)
    }

    /// Matches the classification used by the sidebar smart folders and previews.
    private func category(of file: ObjectRecord) -> StorageCategory {
        let ext = (file.name as NSString).pathExtension.lowercased()
        if file.mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg"].contains(ext) { return .images }
        if file.mime.hasPrefix("video/") { return .videos }
        if file.mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "aac", "ogg"].contains(ext) { return .audio }
        if file.mime.contains("pdf") || file.mime.hasPrefix("text/") || file.mime.contains("msword") || file.mime.contains("officedocument") { return .documents }
        return .other
    }

    private var storageBreakdown: [StorageBreakdownItem] {
        var buckets: [StorageCategory: Int64] = [:]
        for file in appState.files where !file.isFolder && !file.trashed {
            buckets[category(of: file), default: 0] += max(0, file.size)
        }
        let total = stats.size
        return StorageCategory.allCases.map {
            StorageBreakdownItem(category: $0, bytes: buckets[$0] ?? 0, total: total)
        }
    }

    // MARK: - Local Storage

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Local Storage")
            settingsCard {
                settingsRow(title: "Cache Size", subtitle: "Downloads, staging files & thumbnails") {
                    Text(XTheme.formatBytes(appState.localCacheBytes))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                }
                if cacheCapGB > 0 {
                    cacheUsageBar
                }
                settingsDivider
                settingsRow(
                    title: "Cache Limit",
                    subtitle: "Oldest files also auto-evict when free disk space drops below \(XTheme.formatBytes(DownloadEngine.minFreeSpaceBytes))."
                ) {
                    Picker("", selection: $cacheCapGB) {
                        Text("2 GB").tag(2)
                        Text("5 GB").tag(5)
                        Text("10 GB").tag(10)
                        Text("20 GB").tag(20)
                        Text("No limit").tag(0)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: cacheCapGB) { _, _ in
                        DownloadEngine.enforceCacheBudget()
                    }
                }
                settingsDivider
                settingsRow(title: "Free Disk Space", subtitle: "Eviction floor") {
                    Text(freeSpaceText)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                }
                settingsDivider
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    panel.prompt = "Export"
                    panel.message = "Choose a destination folder to export your vault files"
                    if panel.runModal() == .OK, let url = panel.url {
                        isExporting = true
                        Task {
                            _ = try? await ExportEngine.shared.export(to: url) { prog in
                                Task { @MainActor in
                                    exportProgressText = "\(prog.completedFiles)/\(prog.totalFiles) files"
                                    isExporting = prog.isRunning
                                }
                            }
                            await MainActor.run { isExporting = false }
                        }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Export Vault to Local Folder")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                            Text("Download and decrypt all cloud files to a local directory")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        Spacer()
                        if isExporting {
                            ProgressView().controlSize(.small)
                            Text(exportProgressText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 13))
                                .foregroundStyle(XTheme.accent)
                        }
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isExporting)
                settingsDivider
                Button(role: .destructive) {
                    showClearCacheConfirm = true
                } label: {
                    HStack {
                        Text("Clear Local Cache")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.red.opacity(0.85))
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                settingsDivider
                Button(role: .destructive) {
                    showClearTdlibConfirm = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Delete Telegram Download Store")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.red.opacity(0.85))
                            Text("TDLib keeps every downloaded file here — currently \(tdlibSizeLabel). Your channel is unaffected; files re-download on demand.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Slim usage bar under the cache-size row — how full the cache is vs. the
    /// configured limit (hidden when the limit is "No limit").
    private var cacheUsageBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule()
                    .fill(XTheme.accent.opacity(0.6))
                    .frame(width: geo.size.width * min(1.0, cacheUsageRatio))
            }
        }
        .frame(height: 4)
        .padding(.bottom, 12)
    }

    private var cacheUsageRatio: Double {
        guard cacheCapGB > 0 else { return 0 }
        return Double(appState.localCacheBytes) / Double(cacheCapGB) / 1_000_000_000
    }

    private var freeSpaceText: String {
        guard let free = DownloadEngine.freeDiskSpaceBytes() else { return "—" }
        return "\(XTheme.formatBytes(free)) free"
    }

    // MARK: - Shared building blocks

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.35))
            .padding(.horizontal, 4)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 16)
            .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            )
    }

    /// Minimal settings cell: title + optional subtitle, trailing control, no icons.
    private func settingsRow(
        title: String,
        subtitle: String = "",
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            trailing()
        }
        .padding(.vertical, 10)
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.vertical, 10)
    }

    private var settingsDivider: some View {
        Divider().overlay(Color.white.opacity(0.06))
    }

    private var footer: some View {
        VStack(spacing: 2) {
            Text("Cascade")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
            Text(versionString)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return v.isEmpty ? "Telegram-powered cloud drive" : "Version \(v)"
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
}
