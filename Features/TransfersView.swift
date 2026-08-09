import SwiftUI

struct TransfersView: View {
    private var center: TransferCenter { TransferCenter.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if center.items.contains(where: { $0.state != .active }) {
                    HStack {
                        Spacer()
                        Button {
                            center.clearFinished()
                        } label: {
                            Label("Clear Finished", systemImage: "xmark.circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .glassEffect(.regular.interactive(), in: .capsule)
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if center.items.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "arrow.up.arrow.down.circle")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(XTheme.textTertiary)
                        Text("No Transfers Yet")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(XTheme.textPrimary)
                        Text("Active and completed file uploads or downloads will appear here.")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 280)
                    }
                    .padding(40)
                    .frame(maxWidth: .infinity)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .padding(.top, 40)
                } else {
                    LazyVStack(spacing: 10) {
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
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(item.state == .failed ? Color.red.opacity(0.15) : XTheme.accent.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(item.state == .failed ? Color.red : XTheme.accent)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(XTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(Int(item.progress * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(item.state == .failed ? .red : XTheme.accent)
                }

                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .tint(item.state == .failed ? .red : XTheme.accent)

                HStack {
                    Text(item.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(item.state == .failed ? Color.red.opacity(0.8) : XTheme.textTertiary)
                    Spacer()
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}
