#if os(iOS)
import SwiftUI
import UIKit

struct MPVPlayerView: UIViewRepresentable {
    let objectID: String

    func makeUIView(context: Context) -> MPVUIView {
        let view = MPVUIView()
        return view
    }

    func updateUIView(_ uiView: MPVUIView, context: Context) {
    }
}

class MPVUIView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#endif
