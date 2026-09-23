import Foundation
import CADCore
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Thread-safe peak-value tracker used by `--roundtrip`'s peak-RSS-during-
/// write instrumentation (see that code's own doc comment for why a
/// whole-process `/usr/bin/time -l` measurement isn't precise enough to
/// verify the write phase's memory behavior specifically). A background
/// polling thread calls `recordSample` repeatedly while the write runs; the
/// main thread calls `markDone` right after the write returns and reads
/// `peak` once the poller has had a chance to notice and stop.
final class PeakRSSTracker {
    private let lock = NSLock()
    private var peakValue: UInt64
    private var done = false

    init(initial: UInt64) { peakValue = initial }

    func recordSample(_ value: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if value > peakValue { peakValue = value }
    }

    func markDone() {
        lock.lock(); defer { lock.unlock() }
        done = true
    }

    var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }

    var peak: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return peakValue
    }
}

/// Headless rendering: `DWGViewer --snapshot out.png [--size 1600x1000]
/// [--space paper] [--light] file.dxf` parses the file, renders one frame
/// fitted to the drawing extents, writes a PNG, prints stats, and exits.
/// Useful for automated verification and batch previews.
enum SnapshotMode {

    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--test-units") { testUnits(); exit(0) }

        // --compare a.png b.png [--tolerance N]: pixel-diff two PNGs and exit
        // 0/1 accordingly. Needs no input drawing — the Metal-vs-CG parity
        // check (Phase 9) and any other golden-image comparison route through
        // this. Handled before the "must be an existing .dxf" guard below,
        // same as --test-units.
        if let i = args.firstIndex(of: "--compare"), args.count > i + 2 {
            let tolerance = args.firstIndex(of: "--tolerance").flatMap { ti -> Int? in
                args.count > ti + 1 ? Int(args[ti + 1]) : nil
            } ?? 0
            compareImages(args[i + 1], args[i + 2], tolerance: tolerance)
        }

        // --db-stats file.dxf: exercises the NEW `EntityStoreParser` + `Regenerator`
        // path (Phase 1.2/1.3's eager EntityStore parse) instead of the OLD
        // `DXFParser.parse`/`GeometryBuilder.build` path that every other flag in
        // this file uses. Prints per-arena byte accounting plus process RSS — the
        // Phase 1.4 verification gate for memory budget on the 731MB file. Xref
        // resolution is NOT wired into this path yet (PackageLoader still only
        // targets the old RawParseOutput path) — this flag only handles a plain
        // .dxf/.dwg file, not .zip packages or folders.
        if let flagIdx = args.firstIndex(of: "--db-stats"), args.count > flagIdx + 1 {
            runDBStats(path: args[flagIdx + 1])
        }

        // --verify-live-load file|folder|zip (Phase 1.7): exercises
        // `RegenCoordinator.loadPackage` — the EXACT entry point the live
        // app's ContentView.openFile now calls — end to end: full package
        // loading (xrefs/folders/zips/DWG conversion, same as
        // PackageLoader.load), markup-layer pre-registration, then a
        // scripted draw -> undo -> redo cycle through the same
        // DocumentSession.performEdit-shaped sequence the UI uses, so this
        // is a permanent, reusable way to verify the live app's actual data
        // path (not just its constituent pieces in isolation) against any
        // real file, including the large production fixture that can't be
        // committed as a test asset.
        if let flagIdx = args.firstIndex(of: "--verify-live-load"), args.count > flagIdx + 1 {
            runVerifyLiveLoad(path: args[flagIdx + 1])
        }

        // ==================== Phase 1.8: --edit-script ====================
        // `--edit-script <script.txt> [--space paper] file.dxf`: runs a small
        // line-oriented edit language (see EditScriptRunner.swift for the
        // full grammar) against the NEW EntityStore/Regenerator/RegenCoordinator
        // path — the headless test harness for Phase 1.6's incremental
        // regeneration. Only plain ASCII .dxf is supported (same restriction
        // as --new-path/--db-stats: xref merging isn't wired into
        // EntityStoreParser yet). Owns process exit itself (see
        // EditScriptRunner.run), so nothing after this block runs.
        if let flagIdx = args.firstIndex(of: "--edit-script"), args.count > flagIdx + 1 {
            let scriptPath = args[flagIdx + 1]
            guard let docPath = args.last, FileManager.default.fileExists(atPath: docPath),
                  docPath.lowercased().hasSuffix(".dxf") else {
                FileHandle.standardError.write(Data(
                    "edit-script: last argument must be an existing plain ASCII .dxf file\n".utf8))
                exit(2)
            }
            let usePaper = args.contains("--space") &&
                (args.firstIndex(of: "--space").map { args.count > $0 + 1 && args[$0 + 1] == "paper" } ?? false)
            EditScriptRunner.run(scriptPath: scriptPath, documentURL: URL(fileURLWithPath: docPath), isPaper: usePaper)
            // EditScriptRunner.run always calls exit(); unreachable.
        }
        // ================== end Phase 1.8: --edit-script ===================

        // ==================== Phase 3.4: --roundtrip ====================
        // `--roundtrip out.dxf [--dxfver AC1015] file.dxf`: parse the input
        // via the new EntityStore path (`PackageLoader.loadIntoStore`, same
        // entry point RegenCoordinator/--new-path use), write it back out
        // via `DXFStructuralWriter`, re-parse the WRITTEN file, render both
        // the original and the round-tripped document, and report a
        // pixel-diff percentage plus entity/layer/group counts for both —
        // the plan's verification gate for the writer, runnable on the real
        // 731MB production fixture. Owns process exit itself.
        if let flagIdx = args.firstIndex(of: "--roundtrip"), args.count > flagIdx + 1 {
            let outPath = args[flagIdx + 1]
            guard let inPath = args.last, FileManager.default.fileExists(atPath: inPath) else {
                FileHandle.standardError.write(Data(
                    "roundtrip: usage: --roundtrip out.dxf [--dxfver AC1015] file.dxf\n".utf8))
                exit(2)
            }
            var version = DXFVersion.r2000
            if let i = args.firstIndex(of: "--dxfver"), args.count > i + 1 {
                guard let v = DXFVersion(rawValue: args[i + 1]) else {
                    FileHandle.standardError.write(Data(
                        "roundtrip: --dxfver must be one of AC1009/AC1014/AC1015/AC1018/AC1021/AC1024/AC1027/AC1032\n".utf8))
                    exit(2)
                }
                version = v
            }
            runRoundTrip(inPath: inPath, outPath: outPath, version: version)
            // runRoundTrip always calls exit(); unreachable.
        }
        // ================== end Phase 3.4: --roundtrip ===================

