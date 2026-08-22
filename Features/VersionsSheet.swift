import SwiftUI

/// Wave 2 item 8 — Version history for one file: every recorded past revision
/// (snapshotted when the Finder mirror replaced its content), newest first.
/// Replaced copies live in Trash with their channel bytes intact until the
/// user empties it, so recovery = open Trash and restore the old copy.
struct VersionsSheet: View {
    let file: ObjectRecord
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [ObjectVersionRecord] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.1))
            content
        }
        .frame(width: 480, height: 420)
        .background(AppBackground())
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .task {
            versions = (try? await DatabaseManager.shared.versions(for: file.id)) ?? []
            isLoading = false
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Version History")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(XTheme.textPrimary)
                Text(file.name)
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
            .help("Close")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 10) {
                ProgressView().controlSize(.large).tint(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if versions.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(XTheme.accent)
                Text("No previous versions")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Versions are recorded when a synced folder edit replaces this file's content.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(versions.reversed()) { version in
                        versionRow(version)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                        Text("Replaced copies rest in Trash (bytes intact) until it is emptied.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.top, 10)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
        }
    }

    private func versionRow(_ version: ObjectVersionRecord) -> some View {
        HStack(spacing: 12) {
            Text("v\(version.versionNumber)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(XTheme.accent)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(version.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                if let hash = version.rootHash, !hash.isEmpty {
                    Text("sha256 \(hash.prefix(12))…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: version.size, countStyle: .file))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}