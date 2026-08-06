import Foundation
import os

enum ChunkEngineError: Error, Sendable {
    case planMismatch
}

enum ChunkEngine {
    private static let logger = Logger(
        subsystem: "com.xcloud.app",
        category: "engine"
    )

    static func analyze(
        fileURL: URL,
        profile: ChunkProfile = .automatic
    ) throws -> (plan: ChunkPlan, rootHash: String) {
        let attrs = try FileManager.default
            .attributesOfItem(atPath: fileURL.path(percentEncoded: false))
        guard let num = attrs[.size] as? NSNumber else {
            throw HashingError.unreadableFile
        }
        let plan = ChunkPlanner.plan(fileSize: num.int64Value, profile: profile)
        let rootHash = try FileHasher.sha256(of: fileURL)
        return (plan, rootHash)
    }

    static func selfTest() async throws {
        try runSelfTest()
    }

    private static func runSelfTest() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("xcloud-selftest", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("sample.bin")
        let path = fileURL.path(percentEncoded: false)

        if fm.fileExists(atPath: path) {
            try fm.removeItem(at: fileURL)
        }
        fm.createFile(atPath: path, contents: nil)

        let handle = try FileHandle(forWritingTo: fileURL)
        let block = Data(count: 1024 * 1024)
        for _ in 0..<100 {
            try handle.write(contentsOf: block)
        }
        try handle.close()

        let plan = ChunkPlanner.plan(
            fileSize: 100 * 1024 * 1024,
            profile: .streaming
        )
        guard plan.items.count == 2,
              plan.items[0].size == 64 * 1024 * 1024,
              plan.items[1].size == 36 * 1024 * 1024,
              plan.items.reduce(0, { $0 + $1.size }) == plan.totalSize
        else { throw ChunkEngineError.planMismatch }

        for item in plan.items {
            _ = try FileHasher.sha256(
                ofRange: fileURL,
                offset: item.offset,
                length: item.size
            )
        }

        let root = try FileHasher.sha256(of: fileURL)
        guard root.count == 64 else { throw ChunkEngineError.planMismatch }

        let big = ChunkPlanner.plan(fileSize: 10_000_000_000, profile: .automatic)
        guard big.items.reduce(0, { $0 + $1.size }) == big.totalSize,
              big.items.allSatisfy({ $0.size <= ChunkPlanner.maxSafeChunkSize })
        else { throw ChunkEngineError.planMismatch }

        try fm.removeItem(at: dir)

        let short = String(root.prefix(12))
        logger.info(
            "Chunk engine self-test passed: \(plan.items.count) chunks, root=\(short, privacy: .public)…"
        )
    }
}
