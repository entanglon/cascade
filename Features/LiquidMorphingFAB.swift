import SwiftUI

struct LiquidMorphingFAB: View {
    @Environment(AppState.self) private var appState
    @Binding var showImporter: Bool
    @Binding var showNewFolder: Bool
    @Binding var showNewPrivateFolder: Bool
    @Binding var folderName: String

    @State private var showMiniTransfersPopover = false
    @State private var splitProgress: CGFloat = 0.0
    @State private var addHovering = false
    @State private var transferHovering = false

    private var activeTransfers: [TransferCenter.Item] {
        TransferCenter.shared.items.filter { $0.state == .active }
    }

    private var overallProgress: Double {
        guard !activeTransfers.isEmpty else { return 0 }
        let total = activeTransfers.reduce(0.0) { $0 + $1.progress }
        return total / Double(activeTransfers.count)
    }

    private var isTransferring: Bool {
        !activeTransfers.isEmpty
    }

    // Geometry parameters
    private let buttonSize: CGFloat = 52
    private let maxOffset: CGFloat = 68

    var body: some View {
        ZStack(alignment: .bottom) {
            // MARK: - Liquid Gooey Metaball Bridge
            if splitProgress > 0.02 && splitProgress < 0.98 {
                LiquidMetaballBridge(progress: splitProgress)
                    .frame(width: buttonSize, height: maxOffset + buttonSize)
                    .allowsHitTesting(false)
            }

            // MARK: - TOP BUTTON: Transfer Pill (Splits & Moves Upwards)
            if splitProgress > 0.05 {
                transferPillButton
                    .offset(y: -maxOffset * splitProgress)
                    .scaleEffect(0.6 + 0.4 * splitProgress)
                    .opacity(min(1.0, splitProgress * 1.5))
            }

            // MARK: - BOTTOM BUTTON: (+) Add Button
            addButton
        }
        .onChange(of: isTransferring, initial: true) { _, transferring in
            withAnimation(.spring(response: 0.55, dampingFraction: 0.70)) {
                splitProgress = transferring ? 1.0 : 0.0
            }
        }
    }

    // MARK: - Top Button: Transfer Pill

    private var transferPillButton: some View {
        Button {
            showMiniTransfersPopover.toggle()
        } label: {
            ZStack {
                // Glass Base with Brand Gradient
                Circle()
                    .fill(XTheme.brandGradient)

                // Progressive Fill Layer (Fills from bottom to top)
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(Color.white.opacity(0.3))
                            .frame(height: geo.size.height * min(1.0, max(0.05, overallProgress)))
                            .animation(.linear(duration: 0.2), value: overallProgress)
                    }
                }
                .clipShape(Circle())

                // Specular Glass Rim
                Circle()
                    .strokeBorder(LinearGradient(
                        colors: [.white.opacity(0.6), .white.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ), lineWidth: 1.5)

                // Transfer Content
                if let item = activeTransfers.first {
                    VStack(spacing: 1) {
                        Image(systemName: item.direction == .upload ? "arrow.up" : "arrow.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)

                        Text("\(Int(overallProgress * 100))%")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)
            .shadow(color: XTheme.accent.opacity(0.45), radius: 12, y: 6)
            .scaleEffect(transferHovering ? 1.06 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: transferHovering)
            .onHover { transferHovering = $0 }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showMiniTransfersPopover, arrowEdge: .trailing) {
            MiniTransfersView()
        }
        .help("View Transfer Progress")
    }

    // MARK: - Bottom Button: Add (+) Button

    private var addButton: some View {
        Menu {
            Button { showImporter = true } label: {
                Label(appState.selectedDestination == .privateVault ? "Upload Encrypted File" : "Upload File", systemImage: "arrow.up.doc.fill")
            }
            Divider()
            if appState.selectedDestination == .privateVault {
                Button {
                    folderName = ""
                    showNewPrivateFolder = true
                } label: {
                    Label("New Private Folder", systemImage: "lock.shield.fill")
                }
            } else {
                Button {
                    folderName = ""
                    showNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            }
        } label: {
            ZStack {
                // Glass Base with Brand Gradient
                Circle()
                    .fill(XTheme.brandGradient)

                // Specular Glass Rim
                Circle()
                    .strokeBorder(LinearGradient(
                        colors: [.white.opacity(0.6), .white.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ), lineWidth: 1.5)

                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)
            .shadow(color: XTheme.accent.opacity(0.45), radius: 14, y: 6)
            .scaleEffect(addHovering ? 1.08 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: addHovering)
            .onHover { addHovering = $0 }
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }
}

// MARK: - Canvas Metaball Liquid Bridge

struct LiquidMetaballBridge: View {
    var progress: CGFloat

    var body: some View {
        Canvas { context, size in
            guard progress > 0.02 && progress < 0.98 else { return }

            context.addFilter(.alphaThreshold(min: 0.48, color: XTheme.accent))
            context.addFilter(.blur(radius: 12))

            context.drawLayer { ctx in
                let centerX = size.width / 2
                let bottomY = size.height - 26
                let topY = bottomY - (68 * progress)

                let radius: CGFloat = 22

                ctx.fill(
                    Path(ellipseIn: CGRect(x: centerX - radius, y: bottomY - radius, width: radius * 2, height: radius * 2)),
                    with: .color(.white)
                )

                ctx.fill(
                    Path(ellipseIn: CGRect(x: centerX - radius, y: topY - radius, width: radius * 2, height: radius * 2)),
                    with: .color(.white)
                )

                let neckWidth = max(0, radius * 1.6 * (1.0 - progress))
                if neckWidth > 1 {
                    let neckRect = CGRect(
                        x: centerX - neckWidth / 2,
                        y: topY,
                        width: neckWidth,
                        height: bottomY - topY
                    )
                    ctx.fill(
                        Path(roundedRect: neckRect, cornerRadius: neckWidth / 2),
                        with: .color(.white)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}
