import SwiftUI

struct LiquidMorphingFAB: View {
    @Environment(AppState.self) private var appState
    @Binding var showImporter: Bool
    @Binding var showNewFolder: Bool
    @Binding var showNewPrivateFolder: Bool
    @Binding var folderName: String

    @State private var showMiniTransfersPopover = false
    @State private var splitProgress: CGFloat = 0.0

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
            // MARK: - Liquid Glass Surface Layer (Masked by Canvas Metaball)
            ZStack(alignment: .bottom) {
                // 1. Glass Material Background
                Rectangle()
                    .fill(.ultraThinMaterial)

                // 2. Ambient Blue Tint
                XTheme.brandGradient.opacity(0.3)

                // 3. Progressive Blue Fill (Fills from bottom to top for active transfers)
                if splitProgress > 0.05 {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(XTheme.brandGradient)
                            .frame(height: maxOffset * min(1.0, max(0.05, overallProgress)) + buttonSize)
                            .animation(.linear(duration: 0.2), value: overallProgress)
                    }
                }

                // 4. White Top Lighting Highlight
                LinearGradient(
                    colors: [.white.opacity(0.4), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: buttonSize, height: maxOffset * splitProgress + buttonSize)
            .mask {
                // MARK: - Canvas Liquid Metaball Mask
                Canvas { context, size in
                    context.addFilter(.alphaThreshold(min: 0.5, color: .white))
                    context.addFilter(.blur(radius: 10))

                    context.drawLayer { ctx in
                        let centerX = size.width / 2
                        let bottomY = size.height - buttonSize / 2
                        let topY = bottomY - (maxOffset * splitProgress)

                        let radius = buttonSize / 2

                        // Bottom Circle (Add button)
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: centerX - radius, y: bottomY - radius, width: buttonSize, height: buttonSize)),
                            with: .color(.white)
                        )

                        // Top Circle (Transfer button)
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: centerX - radius, y: topY - radius, width: buttonSize, height: buttonSize)),
                            with: .color(.white)
                        )

                        // Connecting Liquid Bridge (Pitches off organically)
                        let bridgeProgress = splitProgress
                        if bridgeProgress > 0.05 && bridgeProgress < 0.95 {
                            let neckWidth = max(0, buttonSize * (1.0 - bridgeProgress * 1.1))
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
                }
            }
            .shadow(color: XTheme.accent.opacity(0.35), radius: 12, y: 6)

            // MARK: - Interactive Button Overlays (Icons & Controls)

            // Top Transfer Button Overlay
            if splitProgress > 0.1 {
                Button {
                    showMiniTransfersPopover.toggle()
                } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)

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
                }
                .buttonStyle(.plain)
                .offset(y: -maxOffset * splitProgress)
                .opacity(min(1.0, splitProgress * 1.5))
                .popover(isPresented: $showMiniTransfersPopover, arrowEdge: .trailing) {
                    MiniTransfersView()
                }
                .help("View Transfer Progress")
            }

            // Bottom Add Button Overlay
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
                    Circle()
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)

                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: buttonSize, height: buttonSize)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
        }
        .onChange(of: isTransferring, initial: true) { _, transferring in
            withAnimation(.spring(response: 0.55, dampingFraction: 0.70)) {
                splitProgress = transferring ? 1.0 : 0.0
            }
        }
    }
}
