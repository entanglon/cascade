//
//  MorphGeometry.swift
// Cascade
//
//  A single Animatable value describing the FAB stack's blob geometry.
//  Bundling every morph parameter into ONE VectorArithmetic type keeps them
//  phase-locked under SwiftUI's spring engine. If you instead drive offset,
//  radius, and "pinch" from three separate @State vars with independent
//  withAnimation calls, an interruption (a second transfer starting mid-morph)
//  can let them drift out of sync and produce a visible stutter or seam.
//

import CoreGraphics
import SwiftUI

/// Describes how far apart, how large, and how "pinched" the two FAB blobs
/// are at a given instant. Both renderers (native Liquid Glass and the
/// Metal/SDF fallback) read from this same value.
struct MorphGeometry: Equatable {

    /// Vertical distance the Transfers blob has risen above the Add
    /// button's center, in points. 0 = fully overlapping/merged.
    /// Negative moves up (SwiftUI's Y axis increases downward).
    var transferOffsetY: CGFloat

    /// Radius of the Transfers blob, in points. 0 = not yet budded off.
    /// Can briefly exceed `restingRadius` if your spring overshoots —
    /// that's intentional, it's what gives the "springs up and settles"
    /// feel rather than a linear ease.
    var transferRadius: CGFloat

    /// How much the Add button's own radius compresses while material is
    /// "leaving" it to form the new drop, in points. Small (a few points
    /// at most), returns to 0 once the two blobs have fully separated.
    /// This is an optional embellishment — leave it 0 everywhere if you
    /// don't want the Add button to visibly react.
    var addRadiusPinch: CGFloat

    static let merged = MorphGeometry(transferOffsetY: 0, transferRadius: 0, addRadiusPinch: 0)

    static func separated(restingRadius: CGFloat) -> MorphGeometry {
        MorphGeometry(
            transferOffsetY: -(restingRadius * 2.4),
            transferRadius: restingRadius,
            addRadiusPinch: 0
        )
    }
}

// MARK: - Animatable

extension MorphGeometry: Animatable {
    // AnimatablePair only nests two values, so a third scalar is packed by
    // nesting a pair inside a pair. Order here doesn't matter functionally,
    // it just needs to round-trip through get/set consistently.
    typealias AnimatableData = AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>

    var animatableData: AnimatableData {
        get {
            AnimatablePair(transferOffsetY, AnimatablePair(transferRadius, addRadiusPinch))
        }
        set {
            transferOffsetY = newValue.first
            transferRadius = newValue.second.first
            addRadiusPinch = newValue.second.second
        }
    }
}
