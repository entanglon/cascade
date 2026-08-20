import AppKit
import Foundation

/// Fast, pure-Swift parser for embedded album artwork in audio files (MP3 ID3v2,
/// M4A/MP4 `covr`, and FLAC `METADATA_BLOCK_PICTURE`), plus a high-res artwork
/// generator for audio files without embedded art.
///
/// Fully headless, zero-AVFoundation, zero-QuickLook dependency.
enum AudioArtworkParser {
    /// Extracts embedded album artwork from a local audio file URL, or returns nil
    /// if the file contains no embedded artwork.
    static func extractArtwork(from url: URL) -> NSImage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp3":
            return parseID3v2(handle: handle)
        case "m4a", "mp4", "aac", "alac":
            return parseMP4(handle: handle)
        case "flac":
            return parseFLAC(handle: handle)
        default:
            // Try ID3v2 then MP4 then FLAC as fallbacks
            if let img = parseID3v2(handle: handle) { return img }
            try? handle.seek(toOffset: 0)
            if let img = parseMP4(handle: handle) { return img }
            try? handle.seek(toOffset: 0)
            return parseFLAC(handle: handle)
        }
    }

    /// Generates a rich 640x640 album artwork disc for audio files that have no
    /// embedded artwork (e.g. voice memos, sound effects), so every audio file
    /// has a high-res preview permanently attached to Telegram and cacheable on disk.
    static func defaultAudioArtwork(title: String) -> NSImage? {
        let size = CGSize(width: 640, height: 640)
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 1. Rich dark gradient background
        let colors = [
            NSColor(red: 0.10, green: 0.10, blue: 0.18, alpha: 1.0).cgColor,
            NSColor(red: 0.05, green: 0.05, blue: 0.09, alpha: 1.0).cgColor
        ] as CFArray
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: size.height),
                end: CGPoint(x: size.width, y: 0),
                options: []
            )
        }

        // 2. Vinyl disc background
        let discRect = CGRect(x: 40, y: 40, width: 560, height: 560)
        ctx.setFillColor(NSColor(white: 0.08, alpha: 1.0).cgColor)
        ctx.fillEllipse(in: discRect)

        // 3. Concentric groove rings
        ctx.setStrokeColor(NSColor(white: 0.16, alpha: 0.7).cgColor)
        ctx.setLineWidth(1.5)
        for inset in stride(from: CGFloat(20), to: CGFloat(150), by: CGFloat(14)) {
            ctx.strokeEllipse(in: discRect.insetBy(dx: inset, dy: inset))
        }

        // 4. Center label with accent gradient
        let labelRect = CGRect(x: 200, y: 200, width: 240, height: 240)
        let labelColors = [
            NSColor(red: 0.90, green: 0.35, blue: 0.55, alpha: 1.0).cgColor,
            NSColor(red: 0.45, green: 0.20, blue: 0.85, alpha: 1.0).cgColor
        ] as CFArray
        if let labelGrad = CGGradient(colorsSpace: colorSpace, colors: labelColors, locations: [0.0, 1.0]) {
            ctx.saveGState()
            ctx.addEllipse(in: labelRect)
            ctx.clip()
            ctx.drawLinearGradient(
                labelGrad,
                start: CGPoint(x: 200, y: 440),
                end: CGPoint(x: 440, y: 200),
                options: []
            )
            ctx.restoreGState()
        }

        // Center spindle hole
        let holeRect = CGRect(x: 300, y: 300, width: 40, height: 40)
        ctx.setFillColor(NSColor(white: 0.05, alpha: 1.0).cgColor)
        ctx.fillEllipse(in: holeRect)
        ctx.setStrokeColor(NSColor(white: 0.3, alpha: 0.8).cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: holeRect)

        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 640, height: 640))
    }

    // MARK: - MP3 ID3v2 Parser

    private static func parseID3v2(handle: FileHandle) -> NSImage? {
        try? handle.seek(toOffset: 0)
        guard let header = try? handle.read(upToCount: 10), header.count == 10 else { return nil }
        guard header[0] == 0x49, header[1] == 0x44, header[2] == 0x33 else { return nil } // "ID3"

        let version = header[3]
        guard version == 2 || version == 3 || version == 4 else { return nil }

        let tagSize = (Int(header[6]) << 21) | (Int(header[7]) << 14) | (Int(header[8]) << 7) | Int(header[9])
        guard tagSize > 0 else { return nil }

        // Read the tag body (capped at 16 MB to prevent OOM on corrupt files)
        let readLen = min(tagSize, 16 * 1024 * 1024)
        guard let tagData = try? handle.read(upToCount: readLen), !tagData.isEmpty else { return nil }

        var offset = 0
        let isV22 = (version == 2)
        let headerSize = isV22 ? 6 : 10

        while offset + headerSize < tagData.count {
            let frameID: String
            let frameSize: Int

            if isV22 {
                frameID = String(decoding: tagData[offset..<offset+3], as: UTF8.self)
                frameSize = (Int(tagData[offset+3]) << 16) | (Int(tagData[offset+4]) << 8) | Int(tagData[offset+5])
                offset += 6
            } else {
                frameID = String(decoding: tagData[offset..<offset+4], as: UTF8.self)
                if version == 4 {
                    // ID3v2.4 syncsafe integer
                    frameSize = (Int(tagData[offset+4]) << 21) | (Int(tagData[offset+5]) << 14) | (Int(tagData[offset+6]) << 7) | Int(tagData[offset+7])
                } else {
                    // ID3v2.3 regular 32-bit int
                    frameSize = (Int(tagData[offset+4]) << 24) | (Int(tagData[offset+5]) << 16) | (Int(tagData[offset+6]) << 8) | Int(tagData[offset+7])
                }
                offset += 10
            }

            guard frameSize > 0, offset + frameSize <= tagData.count else { break }

            if frameID == "APIC" || frameID == "PIC" {
                let frameData = tagData.subdata(in: offset..<offset+frameSize)
                if let image = extractImageFromAPIC(frameData: frameData, isV22: isV22) {
                    return image
                }
            }

            offset += frameSize
        }

        return nil
    }

    private static func extractImageFromAPIC(frameData: Data, isV22: Bool) -> NSImage? {
        guard frameData.count > 10 else { return nil }

        // Find magic bytes for JPEG (FF D8 FF) or PNG (89 50 4E 47)
        let bytes = [UInt8](frameData)
        for i in 0..<(bytes.count - 4) {
            if bytes[i] == 0xFF && bytes[i+1] == 0xD8 && bytes[i+2] == 0xFF {
                let imgData = frameData.subdata(in: i..<frameData.count)
                if let image = NSImage(data: imgData) { return image }
            } else if bytes[i] == 0x89 && bytes[i+1] == 0x50 && bytes[i+2] == 0x4E && bytes[i+3] == 0x47 {
                let imgData = frameData.subdata(in: i..<frameData.count)
                if let image = NSImage(data: imgData) { return image }
            }
        }
        return nil
    }

    // MARK: - M4A / MP4 Parser

    private static func parseMP4(handle: FileHandle) -> NSImage? {
        try? handle.seek(toOffset: 0)
        guard let data = try? handle.read(upToCount: 8 * 1024 * 1024), data.count > 16 else { return nil }
        return searchAtomsForCover(data: data, start: 0, end: data.count)
    }

    private static func searchAtomsForCover(data: Data, start: Int, end: Int) -> NSImage? {
        var offset = start
        while offset + 8 <= end {
            let size = Int(data[offset]) << 24 | Int(data[offset+1]) << 16 | Int(data[offset+2]) << 8 | Int(data[offset+3])
            guard size >= 8, offset + size <= end else { break }

            let name = String(decoding: data[offset+4..<offset+8], as: UTF8.self)
            if name == "moov" || name == "udta" || name == "ilst" {
                if let found = searchAtomsForCover(data: data, start: offset + 8, end: offset + size) {
                    return found
                }
            } else if name == "meta" {
                // meta atom has 4 bytes version/flags before child atoms
                if offset + 12 <= offset + size {
                    if let found = searchAtomsForCover(data: data, start: offset + 12, end: offset + size) {
                        return found
                    }
                }
            } else if name == "covr" {
                // Inside covr atom: look for data atom
                var covrOffset = offset + 8
                while covrOffset + 8 <= offset + size {
                    let childSize = Int(data[covrOffset]) << 24 | Int(data[covrOffset+1]) << 16 | Int(data[covrOffset+2]) << 8 | Int(data[covrOffset+3])
                    guard childSize >= 8, covrOffset + childSize <= offset + size else { break }
                    let childName = String(decoding: data[covrOffset+4..<covrOffset+8], as: UTF8.self)
                    if childName == "data" {
                        // data atom header: 4 bytes size, 4 bytes 'data', 4 bytes type, 4 bytes locale = 16 bytes
                        if childSize > 16 {
                            let imgData = data.subdata(in: (covrOffset + 16)..<(covrOffset + childSize))
                            if let image = NSImage(data: imgData) {
                                return image
                            }
                        }
                    }
                    covrOffset += childSize
                }
            }

            offset += size
        }
        return nil
    }

    // MARK: - FLAC Parser

    private static func parseFLAC(handle: FileHandle) -> NSImage? {
        try? handle.seek(toOffset: 0)
        guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return nil }
        guard header[0] == 0x66, header[1] == 0x4C, header[2] == 0x61, header[3] == 0x43 else { return nil } // "fLaC"

        var isLast = false
        while !isLast {
            guard let blockHeader = try? handle.read(upToCount: 4), blockHeader.count == 4 else { break }
            isLast = (blockHeader[0] & 0x80) != 0
            let blockType = blockHeader[0] & 0x7F
            let blockSize = (Int(blockHeader[1]) << 16) | (Int(blockHeader[2]) << 8) | Int(blockHeader[3])

            if blockType == 6 { // PICTURE block
                guard let blockData = try? handle.read(upToCount: blockSize), blockData.count == blockSize else { break }
                // Parse picture block:
                // 4 bytes: picture type
                // 4 bytes: MIME length
                var pos = 4
                guard pos + 4 <= blockData.count else { break }
                let mimeLen = (Int(blockData[pos]) << 24) | (Int(blockData[pos+1]) << 16) | (Int(blockData[pos+2]) << 8) | Int(blockData[pos+3])
                pos += 4 + mimeLen

                // 4 bytes: desc length
                guard pos + 4 <= blockData.count else { break }
                let descLen = (Int(blockData[pos]) << 24) | (Int(blockData[pos+1]) << 16) | (Int(blockData[pos+2]) << 8) | Int(blockData[pos+3])
                pos += 4 + descLen

                // 16 bytes: width(4), height(4), depth(4), colors(4)
                pos += 16

                // 4 bytes: data length
                guard pos + 4 <= blockData.count else { break }
                let dataLen = (Int(blockData[pos]) << 24) | (Int(blockData[pos+1]) << 16) | (Int(blockData[pos+2]) << 8) | Int(blockData[pos+3])
                pos += 4

                guard pos + dataLen <= blockData.count else { break }
                let imgData = blockData.subdata(in: pos..<pos+dataLen)
                if let image = NSImage(data: imgData) {
                    return image
                }
            } else {
                guard let cur = try? handle.offset() else { break }
                try? handle.seek(toOffset: cur + UInt64(blockSize))
            }
        }
        return nil
    }
}
