import Foundation
import CryptoKit

enum HashingError: Error, Sendable {
    case unreadableFile
}

extension Digest {
    nonisolated var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

enum FileHasher {
    static let bufferSize = 4 * 1024 * 1024

    /// Streaming SHA-256 of a whole file (never loads it into memory).
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let data = try handle.read(upToCount: bufferSize),
                  !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().hexString
    }

    /// SHA-256 of raw data.
    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).hexString
    }

    /// SHA-256 of a byte range inside a file — used per chunk.
    static func sha256(ofRange url: URL, offset: Int64, length: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        var hasher = SHA256()
        var remaining = length
        while remaining > 0 {
            let toRead = Int(min(Int64(bufferSize), remaining))
            guard let data = try handle.read(upToCount: toRead),
                  !data.isEmpty else { break }
            hasher.update(data: data)
            remaining -= Int64(data.count)
        }
        return hasher.finalize().hexString
    }
}
