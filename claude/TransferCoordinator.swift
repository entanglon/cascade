//
//  TransferCoordinator.swift
//  xCloud
//
//  Owns the set of active transfers and derives the FAB's phase from it.
//  The rule that matters most: the appear/disappear morph is triggered ONLY
//  when the active count crosses the 0 <-> nonzero boundary, never per
//  transfer. Starting a second upload while one is already running must
//  just update aggregate progress — it should never re-run the materialize
//  animation. A minimum dwell time also prevents a transfer that starts and
//  finishes within a few hundred milliseconds from causing a visible morph
//  thrash (materialize immediately followed by dematerialize).
//

import Foundation
import Combine

enum TransferPhase: Equatable {
    case hidden
    case materializing
    case active(count: Int, progress: Double)
    case dematerializing
    case error(count: Int)
}

struct TransferItem: Identifiable {
    let id: UUID
    var progress: Double // 0...1
    var failed: Bool = false
}

@MainActor
final class TransferCoordinator: ObservableObject {

    @Published private(set) var phase: TransferPhase = .hidden
    @Published private(set) var items: [TransferItem] = []

    /// Minimum time the Transfers blob stays materialized before it's
    /// allowed to start dematerializing, even if the queue empties
    /// instantly. Tune to taste; 0.5-0.8s reads as deliberate without
    /// feeling sluggish.
    private let minimumDwell: TimeInterval = 0.6

    private var materializedAt: Date?
    private var dematerializeTask: Task<Void, Never>?

    // MARK: - Intent from the transfer engine

    func start(id: UUID = UUID()) {
        dematerializeTask?.cancel()
        let wasEmpty = items.isEmpty
        items.append(TransferItem(id: id, progress: 0))
        recomputePhase(justMaterialized: wasEmpty)
    }

    func update(id: UUID, progress: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].progress = min(max(progress, 0), 1)
        recomputePhase(justMaterialized: false)
    }

    func fail(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].failed = true
        recomputePhase(justMaterialized: false)
    }

    func finish(id: UUID) {
        items.removeAll { $0.id == id }
        scheduleDematerializeIfNeeded()
    }

    // MARK: - Completion callbacks from the view's spring animations

    /// Call once the materialize spring's completion handler fires, to move
    /// from `.materializing` into steady `.active`.
    func settle() {
        guard case .materializing = phase else { return }
        phase = .active(count: items.count, progress: aggregateProgress)
    }

    /// Call once the dematerialize spring's completion handler fires.
    func hide() {
        guard case .dematerializing = phase else { return }
        phase = .hidden
        materializedAt = nil
    }

    // MARK: - Private

    private var aggregateProgress: Double {
        guard !items.isEmpty else { return 0 }
        return items.map(\.progress).reduce(0, +) / Double(items.count)
    }

    private func recomputePhase(justMaterialized: Bool) {
        if justMaterialized {
            materializedAt = Date()
            phase = .materializing
            // The view drives the actual spring and calls settle() on completion.
            return
        }
        if items.contains(where: { $0.failed }) {
            phase = .error(count: items.count)
            return
        }
        if case .materializing = phase {
            return // stay materializing until the view's spring finishes
        }
        if !items.isEmpty {
            phase = .active(count: items.count, progress: aggregateProgress)
        }
    }

    private func scheduleDematerializeIfNeeded() {
        guard items.isEmpty else {
            recomputePhase(justMaterialized: false)
            return
        }

        let elapsed = materializedAt.map { Date().timeIntervalSince($0) } ?? minimumDwell
        let remaining = max(minimumDwell - elapsed, 0)

        dematerializeTask?.cancel()
        dematerializeTask = Task { [weak self] in
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            guard let self, !Task.isCancelled, self.items.isEmpty else { return }
            self.phase = .dematerializing
        }
    }
}
