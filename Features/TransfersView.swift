import SwiftUI

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
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .glassEffect(.regular.interactive(), in: .capsule)
                                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
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

    private var gridView: some View {
        GeometryReader { geo in
            let cols = max(2, Int(geo.size.width / cardWidth))
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols),
                    spacing: 12
                ) {
                    ForEach(center.items) { item in
                        TransferGridCard(item: item)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 80)
            }
        }
    }

    private var listView: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(center.items) { item in
                    TransferRow(item: item)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
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

            Text("Active and completed file uploads or downloads will appear here.")
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

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                ZStack {
                    Circle()
                        .fill(item.iconBackground)
                        .frame(width: 36, height: 36)
                    Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(item.accentColor)
                }

                Spacer()

                TransferItemActions(item: item)

                Text("\(Int(item.progress * 100))%")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(item.accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(XTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(item.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(item.statusColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ProgressView(value: item.progress)
                .progressViewStyle(.linear)
                .tint(item.accentColor)
                .animation(.easeInOut(duration: 0.25), value: item.progress)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .contextMenu { TransferItemMenuContent(item: item) }
    }
}

struct TransferRow: View {
    let item: TransferCenter.Item

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(item.iconBackground)
                    .frame(width: 38, height: 38)
                Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(item.accentColor)
            }

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

                HStack {
                    Text(item.statusText)
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
        .contextMenu { TransferItemMenuContent(item: item) }
    }
}

// MARK: - Transfer card actions + colors

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

    var body: some View {
        HStack(spacing: 8) {
            quickAction

            // Menu button styled exactly like the file cards' ellipsis menu.
            Menu {
                TransferItemMenuContent(item: item)
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
func TransferItemMenuContent(item: TransferCenter.Item) -> some View {
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
        if item.direction == .upload {
            Button(role: .destructive) {
                TransferCenter.shared.discard(item.id)
            } label: {
                Label("Delete", systemImage: "trash.fill")
            }
        }
    case .complete:
        Button {
            TransferCenter.shared.removeItems(forObjectID: item.objectID)
        } label: {
            Label("Remove", systemImage: "xmark.circle.fill")
        }
    }
}
