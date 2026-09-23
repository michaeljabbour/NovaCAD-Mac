import Foundation
import CADCore
import CoreGraphics
import CoreText

/// Resolves an entity's plot-time appearance from a CTB/STB plot style table.
/// This is a stub protocol — Phase 12 supplies the real CTB/STB-backed
/// implementation. Until then, callers pass `nil` and CGRenderCore draws
/// every entity with its normal resolved (interactive) appearance.
protocol PlotStyleResolving {
    func resolve(aci: Int, layerStyleName: String?, lineweight: Int16) -> ResolvedPlotStyle
}

/// The effective appearance CGRenderCore applies for a plotted entity when a
/// `PlotStyleResolving` is supplied. `color`/`lineweightMM` nil means "use
/// object" — keep the entity's own resolved value.
struct ResolvedPlotStyle {
    var color: CGColor?
    var lineweightMM: Double?
    var lineCap: CGLineCap = .butt
    var lineJoin: CGLineJoin = .miter
    var screening: Int = 100
    var dither: Bool = true
}

/// The shared CoreGraphics rasterization body: five passes (fills, LOD-decimated
/// strokes, points, text, selection highlight) drawn into a caller-supplied
/// `CGContext`. This is the single implementation behind:
///   - `BitmapRenderer` (the interactive on-screen renderer — DXFRenderer.swift)
///   - `--renderer cg` in SnapshotMode (headless verification / Metal parity reference)
///   - Phase 12's `CGPDFContext` vector plotting (PlotRenderer)
///
/// Extracted verbatim from the original `BitmapRenderer.render` — no behavior
/// change; `styleResolver` is unused today (Phase 12 wires CTB/STB-driven
/// color/lineweight/cap/join overrides into the fill/stroke passes).
enum CGRenderCore {

    static func plotStrokeWidth(_ lineweight: Int16) -> CGFloat {
        CGFloat(lineweight < 0 ? 25 : max(1, lineweight)) / 100 * 72 / 25.4
    }

    static let darkBackgroundRGB: (CGFloat, CGFloat, CGFloat) = (0.13, 0.16, 0.19) // AutoCAD-ish

    /// Converts a layer's AutoCAD-style 0-100% transparency into the alpha
    /// multiplier every draw pass applies (fills, pattern fills, strokes,
    /// points, text) — one shared lookup so every pass agrees on what a
    /// layer's transparency setting means, rather than each independently
    /// reimplementing the percent-to-alpha conversion. Returns 1 (fully
    /// opaque, i.e. a complete no-op for callers) for an out-of-range
    /// `layerId` — a stroke/fill belonging to a layer index the document
    /// doesn't (yet) have a table entry for must never be silently hidden by
    /// a spurious transparency read.
    @inline(__always)
    static func fillAlpha(for layerId: Int, in document: DXFDocument) -> CGFloat {
        guard layerId >= 0, layerId < document.layers.count else { return 1 }
        let transparency = document.layers[layerId].transparency
        guard transparency > 0 else { return 1 }
        return CGFloat(1 - min(max(transparency, 0), 100) / 100)
    }

    /// Converts a `StrokeStore.Run`/`Arc.lineweight` (DXF group 370,
    /// hundredths of a millimeter — see that field's own doc comment) into a
    /// SCREEN-space stroke width, in device pixels. `< 0` (BYLAYER/BYBLOCK/
    /// default — the overwhelming common case, no explicit override) returns
    /// `defaultWidth` unchanged, i.e. today's fixed hairline.
    ///
    /// Deliberately a fixed SCREEN width independent of `zoom` — matching
    /// AutoCAD's own "Lineweight Display" toggle, which shows a constant
    /// on-screen thickness rather than a true-to-scale plotted width (a
    /// literal mm-to-pixel conversion at typical screen DPI/zoom would make
    /// most real-world lineweights, e.g. 0.25mm, round to sub-pixel and
    /// vanish). Scaled so AutoCAD's own default (0.25mm / DXF value 25)
    /// renders at exactly `defaultWidth` (i.e. an entity that explicitly
    /// sets the default lineweight looks identical to one with no override
    /// at all), doubling for each additional 0.25mm step — a simple,
    /// visually legible progression rather than a literal DPI conversion.
    /// Never renders THINNER than `defaultWidth`: a hairline is already the
    /// thinnest legible width, so an explicit sub-default lineweight (e.g.
    /// 0.13mm, "thin") still shows as a hairline rather than disappearing.
    @inline(__always)
    static func screenStrokeWidth(forLineweight lw: Int16, defaultWidth: CGFloat) -> CGFloat {
        guard lw >= 0 else { return defaultWidth }
        let quarters = max(1.0, CGFloat(lw) / 25.0)
        return defaultWidth * quarters
    }

