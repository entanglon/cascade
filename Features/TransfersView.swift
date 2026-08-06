import SwiftUI

struct TransfersView: View {
    private var center: TransferCenter { TransferCenter.shared }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if center.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.up.arrow.down.circle")
                            .font(.system(size: 46, weight: .light))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("No transfers yet")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.top, 80)
                }
                ForEach(center.items) { item in
                    TransferRow(item: item)
                }
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem {
                Button("Clear Finished") { center.clearFinished() }
                    .buttonStyle(.xGlass)
                    .disabled(!center.items.contains { $0.state != .active })
            }
        }
    }
}

struct TransferRow: View {
    let item: TransferCenter.Item

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(item.state == .failed ? AnyShapeStyle(.red.opacity(0.8)) : AnyShapeStyle(XTheme.brandGradient))

            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .tint(item.state == .failed ? .red : XTheme.accent)
                    Text("\(Int(item.progress * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 38, alignment: .trailing)
                }
                Text(item.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
    }
}
