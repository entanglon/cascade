//
//  MetaballGlassStack.swift
// Cascade
//
//  Fallback renderer for pre-macOS-26 targets, or for when you want tighter
//  choreographic control over the neck than GlassEffectContainer's
//  automatic morph gives you. Both blobs are rendered as ONE shader-masked
//  glass layer, driven by a single MorphGeometry value — never two
//  independently-styled glass circles (glass shouldn't sample glass).
//
//  Requires Metaball.metal to be included in the target's Metal library, and
//  the icon/percentage content in TransferDropContent.swift.
//

import SwiftUI

struct MetaballGlassStack: View {
    @ObservedObject var coordinator: TransferCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let addRadius: CGFloat = 28
    private let transferRadius: CGFloat = 24
    private let neckSoftness: Float = 22
    private let edgeSoftness: Float = 1.2
    private let canvasSize = CGSize(width: 96, height: 200)

    @State private var geometry = MorphGeometry.merged

    var body: some View {
        ZStack {
            glassLayer
            contentLayer
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .onChange(of: coordinator.phase) { _, newPhase in
            handle(newPhase)
        }
        .onAppear { handle(coordinator.phase) }
    }

    // MARK: Glass + mask

    private var glassLayer: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(specularHighlight)
            .colorEffect(
                ShaderLibrary.metaballMask(
                    .float2(Float(addBlobCenter.x), Float(addBlobCenter.y)),
                    .float(Float(addRadius - geometry.addRadiusPinch)),
                    .float2(Float(transferBlobCenter.x), Float(transferBlobCenter.y)),
                    .float(Float(geometry.transferRadius)),
                    .float(neckSoftness),
                    .float(edgeSoftness)
                )
            )
            .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }

    private var specularHighlight: some View {
        LinearGradient(
            colors: [.white.opacity(0.35), .white.opacity(0.05), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .blendMode(.overlay)
    }

    // MARK: Content, positioned to match the shader geometry

    private var contentLayer: some View {
        ZStack {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .position(addBlobCenter)

            if geometry.transferRadius > transferRadius * 0.6 {
                TransferDropContent(phase: coordinator.phase)
                    .frame(width: transferRadius * 2, height: transferRadius * 2)
                    .position(transferBlobCenter)
                    .opacity(contentOpacity)
            }
        }
    }

    /// Fade the icon/percentage in only once the blob is round enough to
    /// legibly hold it — avoids content looking squashed inside a still-
    /// narrow bridge shape early in the materialize morph.
    private var contentOpacity: Double {
        Double(min(max((geometry.transferRadius / transferRadius - 0.6) / 0.4, 0), 1))
    }

    private var addBlobCenter: CGPoint {
        CGPoint(x: canvasSize.width / 2, y: canvasSize.height - addRadius - 12)
    }

    private var transferBlobCenter: CGPoint {
        CGPoint(x: canvasSize.width / 2, y: addBlobCenter.y + geometry.transferOffsetY)
    }

    // MARK: State machine hookup

    private func handle(_ phase: TransferPhase) {
        switch phase {
        case .hidden:
            geometry = .merged

        case .materializing:
            let spring: Animation = reduceMotion
                ? .easeInOut(duration: 0.18)
                : .spring(response: 0.5, dampingFraction: 0.68)
            withAnimation(spring, completionCriteria: .logicallyComplete) {
                geometry = .separated(restingRadius: transferRadius)
            } completion: {
                coordinator.settle()
            }

        case .dematerializing:
            let spring: Animation = reduceMotion
                ? .easeInOut(duration: 0.18)
                : .spring(response: 0.42, dampingFraction: 0.85)
            withAnimation(spring, completionCriteria: .logicallyComplete) {
                geometry = .merged
            } completion: {
                coordinator.hide()
            }

        case .active, .error:
            geometry = .separated(restingRadius: transferRadius)
        }
    }
}