    /// Draws one frame into `ctx` (dimensions taken from `ctx.width`/`ctx.height`).
    /// Returns `false` if `isStale` fired mid-render — the caller should discard
    /// whatever was partially drawn (the context is left in an undefined state).
    @discardableResult
    static func draw(into ctx: CGContext, document: DXFDocument, params p: RenderParams,
                     styleResolver: PlotStyleResolving? = nil, paintBackground: Bool = true,
                     isStale: () -> Bool = { false }) -> Bool {
        let wPx = max(1, Int((p.viewSize.width * p.backingScale).rounded()))
        let hPx = max(1, Int((p.viewSize.height * p.backingScale).rounded()))

        // Background
        if p.darkBackground {
            let (r, g, b) = darkBackgroundRGB
            ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        } else {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        }
        if paintBackground { ctx.fill(CGRect(x: 0, y: 0, width: wPx, height: hPx)) }

        // world → bitmap pixels (bitmap is y-up bottom-left; view is y-down top-left)
        let toPixels = CGAffineTransform(scaleX: p.backingScale, y: p.backingScale)
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(hPx))
        let worldToBitmap = p.worldToView.concatenating(toPixels).concatenating(flip)

        // Visible world rect for culling (world is axis-aligned under our
        // similarity transform, so inverting the view rect is exact enough).
        let viewRect = CGRect(origin: .zero, size: p.viewSize)
        let worldRect = viewRect.applying(p.worldToView.inverted())
            .insetBy(dx: -10, dy: -10)

        let groups = p.usePaperSpace ? document.paperGroups : document.modelGroups
        let visible = groups.filter { g in
            p.visibility.isVisible(g) && g.bounds.intersects(worldRect)
        }

        // A paper viewport shows clipped model geometry, never another sheet.
        if p.usePaperSpace {
            for viewport in document.paperViewports where !p.visibility.hiddenLayerIds.contains(viewport.layerId) {
                if isStale() { return false }
                ctx.saveGState()
                var clipTransform = worldToBitmap
                if let clip = viewport.clip.copy(using: &clipTransform) { ctx.addPath(clip); ctx.clip() }
                var nested = p
                nested.usePaperSpace = false
                nested.worldToView = viewport.modelToPaper.concatenating(p.worldToView)
                nested.zoom = p.zoom * sqrt(abs(viewport.modelToPaper.a * viewport.modelToPaper.d - viewport.modelToPaper.b * viewport.modelToPaper.c))
                nested.visibility.hiddenLayerIds.formUnion(viewport.frozenLayerIDs)
                nested.selection = []
                let complete = draw(into: ctx, document: document, params: nested,
                                    styleResolver: styleResolver, paintBackground: false, isStale: isStale)
                ctx.restoreGState()
                if !complete { return false }
            }
        }
        for raster in p.usePaperSpace ? document.paperImages : document.modelImages {
            guard !p.visibility.hiddenLayerIds.contains(raster.layerId),
                  !p.visibility.hiddenXrefIds.contains(raster.xrefId), raster.bounds.intersects(worldRect) else { continue }
            if isStale() { return false }
            ctx.saveGState()
            ctx.concatenate(raster.transform.concatenating(worldToBitmap))
            if let clip = raster.clip { ctx.addPath(clip); ctx.clip(using: .evenOdd) }
            ctx.setAlpha(raster.opacity * fillAlpha(for: raster.layerId, in: document))
            if let image = raster.image {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            } else {
                ctx.setStrokeColor(CGColor(red: 0.85, green: 0.4, blue: 0.1, alpha: 1))
                ctx.setLineWidth(0.003)
                ctx.stroke(CGRect(x: 0, y: 0, width: 1, height: 1))
                ctx.move(to: .zero); ctx.addLine(to: CGPoint(x: 1, y: 1))
                ctx.move(to: CGPoint(x: 0, y: 1)); ctx.addLine(to: CGPoint(x: 1, y: 0)); ctx.strokePath()
            }
            ctx.restoreGState()
        }

