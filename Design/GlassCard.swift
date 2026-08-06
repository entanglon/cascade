import SwiftUI

/// A reusable Liquid Glass card container.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = XTheme.cornerXL
    var padding: CGFloat = XTheme.spaceXL
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .glassEffect(
                .regular,
                in: .rect(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

/// Convenience helper so any view can become liquid glass conditionally.
extension View {
    @ViewBuilder
    func xGlass(
        _ enabled: Bool = true,
        cornerRadius: CGFloat,
        interactive: Bool = false
    ) -> some View {
        if enabled {
            self.glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: .rect(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self
        }
    }
}
