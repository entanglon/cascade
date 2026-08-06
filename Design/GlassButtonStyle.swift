import SwiftUI

struct GlassButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background {
                if prominent {
                    Capsule()
                        .fill(XTheme.brandGradient.opacity(0.55))
                }
            }
            .glassEffect(.regular, in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(
                .spring(response: 0.25, dampingFraction: 0.75),
                value: configuration.isPressed
            )
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var xGlass: GlassButtonStyle { .init() }
    static var xGlassProminent: GlassButtonStyle { .init(prominent: true) }
}
