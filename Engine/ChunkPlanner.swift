import Foundation

struct ChunkPlanItem: Sendable, Equatable {
    let index: Int
    let offset: Int64
    let size: Int64
}

struct ChunkPlan: Sendable, Equatable {
    let totalSize: Int64
    let chunkSize: Int64
    let items: [ChunkPlanItem]

    var count: Int { items.count }
}

enum ChunkProfile: String, Sendable {
    case automatic
    case streaming
    case archive
}

enum ChunkPlanner {
    static let byteMiB: Int64 = 1024 * 1024

    /// Safety margin below Telegram's per-file limit.
    static let maxSafeChunkSize: Int64 = 1_900 * byteMiB

    static let streamingChunkSize: Int64 = 64 * byteMiB
    static let standardChunkSize: Int64 = 256 * byteMiB
    static let archiveChunkSize: Int64 = 512 * byteMiB
    static let hugeFileThreshold: Int64 = 50_000 * byteMiB

    static func isMedia(mime: String) -> Bool {
        mime.hasPrefix("video/") || mime.hasPrefix("audio/")
    }

    static func chunkSize(
        for fileSize: Int64,
        profile: ChunkProfile,
        mime: String
    ) -> Int64 {
        var size: Int64
        switch profile {
        case .streaming:
            size = streamingChunkSize
        case .archive:
            size = archiveChunkSize
        case .automatic:
            if isMedia(mime: mime) {
                size = streamingChunkSize
            } else if fileSize > hugeFileThreshold {
                size = archiveChunkSize
            } else {
                size = standardChunkSize
            }
        }
        return min(size, maxSafeChunkSize)
    }

    static func plan(
        fileSize: Int64,
        profile: ChunkProfile = .automatic,
        mime: String = ""
    ) -> ChunkPlan {
        let chunkSize = chunkSize(for: fileSize, profile: profile, mime: mime)

        guard fileSize > 0 else {
            return ChunkPlan(totalSize: 0, chunkSize: chunkSize, items: [])
        }

        var items: [ChunkPlanItem] = []
        var offset: Int64 = 0
        var index = 0

        while offset < fileSize {
            let remaining = fileSize - offset
            let size = min(chunkSize, remaining)
            items.append(ChunkPlanItem(index: index, offset: offset, size: size))
            offset += size
            index += 1
        }

        return ChunkPlan(totalSize: fileSize, chunkSize: chunkSize, items: items)
    }
}
