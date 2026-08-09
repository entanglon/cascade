import SwiftUI

struct MiniTransfersView: View {
    @Environment(AppState.self) private var appState
    private var center: TransferCenter { TransferCenter.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Text("Transfers")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                Button("View All") {
                    appState.selectDestination(.transfers)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(XTheme.accent)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            Divider().overlay(.white.opacity(0.1))

            if center.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(XTheme.accent)
                    Text("No active transfers")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(center.items.prefix(5)) { item in
                            HStack(spacing: 10) {
                                Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(XTheme.accent)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)

                                    ProgressView(value: item.progress)
                                        .progressViewStyle(.linear)
                                        .tint(item.accentColor)
                                        .animation(.easeInOut(duration: 0.25), value: item.progress)
                                }

                                Text("\(Int(item.progress * 100))%")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.7))

                                TransferItemActions(item: item)
                            }
                            .padding(10)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
                            .contextMenu { TransferItemMenuContent(item: item) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                .frame(maxHeight: 220)
            }
        }
        .frame(width: 280)
    }
}
