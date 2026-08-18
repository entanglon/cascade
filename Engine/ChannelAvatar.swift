import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Generates branded profile pictures for xCloud's Telegram channels (vault,
/// backup, public, private pool slots) so they're recognizable in the chat
/// list and on t.me link previews. Pure local drawing — no assets, no network.
enum ChannelAvatar {

    /// Draws a 640×640 square avatar: diagonal gradient in a per-family hue
    /// with the label centered in bold white. TDLib's static chat photos must
    /// be JPEG, so the result is written as JPEG to a cache file keyed by
    /// label (reused on every call — generating is cheap, so no invalidation
    /// logic is needed).
    static func makeJPEG(label: String, hue: Double) -> URL? {
        let size = 640
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let top = hsb(h: hue, s: 0.55, b: 0.60)
        let bottom = hsb(h: (hue + 0.10).truncatingRemainder(dividingBy: 1.0), s: 0.62, b: 0.32)
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: [top, bottom] as CFArray, locations: [0, 1]) else { return nil }
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: CGFloat(size), y: CGFloat(size)),
            options: []
        )

        drawLabel(label, in: ctx, size: size)

        guard let image = ctx.makeImage() else { return nil }
        guard let url = cacheURL(for: label) else { return nil }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return url
    }

    // MARK: - Drawing helpers

    private static func hsb(h: CGFloat, s: CGFloat, b: CGFloat) -> CGColor {
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [h, s, b, 1])!
            .converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)!
            .copy(alpha: 1)!
    }

    /// Draws the label centered, scaled so it never exceeds ~62% of the square.
    private static func drawLabel(_ label: String, in ctx: CGContext, size: Int) {
        var fontSize: CGFloat = 230
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        var textSize = (label as NSString).size(withAttributes: attributes)
        let maxWidth = CGFloat(size) * 0.62
        while textSize.width > maxWidth {
            fontSize *= 0.88
            attributes[.font] = NSFont.systemFont(ofSize: fontSize, weight: .bold)
            textSize = (label as NSString).size(withAttributes: attributes)
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
        ctx.textPosition = CGPoint(
            x: (CGFloat(size) - textSize.width) / 2,
            y: (CGFloat(size) - textSize.height) / 2
        )
        ctx.setShadow(offset: .zero, blur: 12, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        CTLineDraw(line, ctx)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }

    /// Cache file for a label: `<tmp>/xcloud-avatars/<label>.jpg`.
    private static func cacheURL(for label: String) -> URL? {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xcloud-avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(label).appendingPathExtension("jpg")
    }
}