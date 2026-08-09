import SwiftUI

// MARK: - Liquid Sphere Visualizer (Liquid Fill Progress Bar inside a Round Sphere)

struct LiquidSphereVisualizer: View {
    var progress: Double

    var body: some View {
        TimelineView(.animation(paused: progress <= 0 || progress >= 1.0)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                // Sphere Ambient Glass Tint Background
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [XTheme.accent.opacity(0.45), XTheme.accentSecondary.opacity(0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Rising Liquid Wave Fill
                GeometryReader { geo in
                    let fillHeight = geo.size.height * min(1.0, max(0.05, progress))
                    let levelY = geo.size.height - fillHeight
                    
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geo.size.height))
                        path.addLine(to: CGPoint(x: 0, y: levelY))
                        
                        // Sinusoidal Liquid Surface Wave Animation
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
                    .fill(XTheme.brandGradient)
                }
                .clipShape(Circle())

                // Specular Inner Rim Highlight
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.65), .white.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )

                // Center Sidebar Transfer Icon (arrow.up.arrow.down) + Percentage Text
                VStack(spacing: 1) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)

                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                }
            }
        }
    }
}

// MARK: - Main FAB Component

struct LiquidMorphingFAB: View {
    @Environment(AppState.self) private var appState
    @Binding var showImporter: Bool
    @Binding var showNewFolder: Bool
    @Binding var showNewPrivateFolder: Bool
    @Binding var folderName: String

    @State private var showMiniTransfersPopover = false
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

    var body: some View {
        VStack(spacing: 12) {
            // MARK: - TOP: Round Transfer Button (Appears smoothly above when transfer is active)
            if isTransferring {
                Button {
                    showMiniTransfersPopover.toggle()
                } label: {
                    LiquidSphereVisualizer(progress: overallProgress)
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)
                        .shadow(color: XTheme.accent.opacity(0.4), radius: 12, y: 6)
                        .scaleEffect(transferHovering ? 1.08 : 1.0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: transferHovering)
                        .onHover { transferHovering = $0 }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showMiniTransfersPopover, arrowEdge: .trailing) {
                    MiniTransfersView()
                }
                .transition(.move(edge: .bottom).combined(with: .scale(scale: 0.8)).combined(with: .opacity))
                .help("View Transfer Progress")
            }

            // MARK: - BOTTOM: Standard (+) Add Button
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
                        Label("New Private Folder", systemImage: "number")
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
                        .fill(XTheme.brandGradient)
                        .frame(width: 48, height: 48)

                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .shadow(color: XTheme.accent.opacity(0.4), radius: 12, y: 6)
                .scaleEffect(addHovering ? 1.08 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: addHovering)
                .onHover { addHovering = $0 }
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
        }
        .animation(.spring(response: 0.40, dampingFraction: 0.75), value: isTransferring)
    }
}
