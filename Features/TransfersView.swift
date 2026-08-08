import SwiftUI

struct TransfersView: View {
    private var center: TransferCenter { TransferCenter.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Clear finished button
                if center.items.contains(where: { $0.state != .active }) {
                    HStack {
                        Spacer()
                        Button {
                            center.clearFinished()
                        } label: {
                            Label("Clear Finished", systemImage: "xmark.circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .glassEffect(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if center.items.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "arrow.up.arrow.down.circle")
                            .font(.system(size: 46, weight: .light))
                            .foregroundStyle(XTheme.textTertiary)
                        Text("No Transfers Yet")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(XTheme.textPrimary)
                        Text("Upload or download files to see them here.")
                            .font(.system(size: 13))
                            .foregroundStyle(XTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(center.items) { item in
                            TransferRow(item: item)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 80)
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
