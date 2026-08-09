import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var showClearCacheConfirm = false

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
                    VStack(spacing: 20) {
                        accountSection
                        statsSection
                        storageSection
                    }
                    .padding(24)
                }
            }
        }
        .frame(width: 520, height: 580)
        .glassEffect(.regular, in: .rect(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .confirmationDialog(
            "Clear local cache? This deletes downloaded previews and thumbnails. Your files in Telegram are safe.",
            isPresented: $showClearCacheConfirm, titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) { appState.clearLocalCache() }
        }
    }

    private var header: some View {
        HStack {
            Text("Settings & Account")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var accountSection: some View {
        SettingsGroup(title: "Account Profile") {
            HStack(spacing: 16) {
                if let data = appState.profilePhotoData, let ns = NSImage(data: data) {
                    Image(nsImage: ns)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(XTheme.brandGradient, lineWidth: 2))
                        .shadow(color: XTheme.accent.opacity(0.4), radius: 8)
                } else {
                    ZStack {
                        Circle().fill(XTheme.brandGradient)
                        Text(initials)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 56, height: 56)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1.5))
                    .shadow(color: XTheme.accent.opacity(0.3), radius: 8)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(displayName)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)

                        HStack(spacing: 4) {
                            Circle()
                                .fill(tg.isAuthorized ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                            Text(tg.isAuthorized ? "Active" : "Offline")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(tg.isAuthorized ? Color.green : Color.orange)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill((tg.isAuthorized ? Color.green : Color.orange).opacity(0.15))
                        )
                        .overlay(
                            Capsule().strokeBorder((tg.isAuthorized ? Color.green : Color.orange).opacity(0.3), lineWidth: 1)
                        )
                    }

                    if let id = identity, !id.phone.isEmpty {
                        Text("+\(id.phone)")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }

                    if let id = identity, !id.username.isEmpty {
                        Text("@\(id.username)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(XTheme.accent)
                    }
                }
                Spacer()
            }
        }
    }

    private var statsSection: some View {
        SettingsGroup(title: "Vault Statistics") {
            VStack(spacing: 12) {
                statRow("Total Vault Files", value: "\(stats.files)")
                Divider().overlay(Color.white.opacity(0.06))
                statRow("Total Folders", value: "\(stats.folders)")
                Divider().overlay(Color.white.opacity(0.06))
                statRow("Cloud Storage Used", value: ByteCountFormatter.string(fromByteCount: stats.size, countStyle: .file))
            }
        }
    }

    private var storageSection: some View {
        SettingsGroup(title: "Local Storage & Cache") {
            VStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local Cache Size")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                        Text("Previews, audio waveforms & thumbnails cached on disk")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: appState.localCacheBytes, countStyle: .file))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(XTheme.accent)
                }

                Button(role: .destructive) {
                    showClearCacheConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "trash.circle.fill")
                            .font(.system(size: 15))
                        Text("Clear Local Cache")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.12)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red.opacity(0.25), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.95))
            }
        }
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
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

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(XTheme.textTertiary)
                .padding(.horizontal, 4)

            VStack(spacing: 14) {
                content
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
        }
    }
}