        if let index = args.firstIndex(of: "--export-pdf") {
            guard args.count > index + 2, let input = args.last else { exit(2) }
            do {
                let coordinator = try RegenCoordinator.loadPackage(url: URL(fileURLWithPath: input))
                let parsed = coordinator.parsed
                var sheets: [UInt64?] = parsed.paperLayouts.map { Optional($0.id) }
                if let i = args.firstIndex(of: "--layout"), args.count > i + 1 {
                    guard let sheet = parsed.paperLayouts.first(where: { $0.name == args[i + 1] }) else {
                        print("Unknown layout"); exit(2)
                    }
                    sheets = [sheet.id]
                }
                if sheets.isEmpty { sheets = [nil] }
                let warnings = try SheetPDFExporter.write(parsed, to: URL(fileURLWithPath: args[index + 1]),
                    options: PDFExportOptions(sheets: sheets, scale: args.contains("--pdf-fit") ? .fit : .pageSetup)) { done, total in
                        print("PDF page \(done)/\(total)")
                    }
                for warning in warnings { print("PDF warning: \(warning)") }
                print("PDF exported: \(args[index + 1])")
                exit(0)
            } catch { print("PDF export failed: \(error.localizedDescription)"); exit(1) }
        }

        guard let flagIdx = args.firstIndex(of: "--snapshot") else { return }
        guard args.count > flagIdx + 1 else {
            FileHandle.standardError.write(Data("usage: DWGViewer --snapshot out.png [--size WxH] [--space paper] [--light] file.dxf\n".utf8))
            exit(2)
        }
        let outPath = args[flagIdx + 1]

