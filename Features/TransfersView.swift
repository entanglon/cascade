import SwiftUI
import AppKit

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
    /// Selected transfer card (Space opens its info panel).
    @State private var selectedTransferID: String? = nil
    /// Transfer ID whose info panel is open (nil = closed).
    @State private var infoTargetID: String? = nil
    @State private var columnCount = 2
    @State private var scrollTargetID: String? = nil

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

            // Quick Look-style info panel for the selected transfer (Space):
            // thumbnail, status, progress, size, and where the file lives in
            // the cloud. Live-updates while open; a removed transfer shows a
            // graceful gone-state instead of vanishing mid-read.
            if let infoID = infoTargetID {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { infoTargetID = nil }
                TransferInfoPanel(itemID: infoID) {
                    infoTargetID = nil
                }
                .transition(.opacity)
            }
        }
        .background {
            TransferKeyMonitorView(
                onSpace: {
                    if infoTargetID != nil {
                        infoTargetID = nil
                        return true
                    }
                    guard let selected = selectedTransferID,
                          center.items.contains(where: { $0.id == selected }) else { return false }
                    infoTargetID = selected
                    return true
                },
                onEscape: {
                    if infoTargetID != nil {
                        infoTargetID = nil
                        return true
                    }
                    guard selectedTransferID != nil else { return false }
                    selectedTransferID = nil
                    return true
                },
                onArrow: { delta, isVertical in
                    navTransfer(delta, isVertical: isVertical)
                }
            )
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

    /// Flat visual order (uploads, downloads, imports — the sections stack in
    /// the same column count) backing arrow-key navigation.
    private var navigableTransfers: [TransferCenter.Item] {
        uploads + downloads + imports
    }

    /// Arrow-key selection mirroring the Shared page: arrows walk the visual
    /// order (vertical steps a full row in grid mode, linear in list mode).
    /// Returns false when there is nothing to move through so the event flows.
    @discardableResult
    private func navTransfer(_ delta: Int, isVertical: Bool) -> Bool {
        let items = navigableTransfers
        guard !items.isEmpty else { return false }
        guard let current = items.firstIndex(where: { $0.id == selectedTransferID }) else {
            selectedTransferID = items[0].id
            scrollTargetID = items[0].id
            return true
        }
        let cols = viewModeRaw == "grid" ? max(2, columnCount) : 1
        let step = isVertical ? delta * cols : delta
        let next = min(max(current + step, 0), items.count - 1)
        selectedTransferID = items[next].id
        scrollTargetID = items[next].id
        return true
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.40))
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    private var gridView: some View {
        GeometryReader { geo in
            let cols = max(2, Int(geo.size.width / cardWidth))
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !uploads.isEmpty {
                        sectionHeader("Uploads")
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: cols),
                            spacing: 16
                        ) {
                            ForEach(uploads) { item in
                                TransferGridCard(item: item, isSelected: selectedTransferID == item.id) {
                                    selectedTransferID = item.id
                                }
                                .id(item.id)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    }

                    if !downloads.isEmpty {
                        sectionHeader("Downloads")
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: cols),
                            spacing: 16
                        ) {
                            ForEach(downloads) { item in
                                TransferGridCard(item: item, isSelected: selectedTransferID == item.id) {
                                    selectedTransferID = item.id
                                }
                                .id(item.id)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    }

                    if !imports.isEmpty {
                        sectionHeader("Imports")
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: cols),
                            spacing: 16
                        ) {
                            ForEach(imports) { item in
                                TransferGridCard(item: item, isSelected: selectedTransferID == item.id) {
                                    selectedTransferID = item.id
                                }
                                .id(item.id)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 80)
            }
            .onChange(of: geo.size.width, initial: true) {
                columnCount = max(2, Int(geo.size.width / cardWidth))
            }
            .onChange(of: scrollTargetID) { _, newID in
                guard let newID else { return }
                proxy.scrollTo(newID, anchor: nil)
            }
            }
        }
    }

    private var listView: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !uploads.isEmpty {
                    sectionHeader("Uploads")
                    LazyVStack(spacing: 10) {
                        ForEach(uploads) { item in
                            TransferRow(item: item, isSelected: selectedTransferID == item.id) {
                                    selectedTransferID = item.id
                                }
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                }

                if !downloads.isEmpty {
                    sectionHeader("Downloads")
                    LazyVStack(spacing: 10) {
                        ForEach(downloads) { item in
                            TransferRow(item: item, isSelected: selectedTransferID == item.id) {
                                    selectedTransferID = item.id
                                }
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                }

                if !imports.isEmpty {
                    sectionHeader("Imports")
                    LazyVStack(spacing: 10) {
                        ForEach(imports) { item in
                            TransferRow(item: item, isSelected: selectedTransferID == item.id) {
                                    selectedTransferID = item.id
                                }
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 80)
        }
        .onChange(of: scrollTargetID) { _, newID in
            guard let newID else { return }
            proxy.scrollTo(newID, anchor: nil)
        }
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
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(AppState.self) private var appState

    var body: some View {
        // Glass card (transfers keep cards, not tiles — different function):
        // icon zone with % pill + transport actions, name/status block,
        // progress track. Transport stays visible (functional); menu button,
        // hover effects and bold names are gone (right-click covers actions).
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                TransferIcon(item: item, size: 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(alignment: .top) {
                    Text("\(Int(item.progress * 100))%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(item.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(item.accentColor.opacity(0.14)))

                    Spacer()

                    TransferItemActions(item: item, compact: true)
                }
                .padding(8)
            }
            .frame(height: 92)
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(XTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: 16)

                Text(item.statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(item.statusColor)
                    .lineLimit(1)
                    .frame(height: 13)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.top, 9)

            TransferProgressCapsule(progress: item.progress, tint: item.accentColor,
                                    animating: item.state == .active)
                .allowsHitTesting(false)
                .padding(.horizontal, 11)
                .padding(.vertical, 11)
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? XTheme.accent : Color.white.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .contextMenu { TransferItemMenuContent(item: item, appState: appState) }
        .onTapGesture(count: 2) { revealTransferItem(item, in: appState) }
        .simultaneousGesture(TapGesture(count: 1).onEnded { onSelect() })
        .help(item.state == .complete ? "Double-click to show in folder" : "")
    }
}

/// Thin rounded progress track with a gradient fill; indeterminate shimmer while
/// an upload/download is actively streaming.
struct TransferProgressCapsule: View {
    let progress: Double
    let tint: Color
    var animating: Bool = false

    @State private var phase: Bool = false

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.08))
            .frame(height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint, tint.opacity(0.65)],
                                startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, geo.size.width * min(max(progress, 0), 1)))
                        .animation(.easeInOut(duration: 0.25), value: progress)
                }
            }
            .animation(animating ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                       value: phase)
    }
}

