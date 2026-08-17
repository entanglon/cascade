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
                            LazyVStack(spacing: 10) {
                                ForEach(publicShares) { share in
                                    ShareRowCard(share: share, onCancel: { cancelTarget = share })
                                }
                            }
                            .padding(.horizontal, 24)
                        }

                        if !privateShares.isEmpty {
                            sectionHeader("Private — expires, revocable")
                            LazyVStack(spacing: 10) {
                                ForEach(privateShares) { share in
                                    ShareRowCard(share: share, onCancel: { cancelTarget = share })
                                }
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

/// One outgoing share card, styled like the transfer cards: kind icon up front,
/// a corner badge marking private vs public, and Copy Link / Cancel Share in the
/// trailing ellipsis menu (the same menu style as transfer cards).
struct ShareRowCard: View {
    let share: ShareRecord
    let onCancel: () -> Void
    @State private var copied = false

    private var isGroup: Bool { !share.groupObjectIDs.isEmpty }
    private var isPublic: Bool { share.isPublic }
    private var kindColor: Color { isPublic ? Color.green : Color.orange }
    private var kindIcon: String { isPublic ? "globe" : "lock.fill" }

    var body: some View {
        HStack(spacing: 14) {
            // Kind icon: lock for private, globe for public.
            ZStack {
                Circle()
                    .fill(kindColor.opacity(0.16))
                    .frame(width: 38, height: 38)
                Image(systemName: kindIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(kindColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(isGroup ? "\(share.groupObjectIDs.split(separator: ",").count) files" : share.fileName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(XTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(expiryText)
                    .font(.system(size: 11))
                    .foregroundStyle(isPublic ? Color.green.opacity(0.9) : XTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Copy Link + Cancel Share live in the ellipsis menu, matching the
            // transfer cards' menu button styling.
            Menu {
                Button {
                    copyLink()
                } label: {
                    Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button(role: .destructive) {
                    onCancel()
                } label: {
                    Label("Cancel Share", systemImage: "xmark.circle.fill")
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.40))
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
            .accessibilityLabel("Options for \(share.fileName)")
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        // Corner badge: small kind icon on the card's top-trailing corner, above
        // the menu — the private/public distinction at a glance.
        .overlay(alignment: .topTrailing) {
            ZStack {
                Circle()
                    .fill(kindColor.opacity(0.14))
                Image(systemName: isPublic ? "globe" : "lock.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(kindColor)
            }
            .frame(width: 18, height: 18)
            .padding(6)
        }
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