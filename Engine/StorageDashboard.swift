import Foundation

/// Wave 2 item 6 — Storage Dashboard math: recursive per-folder usage and the
/// biggest files in the vault. Pure functions over the loaded catalog so the
/// decision-free arithmetic is unit-testable (cycles, trash filtering…).
enum StorageDashboard {

    /// One row per FOLDER with its recursive subtree byte total (the folder's
    /// own files plus every descendant folder's files). Trashed objects are
    /// excluded everywhere; archived/private files still count (they occupy
    /// real vault bytes). Cycles in the parent graph are tolerated — a folder
    /// caught in a cycle simply stops recursing instead of looping forever.
    static func folderSubtreeSizes(_ objects: [ObjectRecord]) -> [String: Int64] {
        let active = objects.filter { !$0.trashed && $0.tombstoneAt == nil }
        var directFileBytes: [String: Int64] = [:]
        for file in active where !file.isFolder {
            directFileBytes[file.parentID ?? "", default: 0] += max(0, file.size)
        }
        let childFolders = Dictionary(grouping: active.filter(\.isFolder), by: { $0.parentID ?? "" })

        var memo: [String: Int64] = [:]
        var visiting: Set<String> = []

        func size(of folder: ObjectRecord) -> Int64 {
            if let cached = memo[folder.id] { return cached }
            guard visiting.insert(folder.id).inserted else { return 0 } // cycle guard
            defer { visiting.remove(folder.id) }
            var sum = directFileBytes[folder.id] ?? 0
            for child in childFolders[folder.id] ?? [] {
                sum += size(of: child)
            }
            memo[folder.id] = sum
            return sum
        }

        for folder in active where folder.isFolder {
            _ = size(of: folder)
        }
        return memo
    }

    /// The N heaviest non-trashed files, descending.
    static func largestFiles(_ objects: [ObjectRecord], limit: Int = 8) -> [ObjectRecord] {
        objects
            .filter { !$0.isFolder && !$0.trashed && $0.tombstoneAt == nil && $0.size > 0 }
            .sorted { $0.size > $1.size }
            .prefix(limit)
            .map { $0 }
    }

    /// Total vault bytes across every active file.
    static func totalBytes(_ objects: [ObjectRecord]) -> Int64 {
        objects
            .filter { !$0.isFolder && !$0.trashed && $0.tombstoneAt == nil }
            .reduce(0) { $0 + max(0, $1.size) }
    }
}