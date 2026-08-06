import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var showClearCacheConfirm = false

    private var identity: TelegramClient.AccountIdentity? { appState.identity }

    private var stats: (files: Int, folders: Int, size: Int64) {
        let files = appState.files.filter { !$0.isFolder }
        let folders = appState.files.filter { $0.isFolder }
        let size = files.reduce(0) { $0 + $1.size }
        return (files.count, folders.count, size)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.1))

            ScrollView {
                VStack(spacing: 24) {
                    accountSection
                    statsSection
                    storageSection
                }
                .padding(24)
            }
        }
        .frame(width: 480, height: 540)
        .glassEffect(.regular, in: .rect(cornerRadius: 30, style: .continuous))
        .confirmationDialog(
            "Clear local cache? This deletes downloaded previews and thumbnails. Your files in Telegram are safe.",
            isPresented: $showClearCacheConfirm, titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) { appState.clearLocalCache() }
        }
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
    }

    private var accountSection: some View {
        SettingsGroup(title: "Account") {
            HStack(spacing: 14) {
                if let data = appState.profilePhotoData, let ns = NSImage(data: data) {
                    Image(nsImage: ns).resizable().scaledToFill()
                        .frame(width: 48, height: 48).clipShape(Circle())
                } else {
                    Circle().fill(.white.opacity(0.1)).frame(width: 48, height: 48)
                        .overlay(Text("T").font(.system(size: 18, weight: .bold)).foregroundStyle(.white.opacity(0.6)))
                }

                VStack(alignment: .leading, spacing: 2) {
                    if let id = identity {
                        Text("\(id.firstName) \(id.lastName)".trimmingCharacters(in: .whitespaces))
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        if !id.phone.isEmpty {
                            Text("+\(id.phone)").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                        }
                    } else {
                        Text("Telegram User").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                Spacer()
            }
        }
    }

    private var statsSection: some View {
        SettingsGroup(title: "Vault Statistics") {
            VStack(spacing: 12) {
                statRow("Total Files", value: "\(stats.files)")
                statRow("Total Folders", value: "\(stats.folders)")
                statRow("Total Storage Used", value: ByteCountFormatter.string(fromByteCount: stats.size, countStyle: .file))
            }
        }
    }

    private var storageSection: some View {
        SettingsGroup(title: "Local Storage") {
            Button(role: .destructive) {
                showClearCacheConfirm = true
            } label: {
                HStack {
                    Image(systemName: "trash.circle")
                    Text("Clear Local Cache")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.9))
        }
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(value).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(.white)
        }
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 4)

            VStack(spacing: 16) {
                content
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
        }
    }
}
