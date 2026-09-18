//
//  CurveBridge.swift
//  DWGViewer / Geometry
//
//  The ONLY file in Sources/DWGViewer/Geometry that may import CoreGraphics.
//  Provides CGPoint <-> Vec2 bridging conveniences for callers elsewhere in
//  the app. Intentionally minimal — not wired into any existing app code by
//  this phase; that integration belongs to later modification-command work.
//

import CoreGraphics

extension Vec2 {
    public init(_ p: CGPoint) {
        self.init(Double(p.x), Double(p.y))
    }

    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

/// Associates a resolved `Curve2` with the polyline segment index it came
/// from, when the source entity was a `BulgePolyline` (nil for standalone
/// curves that aren't part of a polyline).
public struct CurveRef {
    public let curve: Curve2
    public let polySegmentIndex: Int?

    public init(curve: Curve2, polySegmentIndex: Int?) {
        self.curve = curve
        self.polySegmentIndex = polySegmentIndex
    }
}