        var size = CGSize(width: 1600, height: 1000)
        if let i = args.firstIndex(of: "--size"), args.count > i + 1 {
            let parts = args[i + 1].lowercased().split(separator: "x")
            if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
                size = CGSize(width: w, height: h)
            }
        }
        // --renderer metal|cg: Metal doesn't exist yet (Phase 9) — this is a
        // no-op alias that always falls back to the CoreGraphics path, but
        // parsed now so scripts/harnesses written against the eventual flag
        // don't need to change once Metal lands.
        if let i = args.firstIndex(of: "--renderer"), args.count > i + 1 {
            let mode = args[i + 1].lowercased()
            if mode == "metal" {
                print("renderer: metal requested, falling back to cg (Metal engine not yet implemented)")
            } else if mode != "cg" {
                FileHandle.standardError.write(Data("snapshot: --renderer must be 'metal' or 'cg'\n".utf8))
                exit(2)
            }
        }
        let requestedLayout = args.firstIndex(of: "--layout").flatMap { i in
            args.count > i + 1 ? args[i + 1] : nil
        }
        let usePaper = requestedLayout != nil || args.contains("--space") &&
            (args.firstIndex(of: "--space").map { args.count > $0 + 1 && args[$0 + 1] == "paper" } ?? false)
        let dark = !args.contains("--light")

        guard let inPath = args.last, FileManager.default.fileExists(atPath: inPath),
              inPath.lowercased().hasSuffix(".dxf") || inPath.lowercased().hasSuffix(".dwg")
              || inPath.lowercased().hasSuffix(".zip")
              || (try? URL(fileURLWithPath: inPath).resourceValues(forKeys: [.isDirectoryKey])
                    .isDirectory) == true else {
            FileHandle.standardError.write(Data("snapshot: last argument must be an existing .dxf/.dwg/.zip file or folder\n".utf8))
            exit(2)
        }

        // --test-writer: round-trip verification of DXFWriter — writes sample
        // markup standalone + merged into the input, reloads both, reports.
        if args.contains("--test-writer") {
            let sample: [DrawnEntity] = [
                DrawnEntity(shape: .line(a: CGPoint(x: 0, y: -20), b: CGPoint(x: 46, y: -20)), aci: 1),
                DrawnEntity(shape: .rect(a: CGPoint(x: 2, y: -18), b: CGPoint(x: 12, y: -24)), aci: 3),
                DrawnEntity(shape: .circle(center: CGPoint(x: 20, y: -21), radius: 3), aci: 5),
                DrawnEntity(shape: .arc(center: CGPoint(x: 30, y: -21), radius: 3,
                                        startDeg: 20, endDeg: 200), aci: 2),
                DrawnEntity(shape: .polyline(pts: [CGPoint(x: 36, y: -24),
                                                   CGPoint(x: 40, y: -18),
                                                   CGPoint(x: 44, y: -24)], closed: false), aci: 4),
                DrawnEntity(shape: .polyline(
                    pts: DraftState.regularPolygonVertices(center: CGPoint(x: 8, y: -32),
                                                           through: CGPoint(x: 12, y: -32), sides: 6) ?? [],
                    closed: true)),
                DrawnEntity(shape: .text(position: CGPoint(x: 16, y: -34), height: 2,
                                         string: "PROPOSED FLOW"), aci: 6),
            ]
            let dir = FileManager.default.temporaryDirectory
            let markupURL = dir.appendingPathComponent("nova-test-markup.dxf")
            let mergedURL = dir.appendingPathComponent("nova-test-merged.dxf")
            do {
                try DXFWriter.writeMarkupDXF(sample, to: markupURL, insUnits: 4)
                let m = try DXFParser.parse(url: markupURL)
                print("writer: standalone markup reloads with \(m.stats.totalEntities) entities, "
                      + "layers: \(m.layers.map(\.name).joined(separator: ","))")
                try DXFWriter.writeMergedCopy(original: URL(fileURLWithPath: inPath),
                                              entities: sample, to: mergedURL)
                let g = try DXFParser.parse(url: mergedURL)
                print("writer: merged copy reloads with \(g.stats.totalEntities) entities, "
                      + "markup layer present: \(g.layers.contains { $0.name == DXFWriter.markupLayer })")
                print("writer: merged file at \(mergedURL.path)")
            } catch {
                print("writer: FAILED — \(error.localizedDescription)")
                exit(1)
            }
        }

        // --new-path: exercise EntityStoreParser + Regenerator instead of the
        // old DXFParser/GeometryBuilder path for the REST of --snapshot's
        // behavior (bounds, selection, rendering) — this is what makes an
        // apples-to-apples pixel comparison between the two paths possible
        // (same downstream rendering code, same view params, different
        // parse/regen source). Accepts the same input shapes as the old
        // path (plain .dxf/.dwg, folder, eTransmit .zip) — xref/DWG/ZIP
        // resolution routes through `PackageLoader.loadIntoStore`, the
        // EntityStore-level equivalent of `PackageLoader.load`.
        let useNewPath = args.contains("--new-path") || requestedLayout != nil

        do {
            let t0 = Date()
            var lastPct = -1
            let doc: DXFDocument
            if useNewPath {
                let parsed = try PackageLoader.loadIntoStore(url: URL(fileURLWithPath: inPath), progress: { p in
                    let pct = Int(p * 70)
                    if pct / 10 != lastPct / 10 { lastPct = pct; print("progress: \(pct)%") }
                })
                let parseSeconds = Date().timeIntervalSince(t0)
                if let requestedLayout {
                    guard let sheet = parsed.paperLayouts.first(where: {
                        $0.name.caseInsensitiveCompare(requestedLayout) == .orderedSame
                    }) else {
                        FileHandle.standardError.write(Data("snapshot: unknown sheet '\(requestedLayout)'; available: \(parsed.paperLayouts.map(\.name).joined(separator: ", "))\n".utf8))
                        exit(2)
                    }
                    parsed.activePaperLayoutID = sheet.id
                    print("sheet: \(sheet.name)")
                }
                doc = Regenerator.build(from: parsed, parseSeconds: parseSeconds) { p in
                    let pct = 70 + Int(p * 30)
                    if pct / 10 != lastPct / 10 { lastPct = pct; print("progress: \(pct)%") }
                }
            } else {
                doc = try PackageLoader.load(url: URL(fileURLWithPath: inPath)) { p in
                    let pct = Int(p * 100)
                    if pct / 10 != lastPct / 10 {
                        lastPct = pct
                        print("progress: \(pct)%")
                    }
                }
            }
            print(String(format: "parsed in %.2fs (scan %.2fs, geometry %.2fs)",
                         Date().timeIntervalSince(t0),
                         doc.stats.parseSeconds, doc.stats.buildSeconds))
            print("entities: \(doc.stats.totalEntities)")
            print("layers used: \(doc.layers.filter { $0.entityCount > 0 }.count) of \(doc.layers.count)")
            print("groups: \(doc.modelGroups.count) model, \(doc.paperGroups.count) paper")
            for x in doc.xrefs {
                print("xref: \(x.blockName) resolved=\(x.isResolved) entities=\(x.entityCount) inserts=\(x.insertCount)")
            }
            if !doc.stats.skippedTypes.isEmpty {
                let s = doc.stats.skippedTypes.sorted { $0.value > $1.value }
                    .map { "\($0.key):\($0.value)" }.joined(separator: " ")
                print("skipped: \(s)")
            }

            // --layer-counts: per-layer post-expansion entity counts, sorted
            // by name — a verification aid for diffing the old vs new parse
            // path's expansion output layer-by-layer (analogous to
            // --debug-bounds, but broken down per layer instead of globally).
            if args.contains("--layer-counts") {
                for l in doc.layers.sorted(by: { $0.name < $1.name }) where l.entityCount > 0 {
                    print("layer: \(l.name) = \(l.entityCount)")
                }
            }

            // --group-dump: one line per model-space RenderGroup (layer name,
            // color, linetype, xref, entityCount, run/arc/text/point counts) —
            // a finer-grained verification aid than --layer-counts for
            // isolating exactly which (layer, color, linetype, xref)
            // combination differs between the old and new parse paths.
            if args.contains("--group-dump") {
                for g in doc.modelGroups {
                    let lname = g.layerId < doc.layers.count ? doc.layers[g.layerId].name : "?"
                    print("group: \(lname)|\(HitTester.describe(g.color))|\(g.linetypeId)|\(g.xrefId) "
                          + "n=\(g.entityCount) runs=\(g.strokes.runs.count) arcs=\(g.strokes.arcs.count) "
                          + "texts=\(g.texts.count) pts=\(g.points.count)")
                }
            }

            // --search "query": exercise the deep-search index and print hits.
            if let i = args.firstIndex(of: "--search"), args.count > i + 1 {
                // No live EntityStore in scope here (`parsed` is local to the
                // `useNewPath` branch above) — this debug CLI path searches by
                // real block name only, matching its pre-existing behavior.
                let index = SearchIndex(document: doc)
                let hits = index.search(args[i + 1])
                print("search[\(args[i + 1])]: \(hits.count) hits (index: \(index.count) entries)")
                for h in hits.prefix(10) {
                    print(String(format: "  %@ — %@ @ (%.1f, %.1f)",
                                 h.label, h.sublabel, h.position.x, h.position.y))
                }
            }

            if args.contains("--list-stamps") {
                print("stampable blocks: \(doc.stampableBlockNames.count)")
                for name in doc.stampableBlockNames.prefix(12) {
                    print("  \(name): \(doc.blockStamps[name]?.count ?? 0) primitives")
                }
            }

            // --dump-entities: one JSON object per line (JSONL) describing every
            // primitive in the current space, from today's render-only model
            // (no handles yet — Phase 1's EntityStore rewires this to real
            // per-entity handles). The verification backbone for asserting on
            // exact entity content, not just pixels.
            if args.contains("--dump-entities") {
                dumpEntities(doc: doc, usePaper: usePaper)
            }

            let target = usePaper ? doc.paperFitBounds : doc.modelFitBounds
            if args.contains("--debug-bounds") {
                let full = usePaper ? doc.paperBounds : doc.modelBounds
                print("fullBounds: \(full)")
                print("fitBounds:  \(target)")
                let groups = usePaper ? doc.paperGroups : doc.modelGroups
                var totalRuns = 0, inFit = 0, nanRuns = 0, totalArcs = 0, arcsInFit = 0
                var sumRunW = 0.0
                for g in groups {
                    totalRuns += g.strokes.runs.count
                    totalArcs += g.strokes.arcs.count
                    for r in g.strokes.runs {
                        if r.bounds.origin.x.isNaN || r.bounds.size.width.isNaN { nanRuns += 1 }
                        else if r.bounds.intersects(target) { inFit += 1; sumRunW += r.bounds.width }
                    }
                    for arc in g.strokes.arcs where
                        CGRect(x: arc.center.x - arc.radius, y: arc.center.y - arc.radius,
                               width: arc.radius * 2, height: arc.radius * 2).intersects(target) {
                        arcsInFit += 1
                    }
                }
                print("runs: \(totalRuns) total, \(inFit) intersect fit, \(nanRuns) NaN; arcs: \(totalArcs) total, \(arcsInFit) in fit")
                print("avg run width in fit: \(sumRunW / Double(max(inFit, 1)))")
            }
            var focusTarget = target
            if let i = args.firstIndex(of: "--focus"), args.count > i + 1 {
                let parts = args[i + 1].split(separator: ",").compactMap { Double($0) }
                if parts.count == 4 {
                    focusTarget = CGRect(x: parts[0], y: parts[1],
                                         width: parts[2], height: parts[3])
                }
            }
            let fit = focusTarget
            guard fit.width > 0, fit.height > 0 else {
                FileHandle.standardError.write(Data("snapshot: empty drawing bounds\n".utf8))
                exit(1)
            }

            var params = RenderParams()
            params.viewSize = size
            params.backingScale = 2
            if let i = args.firstIndex(of: "--quality"), args.count > i + 1,
               let q = Int(args[i + 1]) {
                params.quality = q
            }
            params.zoom = min(size.width / fit.width, size.height / fit.height) * 0.94
            params.darkBackground = dark
            params.usePaperSpace = usePaper
            // Hide layers that the file marks off/frozen, matching the app defaults.
            params.visibility = VisibilityState(
                hiddenLayerIds: Set(doc.layers.filter { $0.isOffByDefault || $0.isFrozen }.map(\.id)),
                hiddenXrefIds: [])
            var t = CGAffineTransform.identity
            t = t.translatedBy(x: size.width / 2, y: size.height / 2)
            t = t.scaledBy(x: params.zoom, y: -params.zoom)
            t = t.translatedBy(x: -fit.midX, y: -fit.midY)
            params.worldToView = t

            // --select wx,wy: hit-test at a world point, print properties, and
            // render the selection highlight (end-to-end selection verification).
            if let i = args.firstIndex(of: "--select"), args.count > i + 1 {
                let parts = args[i + 1].split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 {
                    let wp = CGPoint(x: parts[0], y: parts[1])
                    let tol = 6 / params.zoom
                    if let hit = HitTester.hitTest(document: doc, usePaperSpace: usePaper,
                                                   at: wp, tolerance: tol,
                                                   visibility: params.visibility) {
                        params.selection = [hit]
                        print("selected: \(hit)")
                        for prop in HitTester.properties(for: hit, document: doc,
                                                         usePaperSpace: usePaper) {
                            print("  \(prop.name): \(prop.value)")
                        }
                    } else {
                        print("selected: nothing at \(wp) (tol \(tol))")
                    }
                }
            }

            let t1 = Date()
            guard let frame = BitmapRenderer.render(document: doc, params: params) else {
                FileHandle.standardError.write(Data("snapshot: render failed\n".utf8))
                exit(1)
            }
            print(String(format: "rendered in %.2fs (%dx%d px)",
                         Date().timeIntervalSince(t1),
                         frame.image.width, frame.image.height))

            // --exec "L;0,0;100,100;;": replay a semicolon-separated
            // command-bar script against a headless draft-tool harness (see
            // Commands/HeadlessCommandHarness.swift for exactly which
            // CommandActions are supported), then composite the resulting
            // markup onto this same frame before writing the PNG.
            var finalImage = frame.image
            if let i = args.firstIndex(of: "--exec"), args.count > i + 1 {
                let result = HeadlessCommandHarness.run(script: args[i + 1], isPaper: usePaper)
                print("exec: \(result.drawn.count) markup object(s)")
                for m in result.messages { print("exec: \(m)") }
                if !result.drawn.isEmpty,
                   let composited = compositeMarkup(result.drawn, isPaper: usePaper,
                                                     onto: frame.image, params: params) {
                    finalImage = composited
                }
            }

            let url = URL(fileURLWithPath: outPath)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                             UTType.png.identifier as CFString,
                                                             1, nil) else {
                FileHandle.standardError.write(Data("snapshot: cannot create \(outPath)\n".utf8))
                exit(1)
            }
            CGImageDestinationAddImage(dest, finalImage, nil)
            CGImageDestinationFinalize(dest)
            print("wrote \(outPath)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    // MARK: - --exec markup compositing

    /// Draws `drawn` on top of an already-rendered document bitmap using the
    /// same `worldToView`/`zoom` the document frame itself was rendered
    /// with, producing a new flattened image. Returns nil (leaving the
    /// original document-only image as the output) if a fresh bitmap context
    /// can't be created.
    private static func compositeMarkup(_ drawn: [DrawnEntity], isPaper: Bool,
                                        onto image: CGImage,
                                        params: RenderParams) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // `params.worldToView` is defined in POINTS (view space); the bitmap
        // is in PIXELS at `params.backingScale` — scale up to match, same
        // convention CGRenderCore uses internally for the document render.
        var pixelTransform = params.worldToView
        pixelTransform = pixelTransform.concatenating(
            CGAffineTransform(scaleX: params.backingScale, y: params.backingScale))
        HeadlessCommandHarness.composite(drawn, isPaper: isPaper, into: ctx,
                                         worldToView: pixelTransform,
                                         zoom: params.zoom * params.backingScale)
        return ctx.makeImage()
    }

    // MARK: - --db-stats (new EntityStore parse path)

    /// Current process resident set size, via `task_info`/`mach_task_basic_info`
    /// — the standard macOS API for "how much physical memory is this process
    /// actually using right now" (what Activity Monitor's "Memory" column shows).
    private static func currentRSSBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return info.resident_size
    }

    private static func runDBStats(path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            FileHandle.standardError.write(Data("db-stats: no such file \(path)\n".utf8))
            exit(2)
        }
        guard path.lowercased().hasSuffix(".dxf") else {
            let msg = "db-stats: only supports a plain ASCII .dxf file — xref/DWG/ZIP resolution "
                + "is not wired into EntityStoreParser yet (still PackageLoader/DXFParser-only)\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }
        do {
            let rssBefore = currentRSSBytes()
            let t0 = Date()
            let parsed = try EntityStoreParser.parse(url: URL(fileURLWithPath: path))
            let parseSeconds = Date().timeIntervalSince(t0)
            let t1 = Date()
            let doc = Regenerator.build(from: parsed, parseSeconds: parseSeconds) { _ in }
            let buildSeconds = Date().timeIntervalSince(t1)
            let rssAfter = currentRSSBytes()

            let store = parsed.store
            func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

            print(String(format: "db-stats: loaded in %.2fs (parse %.2fs, regen %.2fs)",
                         parseSeconds + buildSeconds, parseSeconds, buildSeconds))
            print("db-stats: entities \(store.count), expanded \(doc.stats.totalEntities)")
            print("--- EntityStore arenas ---")
            print("headers:        \(store.count) x \(MemoryLayout<EntityHeader>.stride) = \(mb(store.count * MemoryLayout<EntityHeader>.stride))")
            func arena<T>(_ name: String, _ a: [T]) {
                print("\(name): \(a.count) x \(MemoryLayout<T>.stride) = \(mb(a.count * MemoryLayout<T>.stride))")
            }
            arena("lines", store.lines)
            arena("points", store.points)
            arena("circles", store.circles)
            arena("arcs", store.arcs)
            arena("ellipses", store.ellipses)
            arena("polylines", store.polylines)
            arena("splines", store.splines)
            arena("texts", store.texts)
            arena("mtexts", store.mtexts)
            arena("inserts", store.inserts)
            arena("hatches", store.hatches)
            arena("images", store.images)
            arena("viewports", store.viewports)
            arena("dimensions", store.dimensions)
            arena("vertexArena", store.vertexArena)
            arena("scalarArena", store.scalarArena)
            arena("hatchLoopRanges", store.hatchLoopRanges)
            print("strings:        \(store.strings.count) entries")
            print("xdata:          \(store.xdata.count) entries")
            print("residualPairs:  \(store.residualPairs.count) entries")
            print("--- Phase 3 groundwork: structural metadata retention ---")
            print("header vars:    \(parsed.headerVars.vars.count)")
            print("classes:        \(parsed.classes.count)")
            let symbolTableCount = parsed.symbolTables.values.reduce(0) { $0 + $1.count }
            let symbolTableBreakdown = parsed.symbolTables.keys.sorted()
                .map { "\($0)=\(parsed.symbolTables[$0]?.count ?? 0)" }.joined(separator: " ")
            print("table records:  \(symbolTableCount) additional (beyond LAYER/LTYPE) — \(symbolTableBreakdown)")
            print("objects:        \(parsed.objects.totalObjectCount) total, \(parsed.objects.typedObjectCount) typed, "
                  + "\(parsed.objects.rawObjects.count) raw-fallback "
                  + "(dictionaries=\(parsed.objects.dictionaries.count) layouts=\(parsed.objects.layouts.count) "
                  + "groups=\(parsed.objects.groups.count) imageDefs=\(parsed.objects.imageDefs.count))")
            let layersWithHandles = parsed.layers.filter { $0.handle != 0 }.count
            let linetypesWithHandles = parsed.linetypes.filter { $0.handle != 0 }.count
            let blocksWithHandles = parsed.blocks.values.filter { $0.handle != 0 }.count
            print("handles:        \(layersWithHandles)/\(parsed.layers.count) layers, "
                  + "\(linetypesWithHandles)/\(parsed.linetypes.count) linetypes, "
                  + "\(blocksWithHandles)/\(parsed.blocks.count) blocks")
            print("--- process RSS ---")
            print("RSS before parse: \(mb(Int(rssBefore)))")
            print("RSS after load:   \(mb(Int(rssAfter)))")
            print("RSS delta:        \(mb(Int(rssAfter) - Int(rssBefore)))")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("db-stats: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    // MARK: - Live-load verification (Phase 1.7)

    private static func runVerifyLiveLoad(path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            FileHandle.standardError.write(Data("verify-live-load: no such path \(path)\n".utf8))
            exit(2)
        }
        do {
            let rssBefore = currentRSSBytes()
            let t0 = Date()
            let coordinator = try RegenCoordinator.loadPackage(url: URL(fileURLWithPath: path))
            let loadSeconds = Date().timeIntervalSince(t0)
            let rssAfterLoad = currentRSSBytes()
            let doc = coordinator.document

            print(String(format: "verify-live-load: loaded in %.2fs", loadSeconds))
            print("verify-live-load: entities \(coordinator.parsed.store.count), expanded \(doc.stats.totalEntities)")
            print("verify-live-load: \(doc.modelGroups.count) model groups, \(doc.paperGroups.count) paper groups, \(doc.inserts.count) inserts")
            print("verify-live-load: \(doc.xrefs.count) xref(s): "
                  + doc.xrefs.map { "\($0.blockName) resolved=\($0.isResolved) entities=\($0.entityCount) inserts=\($0.insertCount)" }.joined(separator: "; "))

            // Optional `--png <path>`: render the freshly-loaded Regenerator
            // document (the EXACT DXFDocument the live app draws) to a PNG, so
            // the load can be verified VISUALLY, not just by group/insert
            // counts. Rendered before the scripted markup edit below so it
            // shows the pure loaded drawing.
            if let pngIdx = CommandLine.arguments.firstIndex(of: "--png"),
               CommandLine.arguments.count > pngIdx + 1 {
                let pngPath = CommandLine.arguments[pngIdx + 1]
                if let img = renderFitted(doc, size: CGSize(width: 2400, height: 1600)),
                   let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: pngPath) as CFURL,
                                                              UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, img, nil)
                    CGImageDestinationFinalize(dest)
                    print("verify-live-load: wrote render \(pngPath)")
                } else {
                    print("verify-live-load: render produced no image (empty modelFitBounds?)")
                }
            }

            guard let markupLayerId = coordinator.parsed.layerIdByName[MarkupStore.layerName] else {
                FileHandle.standardError.write(Data("verify-live-load: FAIL — markup layer was not pre-registered\n".utf8))
                exit(1)
            }
            print("verify-live-load: markup layer id \(markupLayerId) (\(doc.layers[Int(markupLayerId)].name))")

            // Scripted draw -> undo -> redo, mirroring
            // DocumentSession.performEdit/undo/redo exactly, against
            // whichever space actually has content. The probe point is
            // placed OUTSIDE the drawing's own full extents entirely (a
            // fixed offset past modelBounds/paperBounds' max corner) so a
            // freshly-drawn small test circle there can never coincidentally
            // overlap real geometry and win/lose the nearest-match hit-test
            // tie ambiguously — this is a synthetic probe for THIS
            // diagnostic only, not a claim about where real markup usually
            // lands (see ContentView's actual drafting tools for that).
            let usePaper = doc.modelGroups.isEmpty && !doc.paperGroups.isEmpty
            let owner: OwnerRef = usePaper ? .paper : .model
            let fullBounds = usePaper ? doc.paperBounds : doc.modelBounds
            let probe = CGPoint(x: fullBounds.maxX + 1000, y: fullBounds.maxY + 1000)

            var addedId: EntityID!
            coordinator.parsed.document.transact("Draw") { tx in
                addedId = tx.add(EntityPrototype(type: .circle, layerId: markupLayerId, owner: owner,
                                                 payload: .circle(CirclePayload(center: Vec3(x: Double(probe.x), y: Double(probe.y)), radius: 10))))
            }
            let addDelta = coordinator.apply(coordinator.parsed.document.undoStack.last!.ops)
            let afterAddHit = HitTester.hitTestEntityID(document: doc, usePaperSpace: usePaper, at: probe,
                                                        tolerance: 15, visibility: VisibilityState())
            guard afterAddHit == addedId else {
                FileHandle.standardError.write(Data("verify-live-load: FAIL — freshly drawn circle not hit-testable (fullRebuild=\(addDelta.fullRebuild))\n".utf8))
                exit(1)
            }
            print("verify-live-load: draw+apply OK (fullRebuild=\(addDelta.fullRebuild), appended \(addDelta.appendedModelGroups.count + addDelta.appendedPaperGroups.count) group(s))")

            coordinator.parsed.document.undo()
            coordinator.fullRebuild()
            let afterUndoHit = HitTester.hitTestEntityID(document: coordinator.document, usePaperSpace: usePaper, at: probe,
                                                         tolerance: 15, visibility: VisibilityState())
            guard afterUndoHit == nil else {
                FileHandle.standardError.write(Data("verify-live-load: FAIL — undo did not remove the drawn circle\n".utf8))
                exit(1)
            }
            print("verify-live-load: undo OK")

            coordinator.parsed.document.redo()
            coordinator.fullRebuild()
            let afterRedoHit = HitTester.hitTestEntityID(document: coordinator.document, usePaperSpace: usePaper, at: probe,
                                                         tolerance: 15, visibility: VisibilityState())
            guard afterRedoHit == addedId else {
                FileHandle.standardError.write(Data("verify-live-load: FAIL — redo did not restore the drawn circle\n".utf8))
                exit(1)
            }
            print("verify-live-load: redo OK")

            // Whole-block ("orphan root"/INSERT) selection resolution — the
            // known gap this phase closed (InsertInstance.entityId +
            // HitTester.resolveEntityID). Only meaningful if the file
            // actually has any top-level inserts; skipped (not failed)
            // otherwise so this flag stays usable on markup-only fixtures.
            if let firstInsert = doc.inserts.first {
                let ref = EntityRef.insert(0)
                let resolved = HitTester.resolveEntityID(ref, document: doc, usePaperSpace: false)
                guard resolved?.raw == firstInsert.entityId, firstInsert.entityId >= 0 else {
                    FileHandle.standardError.write(Data(
                        "verify-live-load: FAIL — top-level INSERT did not resolve to a stable EntityID\n".utf8))
                    exit(1)
                }
                print("verify-live-load: INSERT->EntityID resolution OK (\(doc.inserts.count) top-level inserts)")
            } else {
                print("verify-live-load: no top-level inserts in this file — INSERT resolution check skipped")
            }

            let rssAfterAll = currentRSSBytes()
            func mb(_ bytes: UInt64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
            // NOTE: on a large file, RSS typically rises noticeably across
            // the undo/redo fullRebuild() calls above and then PLATEAUS —
            // this is the macOS allocator not eagerly returning freed pages
            // from the old (now-deallocated) DXFDocument to the OS after a
            // large, short-lived allocation burst, not a leak (verified by
            // calling Regenerator.build several times in a row and
            // confirming RSS stabilizes rather than growing indefinitely;
            // this behavior predates Phase 1.7 and is inherent to
            // Regenerator.build's allocation pattern, not something the
            // RegenCoordinator/undo-redo wiring introduced). Reported here
            // as a real number for the user's own judgment, not asserted
            // against a hard threshold — a true leak would keep climbing on
            // every single rebuild instead of stabilizing after 2-3.
            print("verify-live-load: RSS before=\(mb(rssBefore)) afterLoad=\(mb(rssAfterLoad)) afterUndoRedo=\(mb(rssAfterAll))")
            print("verify-live-load: ALL CHECKS PASSED")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-live-load: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    // MARK: - Structural DXF writer round-trip verification (Phase 3.4)

    /// Renders `doc` fitted to its own model-space extents at a fixed
    /// resolution — same framing convention `--snapshot` uses (94% fill,
    /// centered) so two documents' renders are pixel-comparable as long as
    /// their geometry actually matches.
    private static func renderFitted(_ doc: DXFDocument, size: CGSize) -> CGImage? {
        let fit = doc.modelFitBounds
        guard fit.width > 0, fit.height > 0 else { return nil }
        var params = RenderParams()
        params.viewSize = size
        params.backingScale = 2
        params.zoom = min(size.width / fit.width, size.height / fit.height) * 0.94
        params.darkBackground = true
        params.visibility = VisibilityState(
            hiddenLayerIds: Set(doc.layers.filter { $0.isOffByDefault || $0.isFrozen }.map(\.id)),
            hiddenXrefIds: [])
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: size.width / 2, y: size.height / 2)
        t = t.scaledBy(x: params.zoom, y: -params.zoom)
        t = t.translatedBy(x: -fit.midX, y: -fit.midY)
        params.worldToView = t
        return BitmapRenderer.render(document: doc, params: params)?.image
    }

    /// Pixel-diff between two same-size `CGImage`s — the in-memory
    /// equivalent of `compareImages`'s file-based comparison (that function
    /// owns process exit and reads PNGs from disk; this returns a plain
    /// percentage so `runRoundTrip` can print it alongside other stats
    /// without exiting early).
    private static func pixelDiffPercent(_ a: CGImage, _ b: CGImage) -> Double? {
        guard a.width == b.width, a.height == b.height else { return nil }
        let w = a.width, h = a.height
        func rgba(_ img: CGImage) -> [UInt8]? {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = buf.withUnsafeMutableBytes({ ptr -> CGContext? in
                CGContext(data: ptr.baseAddress, width: w, height: h,
                         bitsPerComponent: 8, bytesPerRow: w * 4,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            }) else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buf
        }
        guard let da = rgba(a), let db = rgba(b) else { return nil }
        var diffCount = 0
        for i in stride(from: 0, to: da.count, by: 4) {
            if abs(Int(da[i]) - Int(db[i])) > 1 || abs(Int(da[i + 1]) - Int(db[i + 1])) > 1
                || abs(Int(da[i + 2]) - Int(db[i + 2])) > 1 || abs(Int(da[i + 3]) - Int(db[i + 3])) > 1 {
                diffCount += 1
            }
        }
        return Double(diffCount) / Double(max(w * h, 1)) * 100
    }

    /// `--roundtrip out.dxf [--dxfver AC1015] file.dxf`: parse -> write ->
    /// re-parse -> render both -> pixel-diff + counts. See the flag's
    /// registration site above for the full doc comment.
    private static func runRoundTrip(inPath: String, outPath: String, version: DXFVersion) {
        do {
            print("roundtrip: parsing \(inPath)")
            let t0 = Date()
            let parsedIn = try PackageLoader.loadIntoStore(url: URL(fileURLWithPath: inPath))
            let parseSeconds = Date().timeIntervalSince(t0)
            let docBefore = Regenerator.build(from: parsedIn, parseSeconds: parseSeconds) { _ in }
            print(String(format: "roundtrip: parsed in %.2fs — entities %d, layers %d, groups %d model / %d paper",
                         parseSeconds, parsedIn.store.count, parsedIn.layers.count,
                         docBefore.modelGroups.count, docBefore.paperGroups.count))

            print("roundtrip: writing \(outPath) (version \(version.rawValue))")
            // Peak-RSS-during-WRITE instrumentation (Phase 3 item 1
            // verification: the 4MB chunked-flush fix's whole point is
            // bounded memory during the write phase specifically — `/usr/bin/time
            // -l`'s "maximum resident set size" measures the ENTIRE process
            // lifetime, which also includes parsing the ~2M-entity source
            // file into EntityStore beforehand and re-parsing + rendering
            // afterward, both of which legitimately hold much more memory
            // than the write phase itself and would swamp a whole-process
            // number). A lightweight background poller samples RSS every
            // 50ms for just the duration of the `write` call below and
            // reports the max — additive instrumentation only, no effect on
            // the write path itself.
            let rssBeforeWrite = currentRSSBytes()
            let rssTracker = PeakRSSTracker(initial: rssBeforeWrite)
            DispatchQueue.global(qos: .utility).async {
                while !rssTracker.isDone {
                    rssTracker.recordSample(currentRSSBytes())
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            let t1 = Date()
            let warnings = try DXFStructuralWriter.write(parsedIn, to: URL(fileURLWithPath: outPath),
                                                         options: DXFWriteOptions(version: version))
            let writeSeconds = Date().timeIntervalSince(t1)
            rssTracker.markDone()
            Thread.sleep(forTimeInterval: 0.1)   // let the sampler take one final reading
            rssTracker.recordSample(currentRSSBytes())
            let peakDuringWrite = rssTracker.peak
            let outSize = (try? FileManager.default.attributesOfItem(atPath: outPath)[.size] as? Int) ?? nil
            let inSize = (try? FileManager.default.attributesOfItem(atPath: inPath)[.size] as? Int) ?? nil
            print(String(format: "roundtrip: wrote in %.2fs (%@)", writeSeconds,
                         outSize.map { String(format: "%.1f MB", Double($0) / 1_048_576) } ?? "size unknown"))
            print(String(format: "roundtrip: RSS before write = %.1f MB, peak RSS DURING write = %.1f MB, "
                         + "delta = %.1f MB (source file is %.1f MB)",
                         Double(rssBeforeWrite) / 1_048_576, Double(peakDuringWrite) / 1_048_576,
                         Double(peakDuringWrite &- rssBeforeWrite) / 1_048_576,
                         Double(inSize ?? 0) / 1_048_576))
            if !warnings.isEmpty {
                print("roundtrip: \(warnings.count) write warning(s):")
                for w in warnings.prefix(20) { print("  - \(w.message)") }
                if warnings.count > 20 { print("  ... and \(warnings.count - 20) more") }
            } else {
                print("roundtrip: 0 write warnings")
            }

            print("roundtrip: re-parsing \(outPath)")
            let t2 = Date()
            let parsedOut = try PackageLoader.loadIntoStore(url: URL(fileURLWithPath: outPath))
            let reparseSeconds = Date().timeIntervalSince(t2)
            let docAfter = Regenerator.build(from: parsedOut, parseSeconds: reparseSeconds) { _ in }
            print(String(format: "roundtrip: re-parsed in %.2fs — entities %d, layers %d, groups %d model / %d paper",
                         reparseSeconds, parsedOut.store.count, parsedOut.layers.count,
                         docAfter.modelGroups.count, docAfter.paperGroups.count))

            let entityDelta = parsedOut.store.count - parsedIn.store.count
            print("roundtrip: entity count delta (after - before) = \(entityDelta)"
                  + (entityDelta == 0 ? " (exact match)" : ""))

            let size = CGSize(width: 1600, height: 1000)
            print("roundtrip: rendering both documents for pixel comparison")
            let imgBefore = renderFitted(docBefore, size: size)
            let imgAfter = renderFitted(docAfter, size: size)
            if let a = imgBefore, let b = imgAfter, let pct = pixelDiffPercent(a, b) {
                print(String(format: "roundtrip: pixel diff = %.4f%% of %dx%d px", pct, a.width, a.height))
            } else {
                print("roundtrip: pixel diff = N/A (render failed or empty bounds on one/both documents)")
            }

            print("roundtrip: DONE")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("roundtrip: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    // MARK: - Entity dump

    private struct EntityDump: Encodable {
        var type: String
        var layer: String
        var points: [[Double]]?
        var closed: Bool?
        var center: [Double]?
        var radius: Double?
        var startDeg: Double?
        var endDeg: Double?
        var text: String?
        var height: Double?
        var rotation: Double?
        var scaleX: Double?
        var scaleY: Double?
        var name: String?
    }

    private static func dumpEntities(doc: DXFDocument, usePaper: Bool) {
        let groups = usePaper ? doc.paperGroups : doc.modelGroups
        let encoder = JSONEncoder()
        func emit(_ d: EntityDump) {
            guard let data = try? encoder.encode(d),
                  let s = String(data: data, encoding: .utf8) else { return }
            print(s)
        }
        func layerName(_ id: Int) -> String {
            id >= 0 && id < doc.layers.count ? doc.layers[id].name : "?"
        }

        for g in groups {
            let layer = layerName(g.layerId)
            for run in g.strokes.runs {
                let s = Int(run.start), c = Int(run.count)
                let pts = (s..<(s + c)).map {
                    [Double(g.strokes.points[$0].x), Double(g.strokes.points[$0].y)]
                }
                emit(EntityDump(type: run.kind.label, layer: layer, points: pts, closed: run.closed))
            }
            for arc in g.strokes.arcs {
                emit(EntityDump(type: arc.isFullCircle ? "Circle" : "Arc", layer: layer,
                                center: [Double(arc.center.x), Double(arc.center.y)],
                                radius: Double(arc.radius),
                                startDeg: arc.startAngleDeg, endDeg: arc.endAngleDeg))
            }
            for t in g.texts {
                emit(EntityDump(type: t.kind.label, layer: layer,
                                points: [[Double(t.position.x), Double(t.position.y)]],
                                text: t.text, height: Double(t.height), rotation: t.rotationDegrees))
            }
            for p in g.points {
                emit(EntityDump(type: "Point", layer: layer,
                                points: [[Double(p.x), Double(p.y)]]))
            }
        }
        for (i, ins) in doc.inserts.enumerated() {
            guard (i >= doc.modelInsertCount) == usePaper else { continue }
            emit(EntityDump(type: "Insert", layer: layerName(Int(ins.layerId)),
                            points: [[Double(ins.position.x), Double(ins.position.y)]],
                            rotation: ins.rotationDegrees,
                            scaleX: Double(ins.scaleX), scaleY: Double(ins.scaleY),
                            name: ins.name))
        }
    }

    // MARK: - Image comparison

    private static func loadRGBA(_ path: String) -> (width: Int, height: Int, data: [UInt8])? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = buf.withUnsafeMutableBytes({ ptr -> CGContext? in
            CGContext(data: ptr.baseAddress, width: w, height: h,
                     bitsPerComponent: 8, bytesPerRow: w * 4,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, buf)
    }

    /// `--compare a.png b.png [--tolerance N]`: counts pixels whose RGBA differ
    /// by more than 1 (rounding slop) and exits 0 if that count is <= tolerance
    /// (default 0 — exact match), else 1. Prints the count either way.
    private static func compareImages(_ pathA: String, _ pathB: String, tolerance: Int) -> Never {
        guard let a = loadRGBA(pathA), let b = loadRGBA(pathB) else {
            FileHandle.standardError.write(Data("compare: could not decode one or both images\n".utf8))
            exit(2)
        }
        guard a.width == b.width, a.height == b.height else {
            print("compare: size mismatch \(a.width)x\(a.height) vs \(b.width)x\(b.height)")
            exit(1)
        }
        var diffCount = 0
        for i in stride(from: 0, to: a.data.count, by: 4) {
            if abs(Int(a.data[i]) - Int(b.data[i])) > 1
                || abs(Int(a.data[i + 1]) - Int(b.data[i + 1])) > 1
                || abs(Int(a.data[i + 2]) - Int(b.data[i + 2])) > 1
                || abs(Int(a.data[i + 3]) - Int(b.data[i + 3])) > 1 {
                diffCount += 1
            }
        }
        let totalPixels = a.width * a.height
        let pct = Double(diffCount) / Double(max(totalPixels, 1)) * 100
        print("compare: \(diffCount)/\(totalPixels) pixels differ (\(String(format: "%.3f", pct))%), tolerance \(tolerance)")
        exit(diffCount > tolerance ? 1 : 0)
    }

    /// Exercises MeasureFormat across styles/systems (`--test-units`).
    private static func testUnits() {
        // Drawing authored in inches (INSUNITS 1). 66 in = 5'-6"; 66.5 in.
        var f = MeasureFormat(insUnits: 1)
        f.style = .architectural; f.precision = 4
        print("arch 66:      \(f.length(66))          (expect 5'-6\")")
        print("arch 66.5:    \(f.length(66.5))        (expect 5'-6-1/2\")")
        print("arch 30.25:   \(f.length(30.25))       (expect 2'-6-1/4\")")
        f.style = .engineering; f.precision = 2
        print("eng 66.5:     \(f.length(66.5))        (expect 5'-6.50\")")
        f.style = .fractional; f.precision = 4
        print("frac 6.5:     \(f.length(6.5))         (expect 6 1/2)")
        f.style = .decimal; f.precision = 2; f.system = .metric
        print("dec metric 1: \(f.length(1))           (expect 25.40 mm)")
        f.system = .imperial
        print("dec imp 1:    \(f.length(1))           (expect 1.00 in)")
        f.system = .asDrawn
        print("dec drawn 1:  \(f.length(1))           (expect 1.00 in)")
        f.style = .architectural; f.precision = 4
        print("area 144in^2: \(f.area(144))           (expect 144.00 in\u{00B2} = 1 sq ft)")
        print("angle 91.25:  \(f.angle(91.25))")
        // Metric drawing (mm). 1000 mm.
        var g = MeasureFormat(insUnits: 4)
        g.style = .decimal; g.precision = 1; g.system = .metric
        print("mm dec 1000:  \(g.length(1000))        (expect 1000.0 mm)")
        g.system = .imperial
        print("mm->in 25.4:  \(g.length(25.4))        (expect 1.00 in)")
    }
}
