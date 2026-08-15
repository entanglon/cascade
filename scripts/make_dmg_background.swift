// make_dmg_background.swift
// Renders the xCloud DMG background (660x400) matching the app's dark navy theme.
// Usage: swift make_dmg_background.swift <icon.png> <output.png>
// Coordinate system is bottom-left origin, matching dmgbuild's icon_locations.

import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: make_dmg_background.swift <icon.png> <output.png>")
    exit(1)
}
let iconPath = args[1]
let outputPath = args[2]

let width: CGFloat = 660
let height: CGFloat = 400

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width),
    pixelsHigh: Int(height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .calibratedRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    print("failed to create bitmap rep")
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    print("failed to create graphics context")
    exit(1)
}
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high

let rect = NSRect(x: 0, y: 0, width: width, height: height)

// ---- Base vertical gradient (#10131c -> #171b28 -> #1e2434) ----
let base = NSGradient(colors: [
    NSColor(calibratedRed: 0.063, green: 0.075, blue: 0.110, alpha: 1.0), // #10131c
    NSColor(calibratedRed: 0.090, green: 0.106, blue: 0.157, alpha: 1.0), // #171b28
    NSColor(calibratedRed: 0.118, green: 0.141, blue: 0.204, alpha: 1.0)  // #1e2434
])!
base.draw(in: rect, angle: -90)

// ---- Radial glow behind the icon row ----
let glowCenter = NSPoint(x: width / 2, y: 125)
let glowRadius: CGFloat = 300
let glow = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.30, blue: 0.62, alpha: 0.35),
    NSColor(calibratedRed: 0.16, green: 0.30, blue: 0.62, alpha: 0.0)
])!
glow.draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: glowRadius, options: [.drawsBeforeStartingLocation])

// ---- Subtle top sheen ----
let sheen = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.045),
    NSColor.white.withAlphaComponent(0.0)
])!
sheen.draw(in: NSRect(x: 0, y: height - 120, width: width, height: 120), angle: -90)

// ---- Wordmark ----
func drawCentered(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let size = (text as NSString).size(withAttributes: attrs)
    (text as NSString).draw(
        at: NSPoint(x: (width - size.width) / 2, y: y),
        withAttributes: attrs
    )
}

let wordmark = NSFont.systemFont(ofSize: 46, weight: .bold)
drawCentered("xCloud", y: 318, font: wordmark, color: NSColor.white)

let tagline = NSFont.systemFont(ofSize: 13, weight: .regular)
drawCentered("Your private cloud — powered by Telegram", y: 288, font: tagline, color: NSColor(calibratedWhite: 0.62, alpha: 1.0))

// ---- Icon slots ----
// App icon slot center: (170, 125); Applications slot center: (490, 125)
let appCenter = NSPoint(x: 170, y: 125)
let appsCenter = NSPoint(x: 490, y: 125)
let slotSize: CGFloat = 112

// Applications slot: soft rounded-rect outline + folder caption
let appsRect = NSRect(x: appsCenter.x - slotSize / 2, y: appsCenter.y - slotSize / 2, width: slotSize, height: slotSize)
NSColor.white.withAlphaComponent(0.10).setStroke()
let slotPath = NSBezierPath(roundedRect: appsRect, xRadius: 24, yRadius: 24)
slotPath.lineWidth = 1.5
slotPath.stroke()

// draw a minimal folder glyph inside the applications slot
func folderGlyph(in rect: NSRect, color: NSColor) {
    let path = NSBezierPath()
    // folder body
    path.move(to: NSPoint(x: rect.minX + 8, y: rect.minY + 6))
    path.line(to: NSPoint(x: rect.minX + 34, y: rect.minY + 6))
    path.curve(to: NSPoint(x: rect.minX + 44, y: rect.minY + 16),
               controlPoint1: NSPoint(x: rect.minX + 40, y: rect.minY + 6),
               controlPoint2: NSPoint(x: rect.minX + 44, y: rect.minY + 10))
    path.line(to: NSPoint(x: rect.minX + 44, y: rect.minY + rect.height - 10))
    path.curve(to: NSPoint(x: rect.minX + rect.width - 8, y: rect.minY + rect.height - 2),
               controlPoint1: NSPoint(x: rect.minX + 44, y: rect.minY + rect.height - 6),
               controlPoint2: NSPoint(x: rect.minX + rect.width - 14, y: rect.minY + rect.height - 2))
    path.line(to: NSPoint(x: rect.minX + rect.width - 8, y: rect.minY + 20))
    path.curve(to: NSPoint(x: rect.minX + rect.width - 18, y: rect.minY + 10),
               controlPoint1: NSPoint(x: rect.minX + rect.width - 8, y: rect.minY + 14),
               controlPoint2: NSPoint(x: rect.minX + rect.width - 14, y: rect.minY + 10))
    path.line(to: NSPoint(x: rect.minX + 20, y: rect.minY + 10))
    path.line(to: NSPoint(x: rect.minX + 8, y: rect.minY + 26))
    path.close()
    color.setFill()
    path.fill()
}
folderGlyph(in: NSRect(x: appsRect.minX + 28, y: appsRect.minY + 30, width: 56, height: 50),
            color: NSColor.white.withAlphaComponent(0.30))

let appsCaption = NSFont.systemFont(ofSize: 11, weight: .medium)
let appsLabel = "Applications"
let appsLabelSize = (appsLabel as NSString).size(withAttributes: [.font: appsCaption])
(appsLabel as NSString).draw(
    at: NSPoint(x: appsCenter.x - appsLabelSize.width / 2, y: appsCenter.y - slotSize / 2 - 22),
    withAttributes: [.font: appsCaption, .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1.0)]
)

// ---- Drag arrow between the slots ----
let arrowY: CGFloat = 125
let arrowFrom = NSPoint(x: appCenter.x + slotSize / 2 + 16, y: arrowY)
let arrowTo = NSPoint(x: appsCenter.x - slotSize / 2 - 16, y: arrowY)
NSColor.white.withAlphaComponent(0.35).setStroke()
let arrow = NSBezierPath()
arrow.move(to: arrowFrom)
arrow.line(to: arrowTo)
arrow.lineWidth = 2
arrow.setLineDash([6, 6], count: 2, phase: 0)
arrow.lineCapStyle = .round
arrow.stroke()

// arrowhead
let head = NSBezierPath()
head.move(to: NSPoint(x: arrowTo.x - 10, y: arrowTo.y + 7))
head.line(to: arrowTo)
head.line(to: NSPoint(x: arrowTo.x - 10, y: arrowTo.y - 7))
head.lineWidth = 2
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

// ---- Embedded app icon art at the app slot (real icon floats over it) ----
if let icon = NSImage(contentsOfFile: iconPath) {
    let iconRect = NSRect(x: appCenter.x - slotSize / 2, y: appCenter.y - slotSize / 2, width: slotSize, height: slotSize)
    icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
}

let appCaption = NSFont.systemFont(ofSize: 11, weight: .medium)
let appLabel = "xCloud"
let appLabelSize = (appLabel as NSString).size(withAttributes: [.font: appCaption])
(appLabel as NSString).draw(
    at: NSPoint(x: appCenter.x - appLabelSize.width / 2, y: appCenter.y - slotSize / 2 - 22),
    withAttributes: [.font: appCaption, .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1.0)]
)

// ---- Bottom hint ----
drawCentered("Drag xCloud to your Applications folder", y: 34, font: NSFont.systemFont(ofSize: 12, weight: .regular), color: NSColor(calibratedWhite: 0.45, alpha: 1.0))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    print("failed to encode PNG")
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
