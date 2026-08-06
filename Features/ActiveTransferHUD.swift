import SwiftUI

struct ActiveTransferHUD: View {
    private var center: TransferCenter { TransferCenter.shared }

    private var active: [TransferCenter.Item] {
        center.items.filter { $0.state == .active }
    }

    var body: some View {
        if let item = active.first {
            HStack(spacing: 12) {
                Image(systemName: item.direction == .upload
                      ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(XTheme.brandGradient)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(item.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if active.count > 1 {
                            Text("+\(active.count - 1) more")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .tint(XTheme.accent)
                }

                Text("\(Int(item.progress * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: 360)
            .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
