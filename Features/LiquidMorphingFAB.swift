import SwiftUI

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
            // MARK: - TOP: Transfer Pill Button (Appears smoothly above when transfer is active)
            if isTransferring {
                Button {
                    showMiniTransfersPopover.toggle()
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .stroke(.white.opacity(0.2), lineWidth: 3)
                                .frame(width: 26, height: 26)
                            Circle()
                                .trim(from: 0, to: max(0.05, overallProgress))
                                .stroke(
                                    XTheme.brandGradient,
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                                .frame(width: 26, height: 26)

                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }

                        Text("\(Int(overallProgress * 100))%")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)

                        if activeTransfers.count > 1 {
                            Text("(\(activeTransfers.count))")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .shadow(color: XTheme.accent.opacity(0.35), radius: 10, y: 4)
                    .scaleEffect(transferHovering ? 1.05 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: transferHovering)
                    .onHover { transferHovering = $0 }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showMiniTransfersPopover, arrowEdge: .trailing) {
                    MiniTransfersView()
                }
                .transition(.move(edge: .bottom).combined(with: .scale(scale: 0.85)).combined(with: .opacity))
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
                        Label("New Private Folder", systemImage: "asterisk")
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
