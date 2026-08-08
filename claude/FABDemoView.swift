//
//  FABDemoView.swift
//  xCloud
//
//  Drop into an Xcode preview to see either renderer in action without
//  wiring up real transfers yet. The buttons simulate starting/finishing
//  uploads so you can test exactly the cases discussed alongside this code:
//  rapid start/stop thrash, multiple simultaneous transfers, and the error
//  path.
//

import SwiftUI

struct FABDemoView: View {
    @StateObject private var coordinator = TransferCoordinator()
    @State private var activeIDs: [UUID] = []

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Group {
                if #available(macOS 26.0, *) {
                    LiquidFABStack(coordinator: coordinator)
                } else {
                    MetaballGlassStack(coordinator: coordinator)
                }
            }
            .frame(width: 96, height: 200)

            Spacer()

            controls
                .padding(.bottom, 24)
        }
        .frame(width: 360, height: 480)
        .background(.gray.opacity(0.15))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button("Start Transfer") {
                let id = UUID()
                activeIDs.append(id)
                coordinator.start(id: id)
                simulateProgress(for: id)
            }

            Button("Start 3 Rapidly") {
                for _ in 0..<3 {
                    let id = UUID()
                    activeIDs.append(id)
                    coordinator.start(id: id)
                    simulateProgress(for: id)
                }
            }

            Button("Fail Active Transfer") {
                guard let id = activeIDs.first else { return }
                coordinator.fail(id: id)
            }

            Button("Start + Finish Instantly (thrash test)") {
                let id = UUID()
                coordinator.start(id: id)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    coordinator.finish(id: id)
                }
            }
        }
        .buttonStyle(.bordered)
    }

    private func simulateProgress(for id: UUID) {
        Task { @MainActor in
            var progress = 0.0
            while progress < 1 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                progress += Double.random(in: 0.05...0.15)
                coordinator.update(id: id, progress: min(progress, 1))
            }
            coordinator.finish(id: id)
            activeIDs.removeAll { $0 == id }
        }
    }
}

#Preview {
    FABDemoView()
}
