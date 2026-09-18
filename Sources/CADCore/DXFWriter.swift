import Foundation
import CoreGraphics

// NOTE: This is a trimmed CADCore extraction of NovaCAD's DXFWriter.swift.
// Only `DrawnEntity` (needed by `DXFDocument.blockStamps` / `GeometryBuilder`'s
// stamp capture) is included. The actual DXF-writing logic (the `DXFWriter`
// enum's markup export / merge-into-original-file methods) and the
// `HitTester`-dependent `boundingBox` extension are editing/UI-layer concerns
// that remain in NovaCAD (Option B extraction boundary).

/// Namespace constant kept here (rather than a full `DXFWriter` enum) because
/// `DrawnEntity.layerName` defaults to it.
public enum MarkupLayer {
    public static let name = "NOVACAD-MARKUP"
}

/// User-drawn markup entity (world coordinates).
public struct DrawnEntity: Identifiable, Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        case line(a: CGPoint, b: CGPoint)
        case polyline(pts: [CGPoint], closed: Bool)
        case circle(center: CGPoint, radius: CGFloat)
        case arc(center: CGPoint, radius: CGFloat, startDeg: Double, endDeg: Double) // CCW
        case rect(a: CGPoint, b: CGPoint)
        case text(position: CGPoint, height: CGFloat, string: String)
    }
    public let id: UUID
    public var shape: Shape
    public var aci: Int = 1                       // AutoCAD red — classic markup color
    public var layerName = MarkupLayer.name
    /// True when drawn while viewing paper space (DXF group 67).
    public var isPaper = false
    /// Entities placed together (e.g. one stamp) share a batch id so Undo
    /// removes the whole group at once.
    public var batchID: UUID? = nil

    public init(shape: Shape, aci: Int = 1, layerName: String = MarkupLayer.name,
                isPaper: Bool = false, batchID: UUID? = nil) {
        self.id = UUID()
        self.shape = shape
        self.aci = aci
        self.layerName = layerName
        self.isPaper = isPaper
        self.batchID = batchID
    }

    /// Returns a copy (same identity) translated by a world-space delta.
    public func translated(by d: CGVector) -> DrawnEntity {
        var e = self
        func t(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.dx, y: p.y + d.dy) }
        switch shape {
        case .line(let a, let b): e.shape = .line(a: t(a), b: t(b))
        case .polyline(let pts, let c): e.shape = .polyline(pts: pts.map(t), closed: c)
        case .circle(let c, let r): e.shape = .circle(center: t(c), radius: r)
        case .arc(let c, let r, let s, let en):
            e.shape = .arc(center: t(c), radius: r, startDeg: s, endDeg: en)
        case .rect(let a, let b): e.shape = .rect(a: t(a), b: t(b))
        case .text(let p, let h, let s): e.shape = .text(position: t(p), height: h, string: s)
        }
        return e
    }

    /// Returns a copy (same identity) transformed by an arbitrary conformal
    /// `Transform2` (rotation/scale/mirror) — the generalization
    /// `translated(by:)` can't express. A `.rect` (axis-aligned by
    /// construction) can't stay a `.rect` under rotation/mirror, so it
    /// degrades to the equivalent `.polyline` of its 4 transformed corners.
    public func transformed(by t: Transform2) -> DrawnEntity {
        var e = self
        func tp(_ p: CGPoint) -> CGPoint { t.apply(Vec2(p)).cgPoint }
        switch shape {
        case .line(let a, let b):
            e.shape = .line(a: tp(a), b: tp(b))
        case .polyline(let pts, let c):
            e.shape = .polyline(pts: pts.map(tp), closed: c)
        case .circle(let c, let r):
            e.shape = .circle(center: tp(c), radius: r * CGFloat(t.uniformScale))
        case .arc(let c, let r, let s, let en):
            let newCenter = tp(c)
            let newRadius = r * CGFloat(t.uniformScale)
            if t.isMirroring {
                let alpha = t.rotationAngle * 180 / .pi
                let newStart = 2 * alpha - en
                let newEnd = 2 * alpha - s
                e.shape = .arc(center: newCenter, radius: newRadius, startDeg: newStart, endDeg: newEnd)
            } else {
                let rot = t.rotationAngle * 180 / .pi
                e.shape = .arc(center: newCenter, radius: newRadius, startDeg: s + rot, endDeg: en + rot)
            }
        case .rect(let a, let b):
            let corners = [CGPoint(x: a.x, y: a.y), CGPoint(x: b.x, y: a.y),
                          CGPoint(x: b.x, y: b.y), CGPoint(x: a.x, y: b.y)].map(tp)
            e.shape = .polyline(pts: corners, closed: true)
        case .text(let p, let h, let s):
            e.shape = .text(position: tp(p), height: h * CGFloat(t.uniformScale), string: s)
        }
        return e
    }
}

extension DrawnEntity.Shape {
    /// Axis-aligned world-space bounding box. The original NovaCAD version's
    /// `.arc` case used `HitTester.arcBoundingBox` (editing-layer helper);
    /// reimplemented here as a small self-contained calculation so CADCore
    /// has no dependency on NovaCAD's HitTesting.swift.
    public var boundingBox: CGRect {
        switch self {
        case .line(let a, let b), .rect(let a, let b):
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(b.x - a.x), height: abs(b.y - a.y))
        case .polyline(let pts, _):
            guard let f = pts.first else { return .zero }
            var r = CGRect(origin: f, size: .zero)
            for p in pts.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
            return r
        case .circle(let c, let r):
            return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        case .arc(let c, let r, let s, let e):
            return DrawnEntity.Shape.arcBoundingBox(center: c, radius: r, startDeg: s, endDeg: e)
        case .text(let pos, let h, let str):
            let w = CGFloat(max(1, str.count)) * h * 0.6
            return CGRect(x: pos.x, y: pos.y, width: w, height: h)
        }
    }

    /// Bounding box of a circular arc: the two endpoints plus any of the
    /// cardinal points (0/90/180/270°) that fall within the arc's sweep.
    private static func arcBoundingBox(center: CGPoint, radius: CGFloat,
                                       startDeg: Double, endDeg: Double) -> CGRect {
        func point(atDeg deg: Double) -> CGPoint {
            let rad = deg * .pi / 180
            return CGPoint(x: center.x + radius * CGFloat(cos(rad)),
                           y: center.y + radius * CGFloat(sin(rad)))
        }
        func normalizedSweepContains(_ deg: Double) -> Bool {
            var s = startDeg.truncatingRemainder(dividingBy: 360)
            var e = endDeg.truncatingRemainder(dividingBy: 360)
            if s < 0 { s += 360 }
            if e < 0 { e += 360 }
            var d = deg.truncatingRemainder(dividingBy: 360)
            if d < 0 { d += 360 }
            if s <= e { return d >= s && d <= e }
            return d >= s || d <= e
        }
        var pts = [point(atDeg: startDeg), point(atDeg: endDeg)]
        for cardinal in [0.0, 90.0, 180.0, 270.0] where normalizedSweepContains(cardinal) {
            pts.append(point(atDeg: cardinal))
        }
        guard var box = pts.first.map({ CGRect(origin: $0, size: .zero) }) else { return .zero }
        for p in pts.dropFirst() { box = box.union(CGRect(origin: p, size: .zero)) }
        return box
    }
}
