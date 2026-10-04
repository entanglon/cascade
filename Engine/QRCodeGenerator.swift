import SwiftUI
import CoreImage

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum QRCodeGenerator {
    /// Generates a crisp QR code bitmap from an arbitrary string payload (e.g. `tg://login?token=...`).
    /// Uses native CoreImage CIQRCodeGenerator with zero third-party dependencies.
    static func generate(from string: String, scale: CGFloat = 10) -> PlatformImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputCIImage = filter.outputImage else { return nil }

        // Scale up using nearest-neighbor transform so the pixel blocks remain pin-sharp
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaledCIImage = outputCIImage.transformed(by: transform)

        #if canImport(AppKit)
        let rep = NSCIImageRep(ciImage: scaledCIImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
        #elseif canImport(UIKit)
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledCIImage, from: scaledCIImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
        #endif
    }
}

/// A SwiftUI view that renders a QR code on a styled, high-contrast card.
struct QRCodeCardView: View {
    let content: String
    var size: CGFloat = 200

    init(content: String, size: CGFloat = 200) {
        self.content = content
        self.size = size
    }

    public var body: some View {
        Group {
            if let image = QRCodeGenerator.generate(from: content) {
                #if canImport(AppKit)
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                #elseif canImport(UIKit)
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                #endif
            } else {
                ProgressView()
            }
        }
        .frame(width: size, height: size)
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 16, x: 0, y: 6)
    }
}
