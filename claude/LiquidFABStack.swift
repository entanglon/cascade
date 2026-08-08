//
//  LiquidFABStack.swift
//  xCloud
//
//  Primary renderer: native Liquid Glass, macOS 26 (Tahoe)+. Two circular
//  glass views share a namespace via .glassEffectID inside one
//  GlassEffectContainer, which handles the actual metaball-style blend as
//  they move within `spacing` of each other. This gets you real optical
//  lensing/specular response for free — try this first before reaching for
//  the Metal/SDF fallback in MetaballGlassStack.swift.
//
//  CAVEAT: exactly how much choreographic control you get over the "neck"
//  during separation (a visible stretch-then-thin, vs. a simpler cross-
//  blend) isn't fully pinned down from documentation alone — confirm in a
//  live Xcode 26 canvas before committing to this as your only renderer.
//  If you need tighter control than the container gives you, fall back to
//  MetaballGlassStack, which exposes the neck softness directly.
//

import SwiftUI

@available(macOS 26.0, *)
struct LiquidFABStack: View {
    @ObservedObject var coordinator: TransferCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var fabNamespace

    // Local mirror of "is the transfer blob visually present," kept separate
    // from coordinator.phase so we control exactly when the spring fires and
    // can attach a completion handler back into the state machine.
    @State private var transferBlobVisible = false

    private let addButtonSize: CGFloat = 56
    private let transferButtonSize: CGFloat = 48
    private let restingGap: CGFloat = 16

    var body: some View {
        GlassEffectContainer(spacing: reduceMotion ? 0 : 40) {
            VStack(spacing: transferBlobVisible ? restingGap : 0) {
                if transferBlobVisible {
                    transferButton
                        .glassEffectID("transfers", in: fabNamespace)
                }
                addButton
                    .glassEffectID("add", in: fabNamespace)
            }
        }
        .onChange(of: coordinator.phase) { _, newPhase in
            handle(newPhase)
        }
        .onAppear { handle(coordinator.phase) }
    }

    private func handle(_ phase: TransferPhase) {
        switch phase {
        case .hidden:
            transferBlobVisible = false

        case .materializing:
            let spring: Animation = reduceMotion
                ? .easeInOut(duration: 0.18)
                : .spring(response: 0.5, dampingFraction: 0.72)
            withAnimation(spring, completionCriteria: .logicallyComplete) {
                transferBlobVisible = true
            } completion: {
                coordinator.settle()
            }

        case .dematerializing:
            let spring: Animation = reduceMotion
                ? .easeInOut(duration: 0.18)
                : .spring(response: 0.45, dampingFraction: 0.8)
            withAnimation(spring, completionCriteria: .logicallyComplete) {
                transferBlobVisible = false
            } completion: {
                coordinator.hide()
            }

        case .active, .error:
            transferBlobVisible = true
        }
    }

    private var addButton: some View {
        Button {
            // present the Add menu (import files / new folder / new private folder)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: addButtonSize, height: addButtonSize)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }

    private var transferButton: some View {
        Button {
            // toggle MiniTransfersView popover
        } label: {
            TransferDropContent(phase: coordinator.phase)
                .frame(width: transferButtonSize, height: transferButtonSize)
        }
        .buttonStyle(.plain)
        .glassEffect(glassStyle, in: .circle)
    }

    private var glassStyle: Glass {
        switch coordinator.phase {
        case .error:
            return .regular.tint(.red.opacity(0.35)).interactive()
        default:
            return .regular.tint(.blue.opacity(0.22)).interactive()
        }
    }
}