        // Pass 1: fills (behind linework, like AutoCAD draw order for hatches).
        // NOTE (Phase 1.6): fills are baked into one merged CGPath per group
        // at emission time, not iterated primitive-by-primitive like
        // runs/arcs/points/texts below — there is no O(1) per-primitive
        // tombstone check possible here without rebuilding the path (which
        // would defeat the point of an O(1) guard). A tombstoned HATCH/SOLID
        // therefore keeps rendering until the next compaction. This is an
        // accepted limitation: the `--edit-script` grammar this phase
        // targets (line/circle/text/erase/move) never edits fill-bearing
        // entities, so it isn't exercised in practice yet; a future phase
        // adding hatch/solid editing should either tombstone at the
        // sub-path level or force those edits through immediate compaction.
        for g in visible {
            if isStale() { return false }
            let color = g.color.cgColor(darkBackground: p.darkBackground)
            // Layer transparency (AutoCAD-style, 0-100%) — see `DXFLayer
            // .transparency`'s own doc comment. `1 - transparency/100` folds
            // straight into the fill alpha; the pattern-fill pass's existing
            // 0.16 approximation is scaled the SAME way so a transparent
            // layer's crosshatch/pattern regions dim consistently with its
            // solid ones rather than one obeying transparency and the other
            // silently ignoring it.
            let layerAlpha = Self.fillAlpha(for: Int(g.layerId), in: document)
            if !g.patternFillPath.isEmpty {
                ctx.saveGState()
                ctx.concatenate(worldToBitmap)
                ctx.addPath(g.patternFillPath)
                ctx.setFillColor(color.copy(alpha: 0.16 * layerAlpha) ?? color)
                ctx.fillPath(using: .evenOdd)
                ctx.restoreGState()
            }
            if !g.fillPath.isEmpty {
                // A hatch's OWN transparency (independent of its layer's —
                // `StrokeStore.Run.fillAlpha`, baked in at emission time)
                // means the group's SOLID fills can no longer always be
                // drawn as one merged path at one alpha: whenever any
                // `fillRun` in this group carries a non-default alpha, each
                // loop is instead drawn as its OWN fillPath at its OWN
                // composed alpha (own x layer). The merged-path fast path
                // stays exactly as before for the overwhelming common case
                // (every hatch on this layer+color at 0% own-transparency),
                // so this costs nothing when the feature isn't in use.
                let hasPerHatchAlpha = g.strokes.fillRuns.contains { $0.fillAlpha < 1 }
                if hasPerHatchAlpha {
                    let tombstones = GroupTombstoneRegistry.tombstones(for: g)
                    ctx.saveGState()
                    ctx.concatenate(worldToBitmap)
                    for (fi, run) in g.strokes.fillRuns.enumerated() {
                        if let t = tombstones, t.isDead(.fillRun, Int32(fi)) { continue }
                        let s = Int(run.start), c = Int(run.count)
                        guard c >= 3, s + c <= g.strokes.fillPoints.count else { continue }
                        let composed = layerAlpha * run.fillAlpha
                        guard composed > 0 else { continue }
                        let loopPath = CGMutablePath()
                        loopPath.move(to: g.strokes.fillPoints[s])
                        for k in (s + 1)..<(s + c) { loopPath.addLine(to: g.strokes.fillPoints[k]) }
                        loopPath.closeSubpath()
                        ctx.addPath(loopPath)
                        ctx.setFillColor(color.copy(alpha: composed) ?? color)
                        ctx.fillPath(using: .evenOdd)
                    }
                    ctx.restoreGState()
                } else {
                    ctx.saveGState()
                    ctx.concatenate(worldToBitmap)
                    ctx.addPath(g.fillPath)
                    ctx.setFillColor(layerAlpha < 1 ? (color.copy(alpha: layerAlpha) ?? color) : color)
                    ctx.fillPath(using: .evenOdd)
                    ctx.restoreGState()
                }
            }
        }

        // Pass 2: strokes, built per frame in SCREEN space with decimation.
        // Points landing within ~3/4 px of the last kept point are dropped and
        // whole sub-pixel runs collapse to a 1px tick. This is what makes
        // full-extent views of multi-million-entity drawings renderable —
        // CoreGraphics' AA sweep cannot handle tens of millions of crossing
        // sub-pixel hairlines (aa_intersection_event blows up for minutes).
        ctx.setLineJoin(.bevel)
        ctx.setLineCap(.butt)
        let quality = RenderQuality(level: p.quality)
        ctx.setShouldAntialias(quality.antialias)
        ctx.setAllowsAntialiasing(quality.antialias)
        let bs = p.backingScale
        let zoomPx = p.zoom * bs                     // device px per drawing unit
        let tol = p.vectorOutput ? 0 : quality.decimationTol * bs
        let tick = 1.0 * bs
        let strokeWidth = (p.vectorOutput ? 0.25 * 72 / 25.4 : 1.0) * bs                   // 1pt lines, like AutoCAD hairlines

        // Occupancy grid for collapsed (sub-pixel) entities. Dense drawings have
        // millions of tiny entities that all land on the same few pixels — only
        // the first one per cell draws. This bounds total ink by SCREEN AREA
        // instead of entity count, which is what makes full-extent views O(pixels).
        let cell = quality.tickCell * bs
        let gridW = Int(CGFloat(wPx) / cell) + 2
        let gridH = Int(CGFloat(hPx) / cell) + 2
        var occupied = [Bool](repeating: false, count: gridW * gridH)

