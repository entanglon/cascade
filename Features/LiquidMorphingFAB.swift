import SwiftUI

// MARK: - Transfers Button Phase State

enum TransfersButtonPhase: Equatable {
    case idle                                      // 0 transfers: Single 52x52 Add button
    case materializing                             // Budding off: 0 -> 1 transfer
    case active(count: Int, progress: Double)      // Steady state: Transfer pill split above
    case dematerializing                           // Merging back: transfers completed
}

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
            // MARK: 1. UNIFIED SINGLE LIQUID GLASS SURFACE (Masked by Metaball SDF)
            ZStack(alignment: .bottom) {
                // Glass Base Material
                Rectangle()
                    .fill(.ultraThinMaterial)

                // Ambient Brand Tint
                XTheme.brandGradient.opacity(0.35)

                // Progressive Blue Fill for Active Transfer
                if splitProgress > 0.02 {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(XTheme.brandGradient)
                            .frame(height: maxOffset * min(1.0, max(0.05, overallProgress)) + buttonSize)
                            .animation(.linear(duration: 0.2), value: overallProgress)
                    }
                }

                // Top Specular Lighting Highlight
                LinearGradient(
                    colors: [.white.opacity(0.5), .white.opacity(0.05)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: buttonSize, height: maxOffset * splitProgress + buttonSize)
            .mask {
                // Smooth Anti-Aliased Liquid Mask
                LiquidMetaballCanvas(progress: splitProgress, buttonSize: buttonSize, maxOffset: maxOffset)
            }
            .overlay(
                // Specular Glass Rim Outline
                ZStack(alignment: .bottom) {
                    LinearGradient(
                        colors: [.white.opacity(0.75), .white.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                .frame(width: buttonSize, height: maxOffset * splitProgress + buttonSize)
                .mask {
                    LiquidMetaballCanvas(progress: splitProgress, buttonSize: buttonSize, maxOffset: maxOffset, isStrokeOnly: true)
                }
            )
            .shadow(color: XTheme.accent.opacity(0.4), radius: 14, y: 6)

            // MARK: 2. SEPARATE CONTENT & INTERACTIVE OVERLAY LAYER

            // TOP BUTTON: Transfer Pill Overlay
            if splitProgress > 0.08 {
                Button {
                    showMiniTransfersPopover.toggle()
                } label: {
                    ZStack {
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
                    .scaleEffect(transferHovering ? 1.08 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: transferHovering)
                    .onHover { transferHovering = $0 }
                }
                .buttonStyle(.plain)
                .offset(y: -maxOffset * splitProgress)
                .opacity(min(1.0, splitProgress * 1.6))
                .popover(isPresented: $showMiniTransfersPopover, arrowEdge: .trailing) {
                    MiniTransfersView()
                }
                .help("View Transfer Progress")
            }

            // BOTTOM BUTTON: Add (+) Button Overlay
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
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Circle())
                .scaleEffect(addHovering ? 1.08 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: addHovering)
                .onHover { addHovering = $0 }
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

// MARK: - Anti-Aliased Liquid Metaball Mask Canvas

struct LiquidMetaballCanvas: View {
    var progress: CGFloat
    var buttonSize: CGFloat
    var maxOffset: CGFloat
    var isStrokeOnly: Bool = false

    var body: some View {
        Canvas { context, size in
            let centerX = size.width / 2
            let bottomY = size.height - buttonSize / 2
            let topY = bottomY - (maxOffset * progress)
            let radius = buttonSize / 2

            let drawStyle: (inout GraphicsContext, Path) -> Void = { ctx, path in
                if isStrokeOnly {
                    ctx.stroke(path, with: .color(.white), lineWidth: 1.5)
                } else {
                    ctx.fill(path, with: .color(.white))
                }
            }

            if progress < 0.02 {
                // Resting single circle
                drawStyle(&context, Path(ellipseIn: CGRect(x: centerX - radius, y: bottomY - radius, width: buttonSize, height: buttonSize)))
            } else {
                context.addFilter(.alphaThreshold(min: 0.45, color: .white))
                context.addFilter(.blur(radius: 8))

                context.drawLayer { ctx in
                    // Bottom Add Circle
                    drawStyle(&ctx, Path(ellipseIn: CGRect(x: centerX - radius, y: bottomY - radius, width: buttonSize, height: buttonSize)))

                    // Top Transfer Circle
                    drawStyle(&ctx, Path(ellipseIn: CGRect(x: centerX - radius, y: topY - radius, width: buttonSize, height: buttonSize)))

                    // Connecting Liquid Neck Bridge
                    if progress < 0.90 {
                        let neckWidth = max(0, buttonSize * 0.9 * (1.0 - progress * 1.1))
                        if neckWidth > 1 {
                            let neckRect = CGRect(
                                x: centerX - neckWidth / 2,
                                y: topY,
                                width: neckWidth,
                                height: bottomY - topY
                            )
                            drawStyle(&ctx, Path(roundedRect: neckRect, cornerRadius: neckWidth / 2))
                        }
                    }
                }
            }
        }
    }
}
