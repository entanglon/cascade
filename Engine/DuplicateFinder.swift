import Foundation

/// Wave 2 item 7 — Duplicate finder math: group vault files by CONTENT identity
/// (`rootHash` = SHA-256 of the plaintext, set on every upload since hashing
/// landed). Pure functions over the loaded catalog so the rules are unit-
/// testable. Deletion itself goes through AppState.deleteForever so every
/// safety rail (channel messages, backup mirror, share revocation, tombstones,
/// checkpoint republish) fires exactly like a manual delete.
enum DuplicateFinder {

    struct Group: Identifiable {
        /// The shared content hash — also the group's identity.
        let id: String
        /// Duplicates sorted OLDEST FIRST (the natural "original").
        let files: [ObjectRecord]

        var keepCandidateID: String { files.first?.id ?? "" }
        /// Bytes wasted by every copy beyond the one being kept (for the
        /// current selection).
        func wastedBytes(keeping objectID: String) -> Int64 {
            files.filter { $0.id != objectID }.reduce(0) { $0 + max(0, $1.size) }
        }
    }

    /// All duplicate sets among active files: same non-empty rootHash, two or
    /// more members. Trashed/tombstoned/folders/hashless objects never appear;
    /// archived/private copies DO (they hold real bytes worth reclaiming).
    static func groups(in objects: [ObjectRecord]) -> [Group] {
        let candidates = objects.filter {
            !$0.isFolder && !$0.trashed && $0.tombstoneAt == nil
                && $0.state == "ready"
                && !($0.rootHash ?? "").isEmpty
        }
        let grouped = Dictionary(grouping: candidates, by: { $0.rootHash ?? "" })
        return grouped.values
            .filter { $0.count > 1 }
            .map { members in
                Group(
                    id: members[0].rootHash ?? "",
                    files: members.sorted {
                        $0.createdAt == $1.createdAt
                            ? $0.name < $1.name
                            : $0.createdAt < $1.createdAt
                    }
                )
            }
            .sorted { $0.files.count > $1.files.count }
    }

    /// Total bytes reclaimable across every group with the given selections
    /// (groupID → objectID to keep; missing entries keep the oldest copy).
    static func totalReclaimable(groups: [Group], keeping: [String: String]) -> Int64 {
        groups.reduce(0) { sum, group in
            sum + group.wastedBytes(keeping: keeping[group.id] ?? group.keepCandidateID)
        }
    }
}