        @inline(__always) func claimCell(_ sp: CGPoint) -> Bool {
            if p.vectorOutput { return true }
            let gx = Int(sp.x / cell), gy = Int(sp.y / cell)
            guard gx >= 0, gy >= 0, gx < gridW, gy < gridH else { return false }
            let idx = gy * gridW + gx
            if occupied[idx] { return false }
            occupied[idx] = true
            return true
        }

        // Pool of reusable CGMutablePaths — allocated once per group, returned
        // to the pool after flush, avoiding ~thousands of malloc/free per frame.
        var pathPool: [CGMutablePath] = []

        for g in visible {
            guard !g.strokes.isEmpty else { continue }
            if isStale() { return false }
            let layerWeight = document.layers.indices.contains(g.layerId) ? document.layers[g.layerId].lineweight : -3
            let strokeWidth = p.vectorOutput ? Self.plotStrokeWidth(layerWeight) : strokeWidth
            var color = g.color.cgColor(darkBackground: p.darkBackground)
            // Layer transparency applies to linework the same as fills —
            // AutoCAD's Layer Properties Manager transparency affects the
            // WHOLE layer's drawn appearance, not solid/pattern fills alone.
            let layerAlpha = Self.fillAlpha(for: Int(g.layerId), in: document)
            if layerAlpha < 1 { color = color.copy(alpha: layerAlpha) ?? color }
            var dashes: [CGFloat] = []
            if g.linetypeId > 0, g.linetypeId < document.linetypes.count {
                let d = document.linetypes[g.linetypeId].dashes
                let patternLen = d.reduce(0, +)
                // Draw solid when the pattern would collapse below ~4 screen points.
                if !d.isEmpty && (p.vectorOutput || patternLen * p.zoom > 4) {
                    dashes = d.map { $0 * zoomPx }   // screen-space dash lengths
                }
            }

            ctx.setStrokeColor(color)
            ctx.setLineWidth(strokeWidth)
            ctx.setLineDash(phase: 0, lengths: dashes)

            // Reuse CGMutablePaths from a pool instead of allocating one per
            // visible group (there can be thousands). `pathPool` is a local
            // array populated lazily; popped paths are returned after flush.
            var path = pathPool.popLast() ?? CGMutablePath()
            var pathVerts = 0
            var tickRects: [CGRect] = []
            func flush() {
                guard !path.isEmpty else { return }
                ctx.addPath(path)
                ctx.strokePath()
                // Discard the path (can't clear CGMutablePath); the pool at
                // the end of the group pops a new one next iteration.
                path = CGMutablePath()
                pathVerts = 0
            }

            // A run/arc carrying an explicit per-entity lineweight (DXF group
            // 370 — see `StrokeStore.Run.lineweight`'s own doc comment) OR a
            // non-default `strokeAlpha` (a non-solid HATCH's diagonal-line
            // pattern, dimmed by its own transparency — see that field's own
            // doc comment) can't share the group's single batched path/
            // line-width/color: it needs its OWN `setLineWidth`/
            // `setStrokeColor` + immediate `strokePath()`. This costs
            // nothing for the overwhelming common case (no entity in this
            // group ever set either — `hasWeightedStrokes` short-circuits
            // every per-primitive check below back to the original
            // single-batched-path fast path) and only pays a per-primitive
            // stroke cost proportional to how many entities actually use
            // one of these features.
            let hasWeightedStrokes = g.strokes.runs.contains { $0.lineweight >= 0 || $0.strokeAlpha < 1 }
                || g.strokes.arcs.contains { $0.lineweight >= 0 }

            let pts = g.strokes.points
            let tombstones = GroupTombstoneRegistry.tombstones(for: g)   // Phase 1.6: nil for any never-edited group (the overwhelming common case)
            for (ri, run) in g.strokes.runs.enumerated() {
                if let t = tombstones, t.isDead(.run, Int32(ri)) { continue }
                guard run.bounds.intersects(worldRect) else { continue }
                let start = Int(run.start), count = Int(run.count)

                // Whole run smaller than ~a pixel: one deduplicated tick, filled
                // (not stroked) — cheap and bounded by the occupancy grid.
                if !p.vectorOutput && (run.bounds.width + run.bounds.height) * zoomPx < cell {
                    let c = CGPoint(x: run.bounds.midX, y: run.bounds.midY)
                        .applying(worldToBitmap)
                    if claimCell(c) {
                        tickRects.append(CGRect(x: c.x - tick / 2, y: c.y - tick / 2,
                                                width: tick, height: tick))
                    }
                    continue
                }

                if hasWeightedStrokes, run.lineweight >= 0 || run.strokeAlpha < 1 {
                    // Own path, own width/color, drawn immediately — doesn't
                    // touch the shared batched `path`/`pathVerts` at all.
                    let weighted = CGMutablePath()
                    var wLast = pts[start].applying(worldToBitmap)
                    weighted.move(to: wLast)
                    for k in (start + 1)..<(start + count) {
                        let sp = pts[k].applying(worldToBitmap)
                        if k != start + count - 1,
                           abs(sp.x - wLast.x) < tol, abs(sp.y - wLast.y) < tol { continue }
                        weighted.addLine(to: sp)
                        wLast = sp
                    }
                    if run.closed { weighted.closeSubpath() }
                    ctx.setLineWidth((p.vectorOutput ? Self.plotStrokeWidth(run.lineweight < 0 ? layerWeight : run.lineweight) : Self.screenStrokeWidth(forLineweight: run.lineweight, defaultWidth: strokeWidth)))
                    if run.strokeAlpha < 1 { ctx.setStrokeColor(color.copy(alpha: run.strokeAlpha) ?? color) }
                    ctx.addPath(weighted)
                    ctx.strokePath()
                    if run.strokeAlpha < 1 { ctx.setStrokeColor(color) }
                    ctx.setLineWidth(strokeWidth)
                    continue
                }

                var last = pts[start].applying(worldToBitmap)
                path.move(to: last)
                pathVerts += 1
                for k in (start + 1)..<(start + count) {
                    let sp = pts[k].applying(worldToBitmap)
                    if k != start + count - 1,
                       abs(sp.x - last.x) < tol, abs(sp.y - last.y) < tol { continue }
                    path.addLine(to: sp)
                    last = sp
                    pathVerts += 1
                }
                if run.closed { path.closeSubpath() }

                if pathVerts > 100_000 {
                    flush()
                    if isStale() { return false }
                }
            }

            // Analytic arcs/circles: exact at any zoom; sub-pixel ones become ticks.
            for (ai, arc) in g.strokes.arcs.enumerated() {
                if let t = tombstones, t.isDead(.arc, Int32(ai)) { continue }
                let rPx = arc.radius * zoomPx
                let c = arc.center
                guard CGRect(x: c.x - arc.radius, y: c.y - arc.radius,
                             width: arc.radius * 2, height: arc.radius * 2)
                    .intersects(worldRect) else { continue }
                let sc = c.applying(worldToBitmap)
                if !p.vectorOutput && rPx < 1.4 {
                    if rPx >= 0.3, claimCell(sc) {
                        tickRects.append(CGRect(x: sc.x - tick / 2, y: sc.y - tick / 2,
                                                width: tick, height: tick))
                    }
                } else if hasWeightedStrokes, arc.lineweight >= 0 {
                    let weighted = CGMutablePath()
                    if arc.isFullCircle {
                        weighted.addEllipse(in: CGRect(x: sc.x - rPx, y: sc.y - rPx,
                                                       width: rPx * 2, height: rPx * 2))
                    } else {
                        let s = arc.startAngleDeg * .pi / 180 + atan2(worldToBitmap.b, worldToBitmap.a)
                        let e = arc.endAngleDeg * .pi / 180 + atan2(worldToBitmap.b, worldToBitmap.a)
                        weighted.move(to: CGPoint(x: sc.x + rPx * cos(s), y: sc.y + rPx * sin(s)))
                        weighted.addArc(center: sc, radius: rPx, startAngle: s, endAngle: e, clockwise: false)
                    }
                    ctx.setLineWidth((p.vectorOutput ? Self.plotStrokeWidth(arc.lineweight < 0 ? layerWeight : arc.lineweight) : Self.screenStrokeWidth(forLineweight: arc.lineweight, defaultWidth: strokeWidth)))
                    ctx.addPath(weighted)
                    ctx.strokePath()
                    ctx.setLineWidth(strokeWidth)
                } else if arc.isFullCircle {
                    path.addEllipse(in: CGRect(x: sc.x - rPx, y: sc.y - rPx,
                                               width: rPx * 2, height: rPx * 2))
                    pathVerts += 4
                } else {
                    // Include sheet/view rotation when drawing analytic arcs.
                    let s = arc.startAngleDeg * .pi / 180 + atan2(worldToBitmap.b, worldToBitmap.a)
                    let e = arc.endAngleDeg * .pi / 180 + atan2(worldToBitmap.b, worldToBitmap.a)
                    path.move(to: CGPoint(x: sc.x + rPx * cos(s), y: sc.y + rPx * sin(s)))
                    path.addArc(center: sc, radius: rPx,
                                startAngle: s, endAngle: e, clockwise: false)
                    pathVerts += 6
                }
                if pathVerts > 100_000 {
                    flush()
                    if isStale() { return false }
                }
            }
            flush()
            // Return path to the pool; the `popLast()` at the start of each
            // group reuses it, avoiding per-frame CGMutablePath allocations.
            pathPool.append(path)
            if !tickRects.isEmpty {
                ctx.setFillColor(color)
                ctx.fill(tickRects)
            }
        }
        ctx.setLineDash(phase: 0, lengths: [])

