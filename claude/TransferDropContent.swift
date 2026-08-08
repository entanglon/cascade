//
//  TransferDropContent.swift
//  xCloud
//
//  The icon + percentage + liquid-fill content drawn inside the Transfers
//  blob once it's fully separated. Shared by both the native Liquid Glass
//  renderer and the Metal/SDF fallback renderer.
//

import SwiftUI

struct TransferDropContent: View {
    let phase: TransferPhase

    var body: some View {
        ZStack {
            liquidFill
            VStack(spacing: 2) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .bold))
                if let percentText {
                    Text(percentText)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                }
            }
            .foregroundStyle(.white)
        }
        .clipShape(Circle())
        .animation(.easeOut(duration: 0.3), value: progressValue)
    }

    private var progressValue: Double {
        switch phase {
        case .active(_, let progress): return progress
        case .error: return 1
        default: return 0
        }
    }

    private var iconName: String {
        switch phase {
        case .error: return "exclamationmark"
        default: return "arrow.up.arrow.down"
        }
    }

    private var percentText: String? {
        guard case .active(_, let progress) = phase else { return nil }
        return "\(Int(progress * 100))%"
    }

    /// A plain rising rectangle, clipped by the circle above it. Deliberately
    /// NOT wired through the metaball SDF — this view is only ever shown
    /// once the blob is a plain circle (phase == .active/.error), so a
    /// GeometryReader + rectangle is sufficient and far cheaper than
    /// re-deriving the fill boundary from the mask shader every frame.
    private var liquidFill: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(fillColor.opacity(0.85))
                .frame(height: proxy.size.height * progressValue)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var fillColor: Color {
        switch phase {
        case .error: return .red
        default: return .blue
        }
    }
}
