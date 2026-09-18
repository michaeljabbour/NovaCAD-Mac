import CADCore
import CoreGraphics

/// Headless command-bar harness for `SnapshotMode`'s `--exec` flag:
/// `DWGViewer --snapshot out.png --exec "L;0,0;100,100;;" file.dxf` replays a
/// semicolon-separated sequence of command-bar entries against an in-memory
/// `[DrawnEntity]` array (mirroring today's markup-drawing behavior) and
/// composites the result onto the same PNG `--snapshot` would otherwise
/// produce.
///
/// SUPPORTED SUBSET (by design — see the work-package spec this was built
/// against): draw-tool activation (L/LINE, PL/PLINE, C/CIRCLE, A/ARC,
/// REC/RECTANGLE, POL/POLYGON, T/TEXT and their aliases), point/coordinate
/// feeding (absolute `x,y`, relative `@dx,dy`, bare-length `n` when a
/// direction can be inferred), CLOSE, and UNDO — i.e. exactly the
/// `CommandAction` cases that `ContentView.feedTypedPoint`/`setDraft`/
/// `undoLast` handle for markup drawing. NOT supported (and left as a clear
/// "unsupported in --exec" message rather than a silent no-op or a crash):
/// selection (`SEL`/`ESC`), the Move tool, and measurement commands
/// (DIST/AREA/RADIUS/ANGLE) — those all depend on live hit-testing against
/// on-screen cursor state or view-driven hover feedback that has no headless
/// equivalent. `.length` input also has no headless "cursor direction," so
/// it's only honored when a prior point establishes an implicit direction
/// isn't available; a bare-length token with no live hover reports an error
/// exactly like the live `executeCommand()` does when direction is missing.
enum HeadlessCommandHarness {

    struct Result {
        var drawn: [DrawnEntity]
        var messages: [String]
    }