        // Pass 3: points (fixed screen size).
        let pointR = 1.6 * p.backingScale
        for g in visible where !g.points.isEmpty {
            if isStale() { return false }
            var pointColor = g.color.cgColor(darkBackground: p.darkBackground)
            let layerAlpha = Self.fillAlpha(for: Int(g.layerId), in: document)
            if layerAlpha < 1 { pointColor = pointColor.copy(alpha: layerAlpha) ?? pointColor }
            ctx.setFillColor(pointColor)
            let tombstones = GroupTombstoneRegistry.tombstones(for: g)
            for (pi, pt) in g.points.enumerated() {
                if let t = tombstones, t.isDead(.point, Int32(pi)) { continue }
                let s = pt.applying(worldToBitmap)
                guard s.x >= -4, s.y >= -4, s.x <= CGFloat(wPx) + 4, s.y <= CGFloat(hPx) + 4
                else { continue }
                ctx.fillEllipse(in: CGRect(x: s.x - pointR, y: s.y - pointR,
                                           width: pointR * 2, height: pointR * 2))
            }
        }

        // Pass 4: text — always antialiased; jagged text is illegible at any
        // quality level and the culled text count is small.
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        drawTexts(ctx: ctx, groups: visible, params: p, document: document,
                  worldToBitmap: worldToBitmap, wPx: wPx, hPx: hPx, isStale: isStale)
        if isStale() { return false }

