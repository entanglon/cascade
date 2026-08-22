import SwiftUI

/// Wave 2 item 7 — Duplicate finder review sheet: every set of vault files
/// sharing one content hash, with a keep-selection per group and one-tap
/// cleanup ("keep one · delete the rest"). Deletion goes through
/// `AppState.deleteForever` so shares die, channel + backup messages are
/// removed, tombstones land, and a fresh checkpoint publishes — identical to
/// deleting by hand.
struct DuplicatesReviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var groups: [DuplicateFinder.Group] = []
    /// groupID → objectID the user chose to KEEP (default: oldest copy).
    @State private var keeping: [String: String] = [:]
    @State private var isWorking = false
    @State private var processedCount = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.1))

            if groups.isEmpty && processedCount == 0 {
                emptyState
            } else if groups.isEmpty {
                doneState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        summary
                        ForEach(groups) { group in
                            groupCard(group)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                }
            }
        }
        .frame(width: 560, height: 560)
        .background(AppBackground())
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .task {
            reload()
        }
    }

    // MARK: - Pieces

    private var reclaimable: Int64 {
        DuplicateFinder.totalReclaimable(groups: groups, keeping: keeping)
    }

    private func reload() {
        let found = DuplicateFinder.groups(in: appState.files)
        groups = found
        keeping = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0.keepCandidateID) })
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicate Finder")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(XTheme.textPrimary)
                Text("Files with identical content — keep one, reclaim the rest.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.on.square")
                .foregroundStyle(XTheme.accent)
            Text("\(groups.count) duplicate set\(groups.count == 1 ? "" : "s") · \(XTheme.formatBytes(reclaimable)) reclaimable")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }

    private func groupCard(_ group: DuplicateFinder.Group) -> some View {
        let keepID = keeping[group.id] ?? group.keepCandidateID
        let wasted = group.wastedBytes(keeping: keepID)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(group.files.count) copies")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button {
                    cleanUp(group: group, keepID: keepID)
                } label: {
                    Text(isWorking ? "Working…" : "Keep 1 · Delete \(group.files.count - 1) (\(XTheme.formatBytes(wasted)))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(wasted > 0 ? XTheme.accent : Color.gray.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(isWorking || wasted <= 0)
            }

            ForEach(group.files) { file in
                duplicateRow(file: file, isKeep: file.id == keepID, groupID: group.id)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func duplicateRow(file: ObjectRecord, isKeep: Bool, groupID: String) -> some View {
        let location = appState.files.first { $0.id == file.parentID }?.name ?? "All Files"
        return Button {
            keeping[groupID] = file.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isKeep ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isKeep ? XTheme.accent : .white.opacity(0.35))
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name)
                        .font(.system(size: 13, weight: isKeep ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(isKeep ? 1 : 0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(location) · added \(file.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isKeep ? XTheme.accent.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(XTheme.accent)
            Text("No duplicates found")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text("Every file has unique content. New scans run each time you open this window.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var doneState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 34))
                .foregroundStyle(XTheme.accent)
            Text("Cleaned up \(processedCount) cop\(processedCount == 1 ? "y" : "ies")")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Capsule().fill(XTheme.accent))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func cleanUp(group: DuplicateFinder.Group, keepID: String) {
        let doomed = group.files.filter { $0.id != keepID }
        guard !doomed.isEmpty else { return }
        isWorking = true
        Task {
            await appState.deleteForever(doomed)
            processedCount += doomed.count
            groups.removeAll { $0.id == group.id }
            isWorking = false
        }
    }
}