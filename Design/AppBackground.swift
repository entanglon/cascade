import SwiftUI

struct AppBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.11)

            RadialGradient(
                colors: [
                    Color(red: 0.12, green: 0.18, blue: 0.32).opacity(0.5),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 600
            )

            RadialGradient(
                colors: [
                    Color(red: 0.15, green: 0.12, blue: 0.28).opacity(0.3),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 700
            )
        }
        .ignoresSafeArea()
    }
}
