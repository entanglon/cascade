import SwiftUI
import AppKit

/// The Shared page (v3): manages the share links this account handed OUT.
/// PRIVATE shares each live in a dedicated pool channel, expire, and are
/// revoked by deleting the channel; PUBLIC shares never expire and live in the
/// persistent public channel. Imports are no longer listed here — they show as
/// "Imports" cards on the Transfers page.
struct ShareManagerView: View {
    @Environment(AppState.self) private var appState
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if active.count > 1 {
                            HStack {
                                Spacer()
                                Button {
                                    showCancelAll = true
                                } label: {
                                    Label("Cancel All Shares", systemImage: "xmark.circle.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .frame(width: XTheme.topBarControlsWidth, height: 34)
                                        .contentShape(Capsule())
                                        .glassEffect(.regular.interactive(), in: .capsule)
                                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.top, 16)
                            .padding(.leading, 24)
                            .padding(.trailing, 20)
                        }

                        if !publicShares.isEmpty {
                            sectionHeader("Public — never expires")
                            ForEach(publicShares) { share in
                                ShareRowCard(share: share, onCancel: { cancelTarget = share })
                            }
                            .padding(.horizontal, 24)
                        }

                        if !privateShares.isEmpty {
                            sectionHeader("Private — expires, revocable")
                            ForEach(privateShares) { share in
                                ShareRowCard(share: share, onCancel: { cancelTarget = share })
                            }
                            .padding(.horizontal, 24)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 80)
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
            Button("Keep Share", role: .cancel) {}
        } message: { share in
            Text("The link stops working immediately. The file stays in your vault.")
        }
        .alert("Cancel All Shares?", isPresented: $showCancelAll) {
            Button("Cancel All", role: .destructive) {
                appState.cancelAllShares()
            }
            Button("Keep Shares", role: .cancel) {}
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

/// One outgoing share card: name (or "N files" for a group), share kind, expiry,
/// Copy Link, and Cancel.
struct ShareRowCard: View {
    let share: ShareRecord
    let onCancel: () -> Void
    @State private var copied = false

    private var isGroup: Bool { !share.groupObjectIDs.isEmpty }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(share.isPublic ? Color.green.opacity(0.16) : Color.orange.opacity(0.16))
                    .frame(width: 38, height: 38)
                Image(systemName: share.isPublic ? "globe" : "lock")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(share.isPublic ? Color.green : Color.orange)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(isGroup ? "\(share.groupObjectIDs.split(separator: ",").count) files" : share.fileName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(XTheme.textPrimary)
                    .lineLimit(1)
                Text(expiryText)
                    .font(.system(size: 11))
                    .foregroundStyle(share.isPublic ? Color.green.opacity(0.9) : XTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                copyLink()
            } label: {
                Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(XTheme.accent)
                    )
            }
            .buttonStyle(.plain)

            Button {
                onCancel()
            } label: {
                Label("Cancel", systemImage: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var expiryText: String {
        if share.isPublic { return "Never expires" }
        if share.expiry == .distantFuture { return "Never expires" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Expires \(formatter.localizedString(for: share.expiry, relativeTo: .now))"
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