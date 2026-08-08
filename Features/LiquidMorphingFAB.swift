import SwiftUI

// MARK: - Animatable Double-Blur Liquid Alpha Mask

struct AnimatableLiquidMetaballCanvas: View, Animatable {
    var splitProgress: CGFloat // 0.0 = merged, 1.0 = fully separated
    var buttonSize: CGFloat = 52
    var maxOffset: CGFloat = 68

    var animatableData: CGFloat {
        get { splitProgress }
        set { splitProgress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let centerX = size.width / 2
            let bottomY = size.height - buttonSize / 2
            let topY = bottomY - (maxOffset * splitProgress)
            let radius = buttonSize / 2

            context.drawLayer { ctx in
                // 1. Initial Blur to merge overlapping shapes
                ctx.addFilter(.blur(radius: 12))
                // 2. Alpha Threshold cutoff to form cohesive liquid skin
                ctx.addFilter(.alphaThreshold(min: 0.5, color: .black))
                // 3. SECOND BLUR PASS: Re-softens threshold cutoff into a crisp, anti-aliased edge
                ctx.addFilter(.blur(radius: 1.5))

                // Bottom Add Blob (pure flat color for alpha mask)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: centerX - radius, y: bottomY - radius, width: buttonSize, height: buttonSize)),
                    with: .color(.black)
                )

                // Top Transfer Blob (Moves up smoothly)
                if splitProgress > 0.001 {
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: centerX - radius, y: topY - radius, width: buttonSize, height: buttonSize)),
                        with: .color(.black)
                    )
                }

                // Liquid Neck Bridge
                let neckWidth = max(0, buttonSize * 0.9 * (1.0 - splitProgress))
                if splitProgress < 0.99 && neckWidth > 1 {
                    let neckRect = CGRect(
                        x: centerX - (neckWidth / 2),
                        y: topY,
                        width: neckWidth,
                        height: (bottomY - topY)
                    )
                    ctx.fill(
                        Path(roundedRect: neckRect, cornerRadius: neckWidth / 2),
                        with: .color(.black)
                    )
                }
            }
        }
        .frame(width: buttonSize, height: maxOffset + buttonSize)
        .clipShape(Rectangle()) // BUG 1 FIX: Strictly clips blur bleed beyond bounding box
    }
}

// MARK: - Liquid Sphere Visualizer (Liquid Filling Up a Sphere)

struct LiquidSphereVisualizer: View {
    var progress: Double
    var isUploading: Bool

    var body: some View {
        TimelineView(.animation(paused: progress <= 0 || progress >= 1.0)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                // Sphere Ambient Glass Gradient Background
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [XTheme.accent.opacity(0.45), XTheme.accentSecondary.opacity(0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Rising Wave Liquid Fill
                GeometryReader { geo in
                    let fillHeight = geo.size.height * min(1.0, max(0.05, progress))
                    let levelY = geo.size.height - fillHeight
                    
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geo.size.height))
                        path.addLine(to: CGPoint(x: 0, y: levelY))
                        
                        // Sinusoidal Liquid Surface Wave
                        let width = geo.size.width
                        let step: CGFloat = 2
                        for x in stride(from: 0, through: width, by: step) {
                            let relativeX = x / width
                            let sine = sin(relativeX * .pi * 2 + now * 4) * 2.5
                            path.addLine(to: CGPoint(x: x, y: levelY + sine))
                        }
                        
                        path.addLine(to: CGPoint(x: width, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [XTheme.accent, XTheme.accentSecondary],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .clipShape(Circle())

                // Specular Inner Sphere Highlight
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.65), .white.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )

                // Center Icon (arrow.up.arrow.down) + Percentage Text
                VStack(spacing: 1) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)

                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                }
            }
        }
    }
}

// MARK: - Main LiquidMorphingFAB View

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

    private let buttonSize: CGFloat = 52
    private let maxOffset: CGFloat = 68

    var body: some View {
        ZStack(alignment: .bottom) {
            // MARK: 1. BUG 2 FIX: UNIFIED LIQUID GLASS SURFACE (Masked by Pure Alpha Canvas)
            ZStack(alignment: .bottom) {
                // Base UltraThinMaterial Translucent Glass
                Rectangle()
                    .fill(.ultraThinMaterial)

                // Vibrant Brand Tint
                XTheme.brandGradient.opacity(0.35)

                // Rising Blue Liquid Fill during Active Transfer
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
                    colors: [.white.opacity(0.55), .white.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Specular Glass Rim Light Stroke
                RoundedRectangle(cornerRadius: buttonSize / 2)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.75), .white.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            }
            .frame(width: buttonSize, height: maxOffset * splitProgress + buttonSize)
            .mask(
                AnimatableLiquidMetaballCanvas(
                    splitProgress: splitProgress,
                    buttonSize: buttonSize,
                    maxOffset: maxOffset
                )
            )
            .shadow(color: XTheme.accent.opacity(0.4), radius: 14, y: 6)

            // MARK: 2. SEPARATE CONTENT LAYER (Icons & Controls Over Glass)

            // TOP BUTTON: Transfer Pill Content
            if splitProgress > 0.05 {
                Button {
                    showMiniTransfersPopover.toggle()
                } label: {
                    LiquidSphereVisualizer(
                        progress: overallProgress,
                        isUploading: activeTransfers.first?.direction == .upload
                    )
                    .frame(width: buttonSize, height: buttonSize)
                    .contentShape(Circle())
                    .scaleEffect(transferHovering ? 1.08 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: transferHovering)
                    .onHover { transferHovering = $0 }
                }
                .buttonStyle(.plain)
                .offset(y: -maxOffset * splitProgress)
                .opacity(min(1.0, splitProgress * 1.5))
                .popover(isPresented: $showMiniTransfersPopover, arrowEdge: .trailing) {
                    MiniTransfersView()
                }
                .help("View Transfer Progress")
            }

            // BOTTOM BUTTON: Add (+) Button Content
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
                        Label("New Private Folder", systemImage: "lock.square.stack.fill")
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
            withAnimation(.spring(response: 0.60, dampingFraction: 0.65)) {
                splitProgress = transferring ? 1.0 : 0.0
            }
        }
    }
}
