#if os(macOS)
import AppKit
import Libavformat
import Libavcodec
import Libavutil
import Libswscale
import os

/// Extracts a representative (non-black) frame from a local video file using the
/// bundled FFmpeg libraries directly (libavformat + libavcodec + libswscale) —
/// no window, no GL, no AVFoundation, no image encoders needed.
///
/// Why this exists: video thumbnails used to come from QuickLook, which always
/// picks the FIRST frame — typically a black title card. A window-based capture
/// through the app's mpv renderer worked in the user's context but depended on a
/// composited WindowServer surface, which automation-launched processes don't get
/// (GL_FRAMEBUFFER_UNDEFINED → black frames). Direct FFmpeg decode is fully
/// headless, deterministic, and verifiable from any launch context.
///
/// Strategy (per the 2026-08-15 consult with Claude/Deepseek/Grok/ChatGPT/Qwen):
/// sample several candidate positions, score each decoded frame's luma variance
/// (a black card scores ~0), keep the richest frame, convert it to RGBA with
/// swscale (colorspace-aware), rotate per display matrix, and let AppKit encode.
enum VideoFrameExtractor {
    private static let logger = Logger(subsystem: "com.cascade.app", category: "thumbnail")

    /// Candidate positions as fractions of duration. The first few percent of
    /// most videos are credits or bumpers, so sampling starts at 8% and spreads.
    private static let candidateFractions: [Double] = [0.08, 0.15, 0.25, 0.40, 0.60]

    /// Cap on decoded packets per candidate (a seek landing far from a keyframe
    /// must never hang extraction).
    private static let maxPacketsPerSeek = 600

    /// Output width cap for the final thumbnail source (aspect preserved).
    private static let maxOutputWidth = 1280

    /// Network I/O bound: avformat has no timeout by default, so an open on the
    /// loopback stream server that never answers blocks forever. rw_timeout also
    /// bounds every later read (headers, slices, seeks) — extraction fails
    /// cleanly and the caller falls back to Telegram's attached thumbnail.
    private static let networkTimeoutMicros = "15000000"

    /// Extraction must never touch the main thread: FFmpeg's open/read blocks
    /// (poll) with no deadline, and a frozen main thread freezes the app. A plain
    /// `Task.detached` body has empirically run on the creating thread in this
    /// runtime (completeTaskWithClosure on com.apple.main-thread), so hop to a
    /// dedicated queue explicitly. The semaphore caps concurrent extractions so
    /// a grid re-key (e.g. after a cache purge) can't start an unbounded FFmpeg
    /// stampede.
    private static let extractionQueue = DispatchQueue(label: "com.cascade.thumbnail-extract", qos: .utility)
    private static let extractionSlots = DispatchSemaphore(value: 2)

    // MARK: - Public API

