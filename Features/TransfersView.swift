import SwiftUI

/// Reveals the object behind a completed transfer in the file browser: navigates to
/// its enclosing folder, selects it, and flashes its border highlight. No-op while a
/// transfer is still running (the file may not be fully available yet).
@MainActor
func revealTransferItem(_ item: TransferCenter.Item, in appState: AppState) {
    guard item.state == .complete else { return }
    Task {
        guard let object = try? await DatabaseManager.shared.object(item.objectID) else { return }
        appState.revealObject(object)
    }
}

struct TransfersView: View {
    private var center: TransferCenter { TransferCenter.shared }
    @AppStorage("xc.viewMode") private var viewModeRaw = "grid"
    @AppStorage("xc.cardWidth") private var cardWidth = 220.0

    var body: some View {
        ZStack {
            if center.items.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 0) {
                    if center.items.contains(where: { $0.state == .complete || $0.state == .failed }) {
                        HStack {
                            Spacer()
                            Button {
                                center.clearFinished()
                            } label: {
                                Label("Clear Finished", systemImage: "xmark.circle")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                                    // Same footprint as the top bar's grid/list toggle
                                    // + sort buttons, so the row lines up beneath them.
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

                    if viewModeRaw == "list" {
                        listView
                    } else {
                        gridView
                    }
                }
            }
        }
    }

    private var uploads: [TransferCenter.Item] {
        center.items.filter { $0.direction == .upload }
    }

    private var downloads: [TransferCenter.Item] {
        center.items.filter { $0.direction == .download }
    }

    private var imports: [TransferCenter.Item] {
        center.items.filter { $0.direction == .inbound }
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

    private var gridView: some View {
        GeometryReader { geo in
            let cols = max(2, Int(geo.size.width / cardWidth))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !uploads.isEmpty {
                        sectionHeader("Uploads")
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols),
                            spacing: 12
                        ) {
                            ForEach(uploads) { item in
                                TransferGridCard(item: item)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    }

                    if !downloads.isEmpty {
                        sectionHeader("Downloads")
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols),
                            spacing: 12
                        ) {
                            ForEach(downloads) { item in
                                TransferGridCard(item: item)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    }

                    if !imports.isEmpty {
                        sectionHeader("Imports")
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols),
                            spacing: 12
                        ) {
                            ForEach(imports) { item in
                                TransferGridCard(item: item)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 80)
            }
        }
    }

    private var listView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !uploads.isEmpty {
                    sectionHeader("Uploads")
                    LazyVStack(spacing: 10) {
                        ForEach(uploads) { item in
                            TransferRow(item: item)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                }

                if !downloads.isEmpty {
                    sectionHeader("Downloads")
                    LazyVStack(spacing: 10) {
                        ForEach(downloads) { item in
                            TransferRow(item: item)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                }

                if !imports.isEmpty {
                    sectionHeader("Imports")
                    LazyVStack(spacing: 10) {
                        ForEach(imports) { item in
                            TransferRow(item: item)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 80)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(XTheme.brandGradient)

            Text("No Transfers Yet")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)

            Text("Active and completed file uploads, downloads, or imports will appear here.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
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

struct TransferGridCard: View {
    let item: TransferCenter.Item
    @Environment(AppState.self) private var appState
    @State private var hovering = false

    var body: some View {
        // Fixed-shape card, same as the file cards: icon/thumbnail area on top,
        // then a fixed-height name/status block, then the progress bar. No part
        // of the card sizes itself to its text, so every card in the grid has
        // EXACTLY the same dimensions regardless of name length or status text.
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Color.white.opacity(0.03)

                TransferIcon(item: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(spacing: 6) {
                    Text("\(Int(item.progress * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(item.accentColor)

                    TransferItemActions(item: item)
                }
                .padding(8)
            }
            .frame(height: 92)
            .clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(XTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: 16)

                Text(item.statusLine)
                    .font(.system(size: 10))
                    .foregroundStyle(item.statusColor)
                    .lineLimit(1)
                    .frame(height: 13)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .background(Color.white.opacity(0.04))

            ProgressView(value: item.progress)
                .progressViewStyle(.linear)
                .tint(item.accentColor)
                .animation(.easeInOut(duration: 0.25), value: item.progress)
                // Display-only — let clicks pass through so the card's double-click
                // reveal works anywhere on the card, not just on the text.
                .allowsHitTesting(false)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.08) : Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .contextMenu { TransferItemMenuContent(item: item, appState: appState) }
        // contentShape makes the whole card (including padding, spacers, and the
        // icon) hit-testable for the double-click, matching the file cards.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { revealTransferItem(item, in: appState) }
        .onHover { hovering = $0 }
        .scaleEffect(hovering ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(item.state == .complete ? "Double-click to show in folder" : "")
    }
}

struct TransferRow: View {
    let item: TransferCenter.Item
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 14) {
            TransferIcon(item: item)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(XTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    TransferItemActions(item: item)
                    Text("\(Int(item.progress * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(item.accentColor)
                }

                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .tint(item.accentColor)
                    .animation(.easeInOut(duration: 0.25), value: item.progress)
                    // Display-only — let clicks pass through so the card's double-click
                    // reveal works anywhere on the card, not just on the text.
                    .allowsHitTesting(false)

                HStack {
                    Text(item.statusLine)
                        .font(.system(size: 11))
                        .foregroundStyle(item.statusColor)
                    Spacer()
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .contextMenu { TransferItemMenuContent(item: item, appState: appState) }
        // contentShape makes the whole card (including padding, spacers, and the
        // icon) hit-testable for the double-click, matching the file cards.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { revealTransferItem(item, in: appState) }
        .help(item.state == .complete ? "Double-click to show in folder" : "")
    }
}

// MARK: - Transfer card actions + colors

/// The card's leading icon: a real thumbnail for completed downloads/imports
/// (media only), the direction circle otherwise.
struct TransferIcon: View {
    let item: TransferCenter.Item
    @State private var thumbURL: URL? = nil

    var body: some View {
        ZStack {
            if let thumbURL {
                AsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 38, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .task(id: item.id) {
            await loadThumbnail()
        }
    }

    private var placeholder: some View {
        ZStack {
            Circle()
                .fill(item.iconBackground)
                .frame(width: 38, height: 38)
            Image(systemName: iconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(item.accentColor)
        }
    }

    private var iconName: String {
        switch item.direction {
        case .upload: return "arrow.up.circle.fill"
        case .download: return "arrow.down.circle.fill"
        case .inbound: return "tray.and.arrow.down.fill"
        }
    }

    private func loadThumbnail() async {
        guard item.state == .complete, item.direction != .upload,
              let object = try? await DatabaseManager.shared.object(item.objectID) else { return }
        thumbURL = await ThumbnailService.shared.thumbnailURL(for: object)
    }
}

extension TransferCenter.Item {
    var accentColor: Color {
        switch state {
        case .paused: .orange
        case .failed: .red
        default: XTheme.accent
        }
    }

    var statusColor: Color {
        switch state {
        case .failed: .red
        case .paused: .orange
        default: XTheme.textTertiary
        }
    }

    var iconBackground: Color {
        switch state {
        case .failed: Color.red.opacity(0.15)
        case .paused: Color.orange.opacity(0.15)
        default: XTheme.accent.opacity(0.15)
        }
    }
}

struct TransferItemActions: View {
    let item: TransferCenter.Item
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            quickAction

            // Menu button styled exactly like the file cards' ellipsis menu.
            Menu {
                TransferItemMenuContent(item: item, appState: appState)
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
            .help("Transfer options")
            .accessibilityLabel("Options for \(item.name)")
        }
    }

    @ViewBuilder
    private var quickAction: some View {
        switch item.state {
        case .active:
            if item.direction == .upload {
                circleActionButton(
                    systemName: "pause.fill",
                    color: .orange,
                    help: "Pause upload — resumes from the last uploaded chunk"
                ) {
                    TransferCenter.shared.cancel(item.id)
                }
            } else {
                circleActionButton(
                    systemName: "xmark",
                    color: .red,
                    help: "Cancel download"
                ) {
                    TransferCenter.shared.cancel(item.id)
                }
            }
        case .paused:
            circleActionButton(
                systemName: "play.fill",
                color: .orange,
                help: "Resume upload from the last uploaded chunk"
            ) {
                Task { await TransferCenter.shared.resume(item.id) }
            }
        case .failed:
            circleActionButton(
                systemName: "arrow.clockwise",
                color: .orange,
                help: item.direction == .upload ? "Retry upload from the last uploaded chunk" : "Retry download"
            ) {
                Task { await TransferCenter.shared.resume(item.id) }
            }
        case .complete:
            EmptyView()
        }
    }

    /// Small dark glass circle button matching the file cards' ellipsis styling.
    private func circleActionButton(
        systemName: String,
        color: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.40))
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
            }
            .frame(width: 24, height: 24)
            .glassEffect(.regular.interactive(), in: .circle)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Shared transfer menu (menu button + right-click)

@ViewBuilder
func TransferItemMenuContent(item: TransferCenter.Item, appState: AppState) -> some View {
    switch item.state {
    case .active:
        if item.direction == .upload {
            Button {
                TransferCenter.shared.cancel(item.id)
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            Button(role: .destructive) {
                TransferCenter.shared.discard(item.id)
            } label: {
                Label("Cancel & Delete", systemImage: "trash.fill")
            }
        } else {
            Button {
                TransferCenter.shared.cancel(item.id)
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            Button(role: .destructive) {
                TransferCenter.shared.discard(item.id)
            } label: {
                Label("Cancel & Delete", systemImage: "trash.fill")
            }
        }
    case .paused:
        Button {
            Task { await TransferCenter.shared.resume(item.id) }
        } label: {
            Label("Resume", systemImage: "play.fill")
        }
        Button(role: .destructive) {
            TransferCenter.shared.discard(item.id)
        } label: {
            Label("Delete", systemImage: "trash.fill")
        }
    case .failed:
        Button {
            Task { await TransferCenter.shared.resume(item.id) }
        } label: {
            Label("Retry", systemImage: "arrow.clockwise")
        }
        Button(role: .destructive) {
            TransferCenter.shared.discard(item.id)
        } label: {
            Label("Delete", systemImage: "trash.fill")
        }
    case .complete:
        Button {
            revealTransferItem(item, in: appState)
        } label: {
            Label("Show in Folder", systemImage: "folder")
        }
        Button {
            TransferCenter.shared.removeItems(forObjectID: item.objectID)
        } label: {
            Label("Remove", systemImage: "xmark.circle.fill")
        }
    }
}

// MARK: - Status line

extension TransferCenter.Item {
    /// The status text plus, for terminal cards, when they finished — e.g.
    /// "Uploaded · 4:12 PM" — so restored history reads as history, not as
    /// something still happening.
    var statusLine: String {
        guard let finishedAt, state == .complete || state == .failed else { return statusText }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(finishedAt) ? "h:mm a" : "MMM d, h:mm a"
        return "\(statusText) · \(formatter.string(from: finishedAt))"
    }
}