    /// Replays `script` (semicolon-separated command-bar entries, matching
    /// what a user would type into the command bar followed by Return for
    /// each) against a fresh draft-tool state machine. `isPaper` mirrors
    /// whichever space is currently being rendered, matching `commitDrawn`'s
    /// `e.isPaper = space == .paper` in ContentView.
    static func run(script: String, isPaper: Bool) -> Result {
        var draft = DraftState()
        var drawn: [DrawnEntity] = []
        var messages: [String] = []
        // A throwaway, never-rendered EntityStore purely so `DraftContext`
        // has a real (if unused-by-any-live-document) home — this harness
        // only ever exercises the legacy LINE/PLINE/CIRCLE/ARC/RECT/POLYGON
        // modes (see this file's header comment), none of which intern
        // strings via `ctx.store`, so its contents are never actually read;
        // it exists only to satisfy `DraftContext.store`'s type.
        let scratchStore = EntityStore()
        // Legacy markup-layer id: 0 is an arbitrary placeholder (this
        // harness has no real layer table at all — `DrawnEntity` doesn't
        // even carry a numeric layer id, only a name — matching how
        // `commit(_:)` below discards `proto.layerId` entirely and instead
        // hardcodes `DrawnEntity`'s own `layerName` default).
        let ctx = DraftContext.markup(layerId: 0, aci: 1, isPaper: isPaper, store: scratchStore)

        let tokens = script.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        func commit(_ output: DraftOutput) {
            guard case .entity(let proto) = output, let shape = HeadlessCommandHarness.shape(for: proto) else { return }
            var e = DrawnEntity(shape: shape)
            e.isPaper = isPaper
            drawn.append(e)
        }

        func feedPoint(_ p: CGPoint) {
            if draft.isActive, draft.mode != .erase {
                commit(draft.addPoint(p, ctx: ctx))
            } else {
                messages.append("no active draw tool — start one first (L, PL, C, A, REC, POL)")
            }
        }

        for raw in tokens {
            guard !raw.isEmpty else {
                // Bare ⏎: finish an in-progress polyline, same as
                // ContentView.executeCommand's empty-input branch.
                if draft.mode == .polyline {
                    commit(draft.finishPolyline(close: false, ctx: ctx))
                }
                continue
            }
            let upper = raw.uppercased()
            if draft.mode == .polyline, !draft.points.isEmpty, upper == "C" {
                commit(draft.finishPolyline(close: true, ctx: ctx))
                continue
            }
            if draft.mode == .polygon, draft.points.isEmpty, let n = Int(upper), n >= 3, n <= 64 {
                draft.polygonSides = n
                continue
            }

            switch CommandParser.parse(raw) {
            case .tool(let mode):
                draft = DraftState(mode: mode)
            case .closePolyline:
                commit(draft.finishPolyline(close: true, ctx: ctx))
            case .undo:
                if let last = drawn.last {
                    if let bid = last.batchID { drawn.removeAll { $0.batchID == bid } }
                    else { drawn.removeLast() }
                }
            case .point(let p):
                feedPoint(p)
            case .relative(let dx, let dy):
                guard let base = draft.points.last else {
                    messages.append("relative input '\(raw)' needs a previous point")
                    continue
                }
                feedPoint(CGPoint(x: base.x + dx, y: base.y + dy))
            case .length:
                // No live cursor/hover exists headlessly, so a bare length's
                // direction is never resolvable — reported, not silently
                // dropped, matching the spirit of the live code's own guard.
                messages.append("length input '\(raw)' has no cursor direction in --exec (unsupported)")
            case .measureDistance, .measureArea, .measureRadius, .measureAngle:
                messages.append("'\(raw)': measurement commands are not supported by --exec")
            case .selectMode:
                messages.append("'\(raw)': select mode is not supported by --exec")
            case .moveTool:
                messages.append("'\(raw)': the Move tool is not supported by --exec")
            case .modify(let cmd):
                // Phase 4.2: COPY/ROTATE/SCALE/MIRROR, like Move/selection,
                // depend on live hit-testing/selection state this markup-only
                // harness has no equivalent for — use `--edit-script`'s
                // copy/rotate/scale/mirror verbs (EditScriptRunner.swift) for
                // headless verification of these commands instead.
                messages.append("'\(raw)': \(cmd.displayName) is not supported by --exec (use --edit-script)")
            case .trimExtend(let cmd):
                // Phase 4.3: TRIM/EXTEND, like COPY/ROTATE/SCALE/MIRROR
                // above, depend on live hit-testing/boundary-resolution
                // state this markup-only harness has no equivalent for —
                // use `--edit-script`'s trim/extend verbs instead.
                messages.append("'\(raw)': \(cmd.displayName) is not supported by --exec (use --edit-script)")
            case .filletChamfer(let cmd):
                // Phase 4.4: FILLET/CHAMFER, same reasoning as trimExtend above.
                messages.append("'\(raw)': \(cmd.displayName) is not supported by --exec (use --edit-script)")
            case .stretch:
                // STRETCH depends on live crossing-window selection state,
                // same reasoning as trimExtend/filletChamfer above.
                messages.append("'\(raw)': Stretch is not supported by --exec (use --edit-script)")
            case .offset:
                // Phase 4.5: OFFSET, same reasoning as trimExtend/filletChamfer above.
                messages.append("'\(raw)': Offset is not supported by --exec (use --edit-script)")
            case .dimension:
                // DIMENSION's 3-click gesture depends on live cursor/hover
                // state this headless harness has no equivalent for, same
                // reasoning as Offset/TrimExtend above.
                messages.append("'\(raw)': Dimension is not supported by --exec (use --edit-script)")
            case .blockCommand(let cmd):
                // Phase 6.1: BLOCK/INSERT depend on live selection/block-name
                // picker state this markup-only harness has no equivalent
                // for — use `--edit-script`'s block/insert verbs instead.
                messages.append("'\(raw)': \(cmd.displayName) is not supported by --exec (use --edit-script)")
            case .attdef:
                messages.append("'\(raw)': ATTDEF is not supported by --exec (use --edit-script)")
            case .attedit:
                messages.append("'\(raw)': ATTEDIT is not supported by --exec (use --edit-script)")
            case .join:
                // JOIN depends on live selection state, same reasoning as
                // EXPLODE below — use `--edit-script`'s join verb instead.
                messages.append("'\(raw)': Join is not supported by --exec (use --edit-script)")
            case .explode:
                // Phase 6.2: EXPLODE depends on live selection/hit-testing
                // state, same reasoning as trimExtend/filletChamfer/offset
                // above — use `--edit-script`'s explode verb instead.
                messages.append("'\(raw)': Explode is not supported by --exec (use --edit-script)")
            case .array:
                // Phase 6.4: ARRAY depends on live selection state, same
                // reasoning as every other selection-driven command above —
                // use `--edit-script`'s array-rect/array-polar verbs instead.
                messages.append("'\(raw)': Array is not supported by --exec (use --edit-script)")
            case .clayer:
                // CLAYER is a live-document CurrentProperties mutation this
                // markup-only harness has no document/session for at all.
                messages.append("'\(raw)': CLAYER is not supported by --exec")
            case .clipboardCopy, .clipboardPaste:
                // Cross-drawing Copy/Paste depends on live selection/
                // NSPasteboard/multi-document state this markup-only
                // harness has no equivalent for at all.
                messages.append("'\(raw)': Copy/Paste is not supported by --exec")
            case .extractData, .importData:
                // Data Extraction depends on a live EntityStore-backed
                // EditableParsedDocument (INSERT attributes, layers, real
                // entity ids) this markup-only harness has no equivalent
                // for at all — same reasoning as `.save`/`.saveAs` below.
                messages.append("'\(raw)': Data Extraction is not supported by --exec")
            case .save, .saveAs:
                // Phase 3.2: writes the live EntityStore-backed document —
                // this markup-only harness has no EditableParsedDocument/
                // RegenCoordinator at all, only a bare [DrawnEntity] array
                // (see this file's own header comment). `--edit-script`'s own
                // "save" verb is an unrelated internal checkpoint/marker
                // mechanism, not a real DXF write — `--roundtrip` is the
                // actual headless equivalent (calls the same
                // `DXFStructuralWriter` this live command does).
                messages.append("'\(raw)': Save is not supported by --exec (see --roundtrip for headless DXF-write testing)")
            case .scalar:
                messages.append("'\(raw)': scalar input is not supported by --exec (no active modify prompt)")
            case .zoomFit:
                // No-op headlessly — SnapshotMode already fits the render to
                // the document/markup bounds independently of this harness.
                break
            case .unknown(let rawToken):
                messages.append("unknown command: \(rawToken)")
            }
        }
        return Result(drawn: drawn, messages: messages)
    }