    /// Returns a representative frame from `url`, or nil if the file has no
    /// decodable video track (callers fall back to QuickLook in that case).
    /// Never runs on the main thread and never blocks longer than the network
    /// timeout — pure C work, no UI involvement.
    static func representativeFrame(from url: URL) async -> NSImage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                extractionQueue.async {
                    extractionSlots.wait()
                    defer { extractionSlots.signal() }
                    continuation.resume(returning: extract(url: url))
                }
            }
        } onCancel: {
            // The C decode can't be interrupted safely; the network timeout and
            // the single-flight gate in ThumbnailService bound the fallout.
        }
    }

    // MARK: - Pipeline

    private static func extract(url: URL) -> NSImage? {
        let isRemote = url.scheme == "http" || url.scheme == "https"
        let path = isRemote ? url.absoluteString : url.path(percentEncoded: false)
        if !isRemote, !FileManager.default.fileExists(atPath: path) { return nil }

        let ext = url.pathExtension.lowercased()
        let isAudio = ["mp3", "m4a", "flac", "wav", "aac", "ogg", "wma", "aiff", "opus", "alac", "dsf", "ape"].contains(ext)

        // 1. Pure-Swift embedded artwork parser for local audio files (0ms, no FFmpeg decode overhead)
        if !isRemote, isAudio, let art = AudioArtworkParser.extractArtwork(from: url) {
            return art
        }

        var fmt: UnsafeMutablePointer<AVFormatContext>? = nil
        var options: OpaquePointer? = nil
        if isRemote {
            // No timeout in avformat by default — a silent loopback stream server
            // (or any stalled connection) would make open/read block forever.
            av_dict_set(&options, "rw_timeout", networkTimeoutMicros, 0)
            av_dict_set(&options, "timeout", networkTimeoutMicros, 0)
        }
        defer { if options != nil { av_dict_free(&options) } }
        guard path.withCString({ avformat_open_input(&fmt, $0, nil, &options) }) >= 0,
              let fmtCtx = fmt else {
            logger.warning("thumbnail: cannot open \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        defer { avformat_close_input(&fmt) }

        guard avformat_find_stream_info(fmtCtx, nil) >= 0 else { return nil }

        // 2. Check for attached pictures across all streams (embedded album art in MP3, FLAC, M4A, OGG, etc.)
        if let streams = fmtCtx.pointee.streams {
            for i in 0..<Int(fmtCtx.pointee.nb_streams) {
                guard let st = streams[i] else { continue }
                if (st.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0 || st.pointee.attached_pic.size > 0 {
                    let pkt = st.pointee.attached_pic
                    if pkt.size > 0, let bytes = pkt.data {
                        let data = Data(bytes: bytes, count: Int(pkt.size))
                        if let image = NSImage(data: data) {
                            return image
                        }
                    }
                }
            }
        }

        var codec: UnsafePointer<AVCodec>? = nil
        let videoIdx = av_find_best_stream(fmtCtx, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0)
        guard videoIdx >= 0, let codec, let streams = fmtCtx.pointee.streams,
              let stream = streams[Int(videoIdx)], let codecpar = stream.pointee.codecpar else {
            return nil
        }

        var dec: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(codec)
        guard let decCtx = dec else { return nil }
        defer { avcodec_free_context(&dec) }
        guard avcodec_parameters_to_context(decCtx, codecpar) >= 0,
              avcodec_open2(decCtx, codec, nil) >= 0 else {
            return nil
        }
        // Best-effort timestamps become meaningful with the real timebase set.
        decCtx.pointee.pkt_timebase = stream.pointee.time_base

        let duration = mediaDuration(fmt: fmtCtx, stream: stream)
        if duration <= 0.05 || isAudio {
            // Single-frame cover art or audio stream: decode frame 0 without seeking
            if let decoded = decodeFirstFrame(fmt: fmtCtx, dec: decCtx, streamIndex: Int32(videoIdx)) {
                var frame: UnsafeMutablePointer<AVFrame>? = decoded
                defer { av_frame_free(&frame) }
                if let rgba = convertToRGBA(frame: decoded) {
                    return image(fromRGBA: rgba, rotationDegrees: displayRotation(frame: decoded))
                }
            }
            return nil
        }

        // Sample each candidate; keep the frame with the most visual content.
        var bestFrame: UnsafeMutablePointer<AVFrame>? = nil
        var bestScore = -1.0
        var usedTarget = 0.0

        var targets = candidateFractions.map { Swift.min(duration - 0.5, duration * $0) }
            .filter { $0 > 0.3 }
        // Very short videos: every fraction collapses below the guard — fall back
        // to a mid-video position so we still return something.
        if targets.isEmpty {
            targets = [Swift.max(0.05, duration * 0.3)]
        }

        for target in targets {
            guard let decoded = decodeFrame(at: target, fmt: fmtCtx, dec: decCtx,
                                            streamIndex: Int32(videoIdx), stream: stream) else { continue }
            var frame: UnsafeMutablePointer<AVFrame>? = decoded
            let score = lumaVariance(decoded)
            if score > bestScore {
                av_frame_free(&bestFrame)
                bestFrame = frame
                bestScore = score
                usedTarget = target
            } else {
                av_frame_free(&frame)
            }
        }

        guard let winner = bestFrame else {
            logger.warning("thumbnail: no frame decoded for \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        defer { av_frame_free(&bestFrame) }
        logger.log("thumbnail: \(url.lastPathComponent, privacy: .public) frame @\(String(format: "%.1f", usedTarget), privacy: .public)s variance \(String(format: "%.1f", bestScore), privacy: .public)")

        // Convert the winner to RGBA (colorspace-aware), rotate, build the image.
        guard let rgba = convertToRGBA(frame: winner) else { return nil }
        return image(fromRGBA: rgba, rotationDegrees: displayRotation(frame: winner))
    }

    /// Stream duration in seconds (stream timebase preferred, container fallback).
    private static func mediaDuration(
        fmt: UnsafeMutablePointer<AVFormatContext>,
        stream: UnsafeMutablePointer<AVStream>
    ) -> Double {
        if stream.pointee.duration != Int64.min, stream.pointee.duration > 0 {
            return Double(stream.pointee.duration) * av_q2d(stream.pointee.time_base)
        }
        if fmt.pointee.duration != Int64.min, fmt.pointee.duration > 0 {
            return Double(fmt.pointee.duration) / Double(AV_TIME_BASE)
        }
        return 0
    }

    /// Seeks to a keyframe at/before `targetSeconds` and decodes forward to the
    /// first frame at or after it. Caller owns the returned frame.
    private static func decodeFrame(
        at targetSeconds: Double,
        fmt: UnsafeMutablePointer<AVFormatContext>,
        dec: UnsafeMutablePointer<AVCodecContext>,
        streamIndex: Int32,
        stream: UnsafeMutablePointer<AVStream>
    ) -> UnsafeMutablePointer<AVFrame>? {
        let timebase = stream.pointee.time_base
        let targetTs = Int64((targetSeconds / av_q2d(timebase)).rounded())

        if av_seek_frame(fmt, streamIndex, targetTs, AVSEEK_FLAG_BACKWARD) < 0 { return nil }
        avcodec_flush_buffers(dec)

        var pkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        var scratch: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let pktPtr = pkt, let scratchPtr = scratch else {
            av_packet_free(&pkt)
            av_frame_free(&scratch)
            return nil
        }
        defer {
            av_packet_free(&pkt)
            av_frame_free(&scratch)
        }

        var lastDecoded: UnsafeMutablePointer<AVFrame>? = nil
        var packets = 0
        while packets < maxPacketsPerSeek, av_read_frame(fmt, pktPtr) >= 0 {
            packets += 1
            defer { av_packet_unref(pktPtr) }
            guard pktPtr.pointee.stream_index == streamIndex else { continue }

            if avcodec_send_packet(dec, pktPtr) == 0 {
                while avcodec_receive_frame(dec, scratchPtr) == 0 {
                    var ts = scratchPtr.pointee.best_effort_timestamp
                    if ts == Int64.min { ts = scratchPtr.pointee.pts }
                    if ts != Int64.min && ts >= targetTs {
                        av_frame_free(&lastDecoded)
                        return av_frame_clone(scratchPtr)
                    }
                    av_frame_free(&lastDecoded)
                    lastDecoded = av_frame_clone(scratchPtr)
                }
            }
        }
        return lastDecoded
    }

    /// Decodes the very first video/picture packet without seeking (for audio embedded art).
    private static func decodeFirstFrame(
        fmt: UnsafeMutablePointer<AVFormatContext>,
        dec: UnsafeMutablePointer<AVCodecContext>,
        streamIndex: Int32
    ) -> UnsafeMutablePointer<AVFrame>? {
        avcodec_flush_buffers(dec)
        var pkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        var scratch: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let pktPtr = pkt, let scratchPtr = scratch else {
            av_packet_free(&pkt)
            av_frame_free(&scratch)
            return nil
        }
        defer {
            av_packet_free(&pkt)
            av_frame_free(&scratch)
        }

        var packets = 0
        while packets < 50, av_read_frame(fmt, pktPtr) >= 0 {
            packets += 1
            defer { av_packet_unref(pktPtr) }
            guard pktPtr.pointee.stream_index == streamIndex else { continue }

            if avcodec_send_packet(dec, pktPtr) == 0 {
                while avcodec_receive_frame(dec, scratchPtr) == 0 {
                    return av_frame_clone(scratchPtr)
                }
            }
        }
        return nil
    }

    /// Luma variance over a coarse sample of the decoded frame's Y plane
    /// (plane 0 for planar YUV; a rich image scores high, a black card ~0).
    private static func lumaVariance(_ frame: UnsafeMutablePointer<AVFrame>) -> Double {
        let w = frame.pointee.width
        let h = frame.pointee.height
        let planes = framePlanes(frame)
        let strides = frameStrides(frame)
        guard w > 0, h > 0, let plane0 = planes[0], strides[0] > 0 else { return -1 }

        var sum = 0.0
        var sumSq = 0.0
        var n = 0.0
        let rowStride = Int(strides[0])
        var y = 0
        while y < h {
            let row = plane0.advanced(by: y * rowStride)
            var x = 0
            while x < w {
                let luma = Double(row[x])
                sum += luma
                sumSq += luma * luma
                n += 1
                x += 4
            }
            y += 4
        }
        guard n > 0 else { return -1 }
        let mean = sum / n
        return max(0, sumSq / n - mean * mean)
    }

    /// Converts the frame to RGBA (top-down), colorspace-aware, capped width.
    private static func convertToRGBA(frame: UnsafeMutablePointer<AVFrame>) -> (data: UnsafeMutablePointer<UInt8>, width: Int, height: Int, rowBytes: Int)? {
        let srcW = frame.pointee.width
        let srcH = frame.pointee.height
        let srcFmtRaw = frame.pointee.format          // imports as Int32 in this build
        guard srcW > 0, srcH > 0, srcFmtRaw != AV_PIX_FMT_NONE.rawValue else { return nil }
        let srcFmt = AVPixelFormat(rawValue: srcFmtRaw) ?? AV_PIX_FMT_NONE

        let scaleF = Swift.min(1.0, Double(maxOutputWidth) / Double(srcW))
        let dstW = Swift.max(2, Int((Double(srcW) * scaleF).rounded()))
        let dstH = Swift.max(2, Int((Double(srcH) * scaleF).rounded()))
        let rowBytes = dstW * 4

        guard let sws = sws_getContext(srcW, srcH, srcFmt, Int32(dstW), Int32(dstH),
                                       AV_PIX_FMT_RGBA, Int32(SWS_BILINEAR.rawValue), nil, nil, nil) else { return nil }
        defer { sws_freeContext(sws) }

        // Colorspace/range: never trust swscale's BT.601 default for HD content.
        let srcCs = frame.pointee.colorspace           // AVColorSpace (rawValue is UInt32)
        let inCoeffs = sws_getCoefficients(Int32((srcCs == AVCOL_SPC_UNSPECIFIED ? AVCOL_SPC_BT709 : srcCs).rawValue))
        let srcRange: Int32 = frame.pointee.color_range == AVCOL_RANGE_JPEG ? 1 : 0
        sws_setColorspaceDetails(sws, inCoeffs, srcRange,
                                 sws_getCoefficients(Int32(AVCOL_SPC_BT709.rawValue)), 1,
                                 Int32(0), Int32(1 << 16), Int32(1 << 16))

        let planes = framePlanes(frame)
        let strides = frameStrides(frame)
        var srcPlanes = [UnsafePointer<UInt8>?](repeating: nil, count: 4)
        var srcStrides = [Int32](repeating: 0, count: 4)
        for i in 0..<4 {
            if let p = planes[i] { srcPlanes[i] = UnsafePointer(p) }
            srcStrides[i] = strides[i]
        }

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: rowBytes * dstH)
        defer { buf.deallocate() }

        var dstPlanes: [UnsafeMutablePointer<UInt8>?] = [buf]
        var dstStrides: [Int32] = [Int32(rowBytes)]

        let ok = srcPlanes.withUnsafeBufferPointer { sp in
            srcStrides.withUnsafeBufferPointer { ss in
                dstPlanes.withUnsafeMutableBufferPointer { dp in
                    dstStrides.withUnsafeMutableBufferPointer { ds in
                        sws_scale(sws, sp.baseAddress, ss.baseAddress, 0, srcH,
                                  dp.baseAddress, ds.baseAddress) >= 0
                    }
                }
            }
        }
        guard ok else { return nil }

        // Copy out (the temp buffer is deallocated above).
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: rowBytes * dstH)
        memcpy(out, buf, rowBytes * dstH)
        return (out, dstW, dstH, rowBytes)
    }

    /// Display rotation from the decoded frame's display matrix (phone videos),
    /// falling back to the legacy `rotate` stream metadata.
    private static func displayRotation(frame: UnsafeMutablePointer<AVFrame>) -> Double {
        if let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_DISPLAYMATRIX),
           let data = sd.pointee.data {
            var angle = av_display_rotation_get(UnsafeRawPointer(data).assumingMemoryBound(to: Int32.self))
            if angle.isNaN { angle = 0 }
            angle = angle.truncatingRemainder(dividingBy: 360)
            if angle < 0 { angle += 360 }
            return angle
        }
        return 0
    }

    /// Builds the final NSImage from a top-down RGBA buffer, applying rotation.
    private static func image(fromRGBA rgba: (data: UnsafeMutablePointer<UInt8>, width: Int, height: Int, rowBytes: Int),
                              rotationDegrees: Double) -> NSImage? {
        let raw = rgba.data
        defer { raw.deallocate() }

        var pixels = [UInt8](repeating: 0, count: rgba.rowBytes * rgba.height)
        pixels.withUnsafeMutableBytes { dst in
            memcpy(dst.baseAddress!, raw, rgba.rowBytes * rgba.height)
        }

        let rot = Int(rotationDegrees.rounded()) % 360
        var data = Data(pixels)
        var w = rgba.width
        var h = rgba.height
        if rot == 90 || rot == 270 {
            let rotated = rotateQuarter(pixels, width: w, height: h, rowBytes: rgba.rowBytes, clockwise: rot == 90)
            data = Data(rotated)
            swap(&w, &h)
        } else if rot == 180 {
            let rotated = rotate180(pixels, width: w, height: h, rowBytes: rgba.rowBytes)
            data = Data(rotated)
        }

        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: w * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    // MARK: - C-array helpers (FFmpeg fixed arrays import as tuples)

    private static func framePlanes(_ frame: UnsafeMutablePointer<AVFrame>) -> [UnsafeMutablePointer<UInt8>?] {
        withUnsafePointer(to: frame.pointee.data) { ptr in
            ptr.withMemoryRebound(to: UnsafeMutablePointer<UInt8>?.self, capacity: 8) { p in
                Array(UnsafeBufferPointer(start: p, count: 8))
            }
        }
    }

    private static func frameStrides(_ frame: UnsafeMutablePointer<AVFrame>) -> [Int32] {
        withUnsafePointer(to: frame.pointee.linesize) { ptr in
            ptr.withMemoryRebound(to: Int32.self, capacity: 8) { p in
                Array(UnsafeBufferPointer(start: p, count: 8))
            }
        }
    }

    private static func rotate180(_ src: [UInt8], width: Int, height: Int, rowBytes: Int) -> [UInt8] {
        var dst = [UInt8](repeating: 0, count: src.count)
        for y in 0..<height {
            for x in 0..<width {
                let s = y * rowBytes + x * 4
                let d = (height - 1 - y) * rowBytes + (width - 1 - x) * 4
                dst[d] = src[s]; dst[d + 1] = src[s + 1]; dst[d + 2] = src[s + 2]; dst[d + 3] = src[s + 3]
            }
        }
        return dst
    }

    private static func rotateQuarter(_ src: [UInt8], width: Int, height: Int, rowBytes: Int, clockwise: Bool) -> [UInt8] {
        // Output is (height x width) with its own row bytes.
        let outRowBytes = height * 4
        var dst = [UInt8](repeating: 0, count: outRowBytes * width)
        for y in 0..<height {
            for x in 0..<width {
                let s = y * rowBytes + x * 4
                let d: Int
                if clockwise {
                    d = x * outRowBytes + (height - 1 - y) * 4
                } else {
                    d = (width - 1 - x) * outRowBytes + y * 4
                }
                dst[d] = src[s]; dst[d + 1] = src[s + 1]; dst[d + 2] = src[s + 2]; dst[d + 3] = src[s + 3]
            }
        }
        return dst
    }
}
#endif