        // Pass 5: selection highlight.
        if !p.selection.isEmpty {
            drawSelection(ctx: ctx, document: document, params: p,
                          worldToBitmap: worldToBitmap, worldRect: worldRect,
                          zoomPx: zoomPx, bs: bs)
        }

        return true
    }

    // MARK: Selection highlight

    private static func drawSelection(ctx: CGContext, document: DXFDocument,
                                      params p: RenderParams,
                                      worldToBitmap: CGAffineTransform,
                                      worldRect: CGRect,
                                      zoomPx: CGFloat, bs: CGFloat) {
        let groups = p.usePaperSpace ? document.paperGroups : document.modelGroups
        var selectedInserts = Set<Int32>()
        var primitives: [Int32: [(PrimitiveStore, Int32)]] = [:]
        for ref in p.selection {
            switch ref {
            case .insert(let id): selectedInserts.insert(id)
            case .primitive(let g, let store, let idx):
                primitives[g, default: []].append((store, idx))
            }
        }

        let accent = CGColor(red: 0.25, green: 0.66, blue: 1.0, alpha: 1)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(2.4 * bs)
        let tol = 0.5 * bs

        let path = CGMutablePath()

        func addRun(_ run: StrokeStore.Run, pts: [CGPoint]) {
            guard run.bounds.intersects(worldRect) else { return }
            let s = Int(run.start), c = Int(run.count)
            var last = pts[s].applying(worldToBitmap)
            path.move(to: last)
            for k in (s + 1)..<(s + c) {
                let sp = pts[k].applying(worldToBitmap)
                if k != s + c - 1, abs(sp.x - last.x) < tol, abs(sp.y - last.y) < tol { continue }
                path.addLine(to: sp)
                last = sp
            }
            if run.closed { path.closeSubpath() }
        }

        func addArc(_ arc: StrokeStore.Arc) {
            let sc = arc.center.applying(worldToBitmap)
            let rPx = max(arc.radius * zoomPx, 1.5 * bs)
            if arc.isFullCircle {
                path.addEllipse(in: CGRect(x: sc.x - rPx, y: sc.y - rPx,
                                           width: rPx * 2, height: rPx * 2))
            } else {
                let s = arc.startAngleDeg * .pi / 180 + atan2(worldToBitmap.b, worldToBitmap.a)
                let e = arc.endAngleDeg * .pi / 180 + atan2(worldToBitmap.b, worldToBitmap.a)
                path.move(to: CGPoint(x: sc.x + rPx * CoreGraphics.cos(s),
                                      y: sc.y + rPx * CoreGraphics.sin(s)))
                path.addArc(center: sc, radius: rPx, startAngle: s, endAngle: e,
                            clockwise: false)
            }
        }

        func addText(_ t: TextItem) {
            let sc = t.position.applying(worldToBitmap)
            let capPx = max(t.height * zoomPx, 4 * bs)
            let lines = t.text.components(separatedBy: "\n")
            let maxChars = lines.reduce(1) { max($0, $1.count) }
            let w = CGFloat(maxChars) * capPx * 0.75 * max(t.widthFactor, 0.1)
            path.addRect(CGRect(x: sc.x - 2 * bs, y: sc.y - 2 * bs,
                                width: w + 4 * bs,
                                height: capPx * CGFloat(lines.count) * 5 / 3 + 4 * bs))
        }

        func addPoint(_ pt: CGPoint) {
            let sc = pt.applying(worldToBitmap)
            let r = 4 * bs
            path.addEllipse(in: CGRect(x: sc.x - r, y: sc.y - r, width: r * 2, height: r * 2))
        }

        let fillPath = CGMutablePath()
        func addFill(_ run: StrokeStore.Run, pts: [CGPoint]) {
            guard run.bounds.intersects(worldRect) else { return }
            let s = Int(run.start), c = Int(run.count)
            fillPath.move(to: pts[s].applying(worldToBitmap))
            for k in (s + 1)..<(s + c) { fillPath.addLine(to: pts[k].applying(worldToBitmap)) }
            fillPath.closeSubpath()
        }

        for (gi, g) in groups.enumerated() {
            guard p.visibility.isVisible(g) else { continue }
            let gi32 = Int32(gi)
            // Phase 1.6 incremental regen tombstones a primitive IN PLACE
            // (bit-flags it dead in the OLD group) rather than physically
            // removing it — the main draw pass (lines 182/221/268/456 in
            // this file) and every hit-test path already guard on this;
            // `drawSelection` must too, or re-selecting/still-selecting an
            // entity that was just edited can resolve BOTH its stale old
            // primitive (found via `RegenCoordinator.reverseIndex`'s own
            // pre-existing tombstone gap) and its live new one, drawing a
            // highlight outline at the entity's FORMER location/shape in
            // addition to (or instead of) its actual current one — exactly
            // the "highlight doesn't match what's drawn" symptom this
            // guards against. `nil` for any never-edited group (the
            // overwhelming common case), so this is a no-op fast path.
            let tombstones = GroupTombstoneRegistry.tombstones(for: g)

            // Whole-insert highlights: scan for members.
            if !selectedInserts.isEmpty,
               g.bounds.intersects(worldRect) {
                for (ri, run) in g.strokes.runs.enumerated() where selectedInserts.contains(run.insertId) {
                    if let t = tombstones, t.isDead(.run, Int32(ri)) { continue }
                    addRun(run, pts: g.strokes.points)
                }
                for (ai, arc) in g.strokes.arcs.enumerated() where selectedInserts.contains(arc.insertId) {
                    if let t = tombstones, t.isDead(.arc, Int32(ai)) { continue }
                    addArc(arc)
                }
                for (ti, t) in g.texts.enumerated() where selectedInserts.contains(t.insertId) {
                    if let tb = tombstones, tb.isDead(.text, Int32(ti)) { continue }
                    addText(t)
                }
                for (pi, pt) in g.points.enumerated() {
                    if pi < g.strokes.pointInsertIds.count,
                       selectedInserts.contains(g.strokes.pointInsertIds[pi]) {
                        if let t = tombstones, t.isDead(.point, Int32(pi)) { continue }
                        addPoint(pt)
                    }
                }
                for (fi, run) in g.strokes.fillRuns.enumerated() where selectedInserts.contains(run.insertId) {
                    if let t = tombstones, t.isDead(.fillRun, Int32(fi)) { continue }
                    addFill(run, pts: g.strokes.fillPoints)
                }
            }

            for (store, idx) in primitives[gi32] ?? [] {
                let i = Int(idx)
                if let t = tombstones, t.isDead(store, idx) { continue }
                switch store {
                case .run:
                    if i < g.strokes.runs.count { addRun(g.strokes.runs[i], pts: g.strokes.points) }
                case .arc:
                    if i < g.strokes.arcs.count { addArc(g.strokes.arcs[i]) }
                case .text:
                    if i < g.texts.count { addText(g.texts[i]) }
                case .point:
                    if i < g.points.count { addPoint(g.points[i]) }
                case .fillRun:
                    if i < g.strokes.fillRuns.count {
                        addFill(g.strokes.fillRuns[i], pts: g.strokes.fillPoints)
                    }
                }
            }
        }

        if !fillPath.isEmpty {
            ctx.addPath(fillPath)
            ctx.setFillColor(accent.copy(alpha: 0.3) ?? accent)
            ctx.fillPath(using: .evenOdd)
        }
        if !path.isEmpty {
            ctx.addPath(path)
            ctx.strokePath()
        }
    }

    // MARK: Text

    private static let baseFont = CTFontCreateWithName("Helvetica" as CFString, 100, nil)
    private static let capRatio: CGFloat = {
        let cap = CTFontGetCapHeight(baseFont)
        return cap > 0 ? cap / 100 : 0.7
    }()

    private static func drawTexts(ctx: CGContext, groups: [RenderGroup], params p: RenderParams,
                                  document: DXFDocument,
                                  worldToBitmap: CGAffineTransform,
                                  wPx: Int, hPx: Int, isStale: () -> Bool) {
        let pxScale = p.zoom * p.backingScale   // pixels per drawing unit
        let minCapPx = p.vectorOutput ? 0.01 : RenderQuality(level: p.quality).minTextPt * p.backingScale
        var fontCache: [Int: CTFont] = [:]

        for g in groups {
            if isStale() { return }
            guard !g.texts.isEmpty else { continue }
            var color = g.color.cgColor(darkBackground: p.darkBackground)
            let layerAlpha = Self.fillAlpha(for: Int(g.layerId), in: document)
            if layerAlpha < 1 { color = color.copy(alpha: layerAlpha) ?? color }
            let tombstones = GroupTombstoneRegistry.tombstones(for: g)

            for (ti, item) in g.texts.enumerated() {
                if let t = tombstones, t.isDead(.text, Int32(ti)) { continue }
                let capPx = item.height * pxScale
                guard capPx >= minCapPx, (p.vectorOutput || capPx <= 4000) else { continue }
                let anchor = item.position.applying(worldToBitmap)

                // Generous cull: assume ~0.8 * cap width per character.
                let lines = item.text.components(separatedBy: "\n")
                let maxChars = lines.reduce(0) { max($0, $1.count) }
                let estW = CGFloat(maxChars) * capPx * 0.8 * max(item.widthFactor, 0.1)
                let margin = max(estW, capPx * CGFloat(lines.count) * 2)
                guard anchor.x > -margin, anchor.x < CGFloat(wPx) + margin,
                      anchor.y > -margin, anchor.y < CGFloat(hPx) + margin else { continue }

                let fontSize = capPx / capRatio
                let sizeKey = Int(fontSize * 4)
                let font = fontCache[sizeKey] ?? {
                    let f = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
                    fontCache[sizeKey] = f
                    return f
                }()

                ctx.saveGState()
                ctx.translateBy(x: anchor.x, y: anchor.y)
                let rotation = item.rotationDegrees * .pi / 180 + atan2(worldToBitmap.b, worldToBitmap.a)
                if rotation != 0 { ctx.rotate(by: rotation) }
                // MIRRTEXT=1 (Phase 4.2 MIRROR command): glyphs render
                // backwards rather than being re-normalized to stay
                // readable. Flipping the context's x-axis BEFORE hAlign's
                // per-line `x = ...` offset (below) is computed means that
                // offset is applied in mirrored space too, so e.g.
                // left-aligned text still starts exactly at the anchor and
                // reads backwards growing toward mirrored +X (world -X) —
                // no separate hAlign-sign correction needed.
                if item.mirroredX {
                    ctx.scaleBy(x: -1, y: 1)
                }
                if item.widthFactor != 1 && item.widthFactor > 0.05 {
                    ctx.scaleBy(x: item.widthFactor, y: 1)
                }
                ctx.setFillColor(color)
                ctx.textMatrix = .identity

                let lineAdvance = capPx * 5 / 3
                let n = lines.count
                // First-line baseline offset from the anchor, per vertical alignment.
                let firstBaselineY: CGFloat
                switch item.vAlign {
                case 3:  firstBaselineY = -capPx                                   // top
                case 2:  firstBaselineY = (capPx + CGFloat(n - 1) * lineAdvance) / 2 - capPx // middle
                case 1:  firstBaselineY = CGFloat(n - 1) * lineAdvance             // bottom
                default: firstBaselineY = 0                                        // baseline
                }

                for (li, lineText) in lines.enumerated() {
                    guard !lineText.isEmpty else { continue }
                    // CoreText attribute keys — NSAttributedString.Key.foregroundColor
                    // (an NSColor key) is ignored by CTLineDraw.
                    let attr = NSAttributedString(string: lineText, attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
                    ])
                    let ctLine = CTLineCreateWithAttributedString(attr)
                    let w = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
                    let x: CGFloat
                    switch item.hAlign {
                    case 1: x = -w / 2
                    case 2: x = -w
                    default: x = 0
                    }
                    ctx.textPosition = CGPoint(x: x, y: firstBaselineY - CGFloat(li) * lineAdvance)
                    CTLineDraw(ctLine, ctx)
                }
                ctx.restoreGState()
            }
        }
    }
}
