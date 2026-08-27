#if os(macOS)
import AppKit
import Foundation
import ImageIO

/// Pure-Swift, zero-AVFoundation embedded album artwork extractor for audio files
/// (MP3 ID3v2, M4A/MP4/AAC `covr`, and FLAC `METADATA_BLOCK_PICTURE`).
///
/// Fast, robust atom/tag seeking — skips multi-gigabyte `mdat` blocks in 0ms
/// and verifies image validity via ImageIO.
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
        case "m4a", "mp4", "aac", "alac", "m4b", "m4p":
            return parseMP4(handle: handle)
        case "flac":
            return parseFLAC(handle: handle)
        default:
            if let img = parseID3v2(handle: handle) { return img }
            try? handle.seek(toOffset: 0)
            if let img = parseMP4(handle: handle) { return img }
            try? handle.seek(toOffset: 0)
            return parseFLAC(handle: handle)
        }
    }

    // MARK: - Validation

    private static func imageFromData(_ data: Data) -> NSImage? {
        guard data.count > 32 else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: - MP3 ID3v2 Parser

    private static func parseID3v2(handle: FileHandle) -> NSImage? {
        try? handle.seek(toOffset: 0)
        guard let header = try? handle.read(upToCount: 10), header.count == 10 else { return nil }
        guard header[0] == 0x49, header[1] == 0x44, header[2] == 0x33 else { return nil } // "ID3"

        let version = header[3]
        guard version >= 2 && version <= 4 else { return nil }

        let tagSize = (Int(header[6] & 0x7F) << 21) |
                      (Int(header[7] & 0x7F) << 14) |
                      (Int(header[8] & 0x7F) << 7)  |
                      Int(header[9] & 0x7F)
        guard tagSize > 0 else { return nil }

        let readLen = min(tagSize, 32 * 1024 * 1024)
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
                    frameSize = (Int(tagData[offset+4] & 0x7F) << 21) |
                                (Int(tagData[offset+5] & 0x7F) << 14) |
                                (Int(tagData[offset+6] & 0x7F) << 7)  |
                                Int(tagData[offset+7] & 0x7F)
                } else {
                    frameSize = (Int(tagData[offset+4]) << 24) |
                                (Int(tagData[offset+5]) << 16) |
                                (Int(tagData[offset+6]) << 8)  |
                                Int(tagData[offset+7])
                }
                offset += 10
            }

            guard frameSize > 0, offset + frameSize <= tagData.count else { break }

            if frameID == "APIC" || frameID == "PIC" {
                let frameData = tagData.subdata(in: offset..<offset+frameSize)
                if let image = extractImageFromPayload(frameData) {
                    return image
                }
            }

            offset += frameSize
        }

        // Fallback: Scan entire ID3 tag data for embedded JPEG or PNG magic bytes
        return extractImageFromPayload(tagData)
    }

    private static func extractImageFromPayload(_ data: Data) -> NSImage? {
        guard data.count > 32 else { return nil }
        let bytes = [UInt8](data)
        let count = bytes.count

        for i in 0..<(count - 8) {
            // JPEG: FF D8 FF
            if bytes[i] == 0xFF && bytes[i+1] == 0xD8 && bytes[i+2] == 0xFF {
                let sub = data.subdata(in: i..<count)
                if let img = imageFromData(sub) { return img }
            }
            // PNG: 89 50 4E 47 0D 0A 1A 0A
            else if bytes[i] == 0x89 && bytes[i+1] == 0x50 && bytes[i+2] == 0x4E && bytes[i+3] == 0x47 {
                let sub = data.subdata(in: i..<count)
                if let img = imageFromData(sub) { return img }
            }
        }
        return nil
    }

    // MARK: - M4A / MP4 Parser

    private static func parseMP4(handle: FileHandle) -> NSImage? {
        guard let fileSize = try? handle.seekToEnd(), fileSize > 16 else { return nil }
        try? handle.seek(toOffset: 0)
        return scanMP4Atoms(handle: handle, start: 0, length: Int(fileSize))
    }

    private static func scanMP4Atoms(handle: FileHandle, start: UInt64, length: Int) -> NSImage? {
        var offset = start
        let end = start + UInt64(length)

        while offset + 8 <= end {
            try? handle.seek(toOffset: offset)
            guard let hdr = try? handle.read(upToCount: 8), hdr.count == 8 else { break }

            var atomSize = UInt64(UInt32(hdr[0]) << 24 | UInt32(hdr[1]) << 16 | UInt32(hdr[2]) << 8 | UInt32(hdr[3]))
            var headerSize: UInt64 = 8
            let atomType = String(decoding: hdr[4..<8], as: UTF8.self)

            if atomSize == 1 {
                // 64-bit large size
                guard let extHdr = try? handle.read(upToCount: 8), extHdr.count == 8 else { break }
                atomSize = UInt64(extHdr[0]) << 56 | UInt64(extHdr[1]) << 48 |
                           UInt64(extHdr[2]) << 40 | UInt64(extHdr[3]) << 32 |
                           UInt64(extHdr[4]) << 24 | UInt64(extHdr[5]) << 16 |
                           UInt64(extHdr[6]) << 8  | UInt64(extHdr[7])
                headerSize = 16
            } else if atomSize == 0 {
                atomSize = end - offset
            }

            guard atomSize >= headerSize, offset + atomSize <= end else { break }

            if atomType == "moov" || atomType == "udta" || atomType == "ilst" {
                if let found = scanMP4Atoms(handle: handle, start: offset + headerSize, length: Int(atomSize - headerSize)) {
                    return found
                }
            } else if atomType == "meta" {
                // meta atom has 4 bytes version/flags before children
                let metaHdr: UInt64 = headerSize + 4
                if atomSize > metaHdr {
                    if let found = scanMP4Atoms(handle: handle, start: offset + metaHdr, length: Int(atomSize - metaHdr)) {
                        return found
                    }
                }
            } else if atomType == "covr" {
                // Inside covr: search for data atom
                var covrOffset = offset + headerSize
                let covrEnd = offset + atomSize
                while covrOffset + 8 <= covrEnd {
                    try? handle.seek(toOffset: covrOffset)
                    guard let childHdr = try? handle.read(upToCount: 8), childHdr.count == 8 else { break }
                    let childSize = UInt64(UInt32(childHdr[0]) << 24 | UInt32(childHdr[1]) << 16 | UInt32(childHdr[2]) << 8 | UInt32(childHdr[3]))
                    let childType = String(decoding: childHdr[4..<8], as: UTF8.self)

                    guard childSize >= 8, covrOffset + childSize <= covrEnd else { break }

                    if childType == "data" {
                        // data atom: 8 bytes header + 8 bytes (type indicator & locale) = 16 bytes prefix
                        let payloadSize = Int(childSize - 16)
                        if payloadSize > 16 {
                            try? handle.seek(toOffset: covrOffset + 16)
                            if let payload = try? handle.read(upToCount: payloadSize),
                               let img = imageFromData(payload) {
                                return img
                            }
                        }
                    }
                    covrOffset += childSize
                }
            }

            offset += atomSize
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
                var pos = 4 // skip picture type (4)
                guard pos + 4 <= blockData.count else { break }
                let mimeLen = Int(UInt32(blockData[pos]) << 24 | UInt32(blockData[pos+1]) << 16 | UInt32(blockData[pos+2]) << 8 | UInt32(blockData[pos+3]))
                pos += 4 + mimeLen

                guard pos + 4 <= blockData.count else { break }
                let descLen = Int(UInt32(blockData[pos]) << 24 | UInt32(blockData[pos+1]) << 16 | UInt32(blockData[pos+2]) << 8 | UInt32(blockData[pos+3]))
                pos += 4 + descLen

                pos += 16 // width, height, depth, colors

                guard pos + 4 <= blockData.count else { break }
                let dataLen = Int(UInt32(blockData[pos]) << 24 | UInt32(blockData[pos+1]) << 16 | UInt32(blockData[pos+2]) << 8 | UInt32(blockData[pos+3]))
                pos += 4

                guard pos + dataLen <= blockData.count else { break }
                let imgData = blockData.subdata(in: pos..<pos+dataLen)
                if let img = imageFromData(imgData) {
                    return img
                }
            } else {
                guard let cur = try? handle.offset() else { break }
                try? handle.seek(toOffset: cur + UInt64(blockSize))
            }
        }
        return nil
    }
}
#endif
