//
//  DimensionToolState.swift
//  DWGViewer / Editing
//
//  Interactive state machine for the DIMENSION tool (linear/aligned):
//  3-click AutoCAD DIMLINEAR/DIMALIGNED gesture — pick first extension-line
//  origin, pick second, then pick where the dimension line itself sits
//  (with a live preview) — mirrors `OffsetToolState`'s "phase enum + isActive
//  + reset-for-next" shape.
//

import Foundation
import CoreGraphics

enum DimensionPhase: Equatable {
    case idle
    case pickFirstPoint
    case pickSecondPoint
    case pickDimensionLinePlacement
}

struct DimensionToolState: Equatable {
    var kind: DimensionKind = .aligned
    var phase: DimensionPhase = .idle
    var firstPoint: CGPoint? = nil
    var secondPoint: CGPoint? = nil
    /// Live cursor position, tracked for the on-canvas preview (mirrors
    /// every other multi-click tool's own `hover`).
    var hover: CGPoint? = nil
    var snap: SnapResult? = nil

    var isActive: Bool { phase != .idle }

    static func begin(kind: DimensionKind) -> DimensionToolState {
        var state = DimensionToolState()
        state.kind = kind
        state.phase = .pickFirstPoint
        return state
    }

    mutating func withFirstPoint(_ p: CGPoint) {
        firstPoint = p
        phase = .pickSecondPoint
    }

    mutating func withSecondPoint(_ p: CGPoint) {
        secondPoint = p
        phase = .pickDimensionLinePlacement
    }

    /// Resets back to the start of a NEW dimension using the SAME kind —
    /// DIMENSION repeats until Esc, matching OFFSET's own "distance/mode
    /// fixed, object picking repeats" convention and every other drafting
    /// tool in this app (LINE, CIRCLE, etc. all stay active for the next
    /// shape after committing one).
    mutating func resetForNext() {
        firstPoint = nil
        secondPoint = nil
        phase = .pickFirstPoint
    }

    var prompt: String {
        let kindLabel = kind == .aligned ? "DIMENSION (Aligned)" : "DIMENSION (Linear)"
        switch phase {
        case .idle:
            return ""
        case .pickFirstPoint:
            return "\(kindLabel) — specify first extension line origin"
        case .pickSecondPoint:
            return "\(kindLabel) — specify second extension line origin"
        case .pickDimensionLinePlacement:
            return "\(kindLabel) — specify dimension line location"
        }
    }
}