    /// `EntityPrototype` -> `DrawnEntity.Shape`, for the legacy modes this
    /// harness exercises (LINE/PLINE/RECT/POLYGON all produce `.line`/
    /// `.polyline`; CIRCLE/ARC produce their own cases directly) — unlike
    /// `MarkupStore.shape(for:at:store:)` (which reads a STORED entity back
    /// out of arena indices), a freshly-built `EntityPrototype` already
    /// carries its vertex/control data inline, so no store lookup is
    /// needed. Returns nil for any prototype shape `DrawnEntity.Shape`
    /// can't represent (ellipse/point/spline/face3d) — unreachable in
    /// practice since this harness never activates those Phase 6.3 modes
    /// (see the file header comment's "SUPPORTED SUBSET"), but handled
    /// defensively rather than force-unwrapped.
    private static func shape(for proto: EntityPrototype) -> DrawnEntity.Shape? {
        switch proto.payload {
        case .line(let p):
            return .line(a: p.a.cgPoint, b: p.b.cgPoint)
        case .polyline(let p, let verts, _):
            return .polyline(pts: verts.map(\.cgPoint), closed: p.closed)
        case .circle(let p):
            return .circle(center: p.center.cgPoint, radius: CGFloat(p.radius))
        case .arc(let p):
            return .arc(center: p.center.cgPoint, radius: CGFloat(p.radius),
                       startDeg: p.startAngleDeg, endDeg: p.endAngleDeg)
        case .text(let p):
            return .text(position: p.position.cgPoint, height: CGFloat(p.height), string: "")
        default:
            return nil
        }
    }

    // MARK: - Headless markup compositing
    //
    // The live app draws markup via DXFCanvasView's AppKit NSView.draw(_:),
    // which isn't available headlessly (no NSGraphicsContext, no window).
    // This reimplements just enough of that drawing — plain CGContext calls,
    // no NSColor/NSFont — to composite the same shapes onto the snapshot
    // bitmap. Visual style (line width, no selection/erase highlighting)
    // intentionally kept simple; this is a verification aid, not a pixel-
    // perfect match of the live overlay.

    static func composite(_ drawn: [DrawnEntity], isPaper: Bool,
                          into ctx: CGContext, worldToView: CGAffineTransform, zoom: CGFloat) {
        guard !drawn.isEmpty else { return }
        ctx.saveGState()
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.setLineWidth(1.8)
        for e in drawn where e.isPaper == isPaper {
            let rgb = ACIPalette.rgb(forACI: e.aci)
            let color = CGColor(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
            ctx.setStrokeColor(color)
            func toView(_ p: CGPoint) -> CGPoint { p.applying(worldToView) }
            switch e.shape {
            case .line(let a, let b):
                ctx.move(to: toView(a)); ctx.addLine(to: toView(b)); ctx.strokePath()
            case .polyline(let pts, let closed):
                guard let f = pts.first else { continue }
                ctx.move(to: toView(f))
                for p in pts.dropFirst() { ctx.addLine(to: toView(p)) }
                if closed { ctx.closePath() }
                ctx.strokePath()
            case .rect(let a, let b):
                let va = toView(a), vb = toView(b)
                ctx.stroke(CGRect(x: min(va.x, vb.x), y: min(va.y, vb.y),
                                  width: abs(vb.x - va.x), height: abs(vb.y - va.y)))
            case .circle(let c, let r):
                let vc = toView(c)
                let vr = r * zoom
                ctx.strokeEllipse(in: CGRect(x: vc.x - vr, y: vc.y - vr, width: vr * 2, height: vr * 2))
            case .arc(let c, let r, let a1, let a2):
                let vc = toView(c)
                let vr = r * zoom
                ctx.move(to: CGPoint(x: vc.x + vr * cos(-a1 * .pi / 180),
                                     y: vc.y + vr * sin(-a1 * .pi / 180)))
                ctx.addArc(center: vc, radius: vr, startAngle: -a1 * .pi / 180,
                          endAngle: -a2 * .pi / 180, clockwise: true)
                ctx.strokePath()
            case .text:
                break   // glyph rendering needs AppKit text layout — skipped headlessly.
            }
        }
        ctx.restoreGState()
    }
}
