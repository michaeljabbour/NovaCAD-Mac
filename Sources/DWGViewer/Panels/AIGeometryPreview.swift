import SwiftUI

/// Uses the exact normalized proposal payload, including curved polyline edges.
struct AIGeometryPreview: View {
    let plan: AIGeometryEditPlan
    var body: some View {
        let before = plan.edits.flatMap(\.before).map(\.previewPoints)
        let after = plan.edits.flatMap(\.replacements).map(\.previewPoints)
        Canvas { context, size in
            let points = (before + after).flatMap { $0 }
            guard let first = points.first else { return }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in points { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
            let scale = min((size.width - 16) / max(maxX - minX, 1e-6), (size.height - 16) / max(maxY - minY, 1e-6))
            func path(_ points: [CGPoint]) -> Path {
                Path { p in
                    for (i, point) in points.enumerated() {
                        let q = CGPoint(x: size.width / 2 + (point.x - (minX + maxX) / 2) * scale,
                                        y: size.height / 2 - (point.y - (minY + maxY) / 2) * scale)
                        if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
                    }
                }
            }
            for line in before { context.stroke(path(line), with: .color(.secondary), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) }
            for line in after { context.stroke(path(line), with: .color(.accentColor), lineWidth: 2) }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("Geometry preview: dashed current objects, solid proposed replacements")
    }
}