struct TransferRow: View {
    let item: TransferCenter.Item
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 14) {
            TransferIcon(item: item)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(XTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    TransferItemActions(item: item, compact: true)
                    Text("\(Int(item.progress * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(item.accentColor)
                }

                TransferProgressCapsule(progress: item.progress, tint: item.accentColor,
                                        animating: item.state == .active)
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
                .strokeBorder(isSelected ? XTheme.accent : Color.white.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
        )
        .contextMenu { TransferItemMenuContent(item: item, appState: appState) }
        // contentShape makes the whole card (including padding, spacers, and the
        // icon) hit-testable for the double-click, matching the file cards.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { revealTransferItem(item, in: appState) }
        .simultaneousGesture(TapGesture(count: 1).onEnded { onSelect() })
        .help(item.state == .complete ? "Double-click to show in folder" : "")
    }
}

// MARK: - Transfer card actions + colors

/// The tile's icon: a real thumbnail for completed downloads/imports
/// (media only), the direction circle otherwise. Sized by the caller (list
/// rows stay compact, grid tiles go large).
struct TransferIcon: View {
    let item: TransferCenter.Item
    var size: CGFloat = 38
    @State private var thumbURL: URL? = nil

    var body: some View {
        ZStack {
            if let thumbURL {
                AsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: size * 2, maxHeight: size * 1.7)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: .black.opacity(0.18), radius: 2.5, x: 0, y: 1.5)
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
                .frame(width: size, height: size)
            Image(systemName: iconName)
                .font(.system(size: size * 0.47, weight: .semibold))
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
    /// Compact (tile corners): transport buttons only, no menu — right-click
    /// covers the rest. Full (list rows): transport + menu.
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            quickAction

            if !compact {
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
    }

    @ViewBuilder
    private var quickAction: some View {
        switch item.state {
        case .active:
            circleActionButton(
                systemName: "pause.fill",
                color: .orange,
                help: item.direction == .upload
                    ? "Pause upload — resumes from the last uploaded chunk"
                    : "Pause download — resumes from the exact byte offset"
            ) {
                TransferCenter.shared.cancel(item.id)
            }
        case .paused:
            circleActionButton(
                systemName: "play.fill",
                color: .orange,
                help: item.direction == .upload
                    ? "Resume upload from the last uploaded chunk"
                    : "Resume download from the exact byte offset"
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

// MARK: - Transfer info panel (Space)

///
/// Quick Look-style info for one transfer: thumbnail, live status +
/// progress, size, and the file's location in the cloud (vault breadcrumb
/// path). Opened with Space on a selected card/row; X, Escape, or dim-tap
/// closes. A transfer removed while open shows a gone-state.
struct TransferInfoPanel: View {
    let itemID: String
    let onClose: () -> Void
    @Environment(AppState.self) private var appState
    @State private var cloudPath: String? = nil
    @State private var fileSize: Int64? = nil
    @State private var detailsLoadedFor: String? = nil

    private var center: TransferCenter { TransferCenter.shared }
    private var item: TransferCenter.Item? {
        center.items.first(where: { $0.id == itemID })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfer Info")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(XTheme.textPrimary)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            Divider().overlay(Color.white.opacity(0.1))

            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            TransferIcon(item: item, size: 52)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                Text(item.statusLine)
                                    .font(.system(size: 12))
                                    .foregroundStyle(item.statusColor)
                            }
                        }

                        TransferProgressCapsule(progress: item.progress, tint: item.accentColor,
                                                animating: item.state == .active)
                            .allowsHitTesting(false)

                        infoRow(label: "Direction", value: directionText(item.direction))
                        infoRow(label: "Size", value: fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                        infoRow(label: "Location", value: cloudPath ?? "Resolving…")
                        infoRow(label: "Progress", value: "\(Int(item.progress * 100))%")

                        Button {
                            onClose()
                            revealTransferItem(item, in: appState)
                        } label: {
                            Label("Show in Folder", systemImage: "folder")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(XTheme.accent))
                        }
                        .buttonStyle(.plain)
                        .disabled(item.state != .complete)
                        .opacity(item.state != .complete ? 0.4 : 1.0)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(XTheme.textTertiary)
                    Text("No longer listed")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("This transfer finished clearing or was removed.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 440, height: 480)
        .background(AppBackground())
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .task(id: itemID) {
            await loadDetails()
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(3)
            Spacer(minLength: 0)
        }
    }

    private func directionText(_ direction: TransferCenter.Item.Direction) -> String {
        switch direction {
        case .upload: return "Upload"
        case .download: return "Download"
        case .inbound: return "Import"
        }
    }

    /// Resolves vault-backed details once per panel opening: thumbnail, byte
    /// size, and the breadcrumb path to the file in the cloud. Uploads that
    /// haven't cataloged yet (or removed files) leave dashes.
    private func loadDetails() async {
        guard detailsLoadedFor != itemID else { return }
        detailsLoadedFor = itemID
        guard let live = center.items.first(where: { $0.id == itemID }),
              let object = try? await DatabaseManager.shared.object(live.objectID) else { return }
        fileSize = object.size
        cloudPath = await Self.cloudPath(for: object)
    }

    /// Vault breadcrumb path, e.g. "All Files / Movies" — root section plus
    /// every enclosing folder. Cycle-capped like the dashboard math.
    static func cloudPath(for object: ObjectRecord) async -> String {
        var names: [String] = []
        var seen = Set<String>([object.id])
        var parentID = object.parentID
        var guardCount = 0
        while let pid = parentID, guardCount < 32, !seen.contains(pid) {
            guardCount += 1
            seen.insert(pid)
            guard let parent = try? await DatabaseManager.shared.object(pid) else { break }
            names.insert(parent.name, at: 0)
            parentID = parent.parentID
        }
        let root = object.isPrivate ? "Private Vault" : "All Files"
        return ([root] + names).joined(separator: " / ")
    }
}

// MARK: - Keyboard navigation

/// Window-scoped key monitor for the Transfers page (same technique as the
/// file browser's FileBrowserKeyView and the Shared page): Space opens the
/// selected transfer's info panel (Escape closes it). Never steals keys while
/// typing, and defers to other windows. The browser's own monitor defers on
/// this page, so there is no double-handling.
private struct TransferKeyMonitorView: NSViewRepresentable {
    var onSpace: () -> Bool
    var onEscape: () -> Bool
    var onArrow: (Int, Bool) -> Bool

    func makeNSView(context: Context) -> TransferKeyView {
        let view = TransferKeyView()
        view.onSpace = onSpace
        view.onEscape = onEscape
        view.onArrow = onArrow
        return view
    }

    func updateNSView(_ nsView: TransferKeyView, context: Context) {
        nsView.onSpace = onSpace
        nsView.onEscape = onEscape
        nsView.onArrow = onArrow
    }
}

final class TransferKeyView: NSView {
    var onSpace: (() -> Bool)?
    var onEscape: (() -> Bool)?
    var onArrow: ((Int, Bool) -> Bool)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { return nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window != nil else { return event }
                guard event.window === self.window else { return event }
                if let responder = self.window?.firstResponder,
                   responder is NSTextView || responder is NSTextField {
                    return event
                }
                switch event.keyCode {
                case 49: // space
                    if self.onSpace?() == true { return nil }
                case 53: // escape
                    if self.onEscape?() == true { return nil }
                case 123: // left
                    if self.onArrow?(-1, false) == true { return nil }
                case 124: // right
                    if self.onArrow?(1, false) == true { return nil }
                case 125: // down
                    if self.onArrow?(1, true) == true { return nil }
                case 126: // up
                    if self.onArrow?(-1, true) == true { return nil }
                default:
                    break
                }
                return event
            }
        }
        if window == nil, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
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
