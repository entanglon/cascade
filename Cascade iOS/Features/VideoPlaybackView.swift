#if os(iOS)
import SwiftUI

struct VideoPlaybackView: View {
    let file: FileItem

    var body: some View {
        VStack(spacing: 0) {
            MPVPlayerView(objectID: file.id)
                .ignoresSafeArea()

            HStack {
                Spacer()
                Text(file.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(8)
        }
        .background(.black)
    }
}
#endif
