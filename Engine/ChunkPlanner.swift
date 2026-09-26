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

    /// Uniform chunk size for ALL content: ~1.9 GiB, safely under Telegram's
    /// 2 GB per-document limit. Rationale: TDLib resumes uploads/downloads at
    /// internal part granularity from its persistent database (so a failed giant
    /// chunk costs only its unfinished tail), and every message-count metric —
    /// uploads, backup forwards, share-pool forwards, repair scans — scales with
    /// chunk COUNT. Chunk size is a storage-layout concern only: streaming is
    /// byte-range and slices through chunk documents without ever waiting for a
    /// full one.
    ///
    /// Streaming slices are fixed at 1 MiB (SliceMath.sliceSize) and are
    /// independent of chunk size — but the 1.9 GiB value predates the plaintext
    /// era and is retained for catalog stability with existing uploads.
    static let maxSafeChunkSize: Int64 = 1_900 * byteMiB

    @available(*, deprecated, message: "Uniform chunking supersedes per-profile sizes")
    static let streamingChunkSize: Int64 = maxSafeChunkSize
    @available(*, deprecated, message: "Uniform chunking supersedes per-profile sizes")
    static let standardChunkSize: Int64 = maxSafeChunkSize
    @available(*, deprecated, message: "Uniform chunking supersedes per-profile sizes")
    static let archiveChunkSize: Int64 = maxSafeChunkSize
    @available(*, deprecated, message: "Uniform chunking supersedes per-profile sizes")
    static let hugeFileThreshold: Int64 = 50_000 * byteMiB

    static func isMedia(mime: String) -> Bool {
        mime.hasPrefix("video/") || mime.hasPrefix("audio/")
    }

    static func chunkSize(
        for fileSize: Int64,
        profile: ChunkProfile,
        mime: String
    ) -> Int64 {
        // Uniform by design; profile/mime parameters retained for API stability.
        return maxSafeChunkSize
    }

    static func plan(
        fileSize: Int64,
        profile: ChunkProfile = .automatic,
        mime: String = "",
        chunkSize: Int64? = nil
    ) -> ChunkPlan {
        // A stored chunk size (set at upload time) wins over the profile constants so a
        // resumed upload always re-derives the exact same chunk boundaries — even if the
        // global constants change between versions.
        let effectiveChunkSize = chunkSize ?? ChunkPlanner.chunkSize(for: fileSize, profile: profile, mime: mime)

        guard fileSize > 0 else {
            return ChunkPlan(totalSize: 0, chunkSize: effectiveChunkSize, items: [])
        }

        var items: [ChunkPlanItem] = []
        var offset: Int64 = 0
        var index = 0

        while offset < fileSize {
            let remaining = fileSize - offset
            let size = min(effectiveChunkSize, remaining)
            items.append(ChunkPlanItem(index: index, offset: offset, size: size))
            offset += size
            index += 1
        }

        return ChunkPlan(totalSize: fileSize, chunkSize: effectiveChunkSize, items: items)
    }
}
