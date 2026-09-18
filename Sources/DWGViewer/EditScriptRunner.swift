import Foundation
import CADCore
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Phase 1.8: a headless, scriptable test harness for the Phase 1.6
/// incremental-regen machinery — `SnapshotMode --edit-script <path> file.dxf`
/// runs a small line-oriented command language against a live
/// `RegenCoordinator` session (parse -> edit -> undo/redo -> compact ->
/// snapshot -> assert), entirely off the `EntityStoreParser`/`Regenerator`/
/// `RegenCoordinator` path — no UI, no DXFCanvasView, nothing app-side.
///
/// Grammar (whitespace-tokenized, `#` comment lines and blank lines ignored):
/// ```
/// line x1,y1 x2,y2 | circle cx,cy r | text x,y h STR | erase x,y | move x,y dx,dy
/// select x,y | select-box x1,y1,x2,y2 | undo | redo | compact | save PATH [VER]
/// snapshot PATH | assert-count TYPE N | assert-rss MB
///
/// Phase 4.1/4.2 additions (selection engine + MOVE/COPY/ROTATE/SCALE/MIRROR):
/// select-window x1,y1,x2,y2 | select-crossing x1,y1,x2,y2
/// select-lasso x1,y1;x2,y2;x3,y3;... | select-fence x1,y1;x2,y2;...
/// copy dx,dy | rotate cx,cy deg | scale cx,cy factor | mirror x1,y1 x2,y2
/// assert-selection-count N | assert-geometry-equal ID1 ID2 [TOL]
/// ```
/// The transform verbs (copy/rotate/scale/mirror, alongside the pre-existing
/// move) all act on the CURRENT `selection` (set by a prior `select*`
/// command) — there is no separate "verb x,y ..." single-entity form for
/// these the way `move x,y dx,dy` supports as a fallback, since a scripted
/// test always wants to `select-*` first for repeatability.
///
/// Phase 4.3 additions (TRIM/EXTEND):
/// ```
/// trim x,y [ALL] | extend x,y [ALL] | trim-fence x1,y1;x2,y2;...
/// assert-entity-exists ID | assert-entity-deleted ID
/// ```
/// `trim`/`extend` act on whatever entity is at `(x,y)` (mirroring `move`'s
/// own "act on the entity at this point" convention, not the transform
/// verbs' "act on CURRENT selection" convention — TRIM/EXTEND's real
/// interaction is inherently per-click, not a batch, so this matches the
/// live app's own semantics exactly rather than introducing a scripted-only
/// shape). The CUTTING/BOUNDARY edge set is the CURRENT `selection` (set by
/// a prior `select*` command) UNLESS the literal token `ALL` is passed as a
/// 3rd argument, which resolves boundaries LAZILY per target via
/// `BoundaryResolver` exactly like the live app's Enter-for-all-visible
/// gesture — this is the form the performance-verification script (see the
/// phase's final report) uses against the real 3.4M-entity fixture to
/// confirm boundary resolution never scans the whole document.
/// `trim-fence` batches every entity the fence polyline crosses, exactly
/// like the live app's lasso-drag-during-pickingTargets gesture.
///
/// Phase 4.4 additions (FILLET/CHAMFER):
/// ```
/// fillet x1,y1 x2,y2 radius | chamfer x1,y1 x2,y2 d1 d2
/// ```
/// Both take one click point per line (LINE entities only, matching the
/// live app's Phase 4.4 scope) and always trim (TRIMMODE=1 behavior) — this
/// harness has no SysVars instance to script TRIMMODE=0 through; that
/// specific behavior is covered by `FilletChamferExecutorTests` instead.
///
/// Phase 4.5 additions (OFFSET):
/// ```
/// offset x,y distance side_x,side_y | offset-through x,y through_x,through_y
/// ```
///
/// Phase 6.1/6.2 additions (BLOCK/INSERT/ATTDEF/ATTEDIT/EXPLODE):
/// ```
/// block NAME bx,by | insert NAME x,y [sx sy rot] | attr INSERT_ID TAG=VALUE
/// explode x,y | assert-block-exists NAME [entityCount]
/// ```
/// `block` blockifies the CURRENT `selection` (set by a prior `select*`
/// command) rebased to `bx,by`, matching the transform verbs' (copy/
/// rotate/scale/mirror) "act on current selection" convention rather than
/// `move`'s "act on the entity at this point" one — a BLOCK operation is
/// inherently a multi-object batch, so there is no useful single-point
/// form. `insert` places a new INSERT of an already-registered block by
/// name (register one first via `block`, or by loading a real file that
/// already defines it) — the OPTIONAL `sx sy rot` trailing args default to
/// (1,1,0) when omitted. `explode` acts on the entity AT `x,y` (mirroring
/// `move`'s per-click convention) and falls back to the CURRENT selection
/// when nothing resolves at that point (mirroring `move`'s own fallback),
/// so a real-file large-INSERT stress test can `select x,y` (to pick one
/// specific top-level INSERT precisely) then `explode x,y` at the SAME
/// point for a scripted, repeatable target. `attr` sets one ATTRIB's value
/// by tag on an already-placed INSERT (found by `EntityID.raw`, e.g. from
/// a preceding verb's own printed "id N" — `insert`/`block` both print and
/// select their new entity's id for this purpose).
///
/// Phase 6.4 additions (ARRAY):
/// ```
/// array-rect rows cols rowSpacing colSpacing [axisAngleDeg]
/// array-polar cx,cy count fillAngleDeg [rotateItems(0|1)]
/// array-edit ANCHOR_ID rect rows cols rowSpacing colSpacing [axisAngleDeg]
/// array-edit ANCHOR_ID polar cx,cy count fillAngleDeg [rotateItems(0|1)]
/// assert-array-exists ANCHOR_ID [memberCount]
/// ```
/// `array-rect`/`array-polar` act on the CURRENT `selection` (set by a
/// prior `select*` command), matching `block`'s own "act on current
/// selection" convention — both register the resulting `ArrayDefinition`
/// under an ANCHOR id (the first selected entity, same convention the live
/// app's `commitArrayFromCurrentFields` uses) in this session's own
/// `arrays` table, printed via `assert-array-exists`'s own output and
/// reusable by a later `array-edit ANCHOR_ID ...` line in the SAME script.
///
/// Deviations from the plan's grammar, and why (see also the final
/// implementation report): `save`/`load` are NOT DXF serialization — there is
/// no DXF writer yet (Phase 3). `save PATH [VER]` checkpoints the
/// `EntityStore`'s structural state in memory (see `EntityStore.checkpoint()`)
/// keyed by `PATH`, and ALSO writes a tiny human-readable marker file at
/// `PATH` (entity count + revision) so the argument is a real, inspectable
/// file on disk, not a silent no-op; `[VER]` is accepted and echoed into
/// that marker file but doesn't otherwise affect behavior (there is only one
/// schema version today). There is no `load` verb in the grammar as given —
/// restoring a checkpoint is exercised via `compact` + `undo`, which is what
/// the plan's own test list ("undo across forced compact restores") actually
/// requires; `save` mainly proves the checkpoint/restore machinery itself
/// works, which the accompanying unit tests exercise directly.
enum EditScriptRunner {

    struct ScriptError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// One parsed line, kept as raw tokens — each command validates its own
    /// arity so a malformed line produces a precise error pointing at the
    /// offending line number.
    private struct Line {
        let number: Int
        let tokens: [String]
    }

    /// Runs `scriptPath` against a freshly loaded `url`, printing progress /
    /// results to stdout exactly like the rest of `SnapshotMode`, and exits
    /// the process (0 on success, 1 on any script error or failed assertion)
    /// — matching every other `SnapshotMode` entry point's convention of
    /// owning process exit.
    static func run(scriptPath: String, documentURL: URL, isPaper: Bool) -> Never {
        do {
            let coordinator = try RegenCoordinator.load(url: documentURL)
            var session = Session(coordinator: coordinator, isPaper: isPaper)
            let lines = try readLines(scriptPath)
            for line in lines {
                try session.execute(line.tokens, lineNumber: line.number)
            }
            print("edit-script: \(lines.count) command(s) OK")
            exit(0)
        } catch let e as ScriptError {
            FileHandle.standardError.write(Data("edit-script: \(e.message)\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("edit-script: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func readLines(_ path: String) throws -> [Line] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            throw ScriptError(message: "cannot read script file \(path)")
        }
        var result: [Line] = []
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            result.append(Line(number: i + 1, tokens: tokens))
        }
        return result
    }

    // MARK: - Geometry comparison (`assert-geometry-equal`)

    /// Compares two payloads' world-space coordinates within `tol`, ignoring
    /// non-geometric fields (arena bookkeeping like `vertsStart`, which
    /// legitimately differs between any two distinct entities) — used by
    /// scripted round-trip checks like "ROTATE 90 twice equals ROTATE 180
    /// once" and "MIRROR twice returns to the original," which compare a
    /// transformed entity's ACTUAL geometry against a reference, not just a
    /// rendered snapshot.
    static func payloadsApproximatelyEqual(_ a: EntityPayloadCopy, _ b: EntityPayloadCopy, tol: Double) -> Bool {
        func close(_ x: Double, _ y: Double) -> Bool { abs(x - y) <= tol }
        func closeV(_ x: Vec3, _ y: Vec3) -> Bool { close(x.x, y.x) && close(x.y, y.y) && close(x.z, y.z) }

        switch (a, b) {
        case (.line(let pa), .line(let pb)):
            return closeV(pa.a, pb.a) && closeV(pa.b, pb.b)
        case (.point(let pa), .point(let pb)):
            return closeV(pa.p, pb.p)
        case (.circle(let pa), .circle(let pb)):
            return closeV(pa.center, pb.center) && close(pa.radius, pb.radius)
        case (.arc(let pa), .arc(let pb)):
            return closeV(pa.center, pb.center) && close(pa.radius, pb.radius)
                && close(pa.startAngleDeg, pb.startAngleDeg) && close(pa.endAngleDeg, pb.endAngleDeg)
        case (.ellipse(let pa), .ellipse(let pb)):
            return closeV(pa.center, pb.center) && closeV(pa.majorAxisEndpoint, pb.majorAxisEndpoint)
                && close(pa.ratio, pb.ratio) && close(pa.startParam, pb.startParam) && close(pa.endParam, pb.endParam)
        case (.polyline(_, let va, let ba), .polyline(_, let vb, let bb)):
            guard va.count == vb.count, ba.count == bb.count else { return false }
            return zip(va, vb).allSatisfy { closeV($0, $1) } && zip(ba, bb).allSatisfy { close($0, $1) }
        case (.spline(let pa, let ca, _, _), .spline(let pb, let cb, _, _)):
            guard ca.count == cb.count, pa.degree == pb.degree else { return false }
            return zip(ca, cb).allSatisfy { closeV($0, $1) }
        case (.text(let pa), .text(let pb)):
            return closeV(pa.position, pb.position) && close(pa.height, pb.height) && close(pa.rotationDeg, pb.rotationDeg)
        case (.mtext(let pa), .mtext(let pb)):
            return closeV(pa.insertion, pb.insertion) && close(pa.height, pb.height) && close(pa.rotationDeg, pb.rotationDeg)
        case (.insert(let pa), .insert(let pb)):
            return closeV(pa.position, pb.position) && close(pa.rotationDeg, pb.rotationDeg)
                && close(pa.scale.x, pb.scale.x) && close(pa.scale.y, pb.scale.y)
        case (.hatch(let pa, let la), .hatch(let pb, let lb)):
            guard la.count == lb.count else { return false }
            return closeV(pa.origin, pb.origin)
                && zip(la, lb).allSatisfy { loopA, loopB in
                    loopA.count == loopB.count && zip(loopA, loopB).allSatisfy { closeV($0, $1) }
                }
        case (.unknown, .unknown):
            return true
        default:
            return false
        }
    }

    // MARK: - Session state

    private struct Session {
        let coordinator: RegenCoordinator
        let isPaper: Bool
        var selection: Set<EntityID> = []
        /// PATH -> checkpointed EntityStore state, per `save`.
        var checkpoints: [String: EntityStore.Checkpoint] = [:]
        var visibility = VisibilityState()
        /// Phase 6.4: ARRAY's associativity side-table, mirroring
        /// `DocumentSession.arrays` in the live app — keyed by whatever
        /// anchor id `array-rect`/`array-polar`/`array-edit` chose (the
        /// first source entity, same convention as the live app's
        /// `commitArrayFromCurrentFields`).
        var arrays: [EntityID: ArrayDefinition] = [:]

        var owner: OwnerRef { isPaper ? .paper : .model }
        var space: SpaceID { isPaper ? .paper : .model }

        mutating func execute(_ tokens: [String], lineNumber: Int) throws {
            guard let cmd = tokens.first else { return }
            func fail(_ msg: String) -> ScriptError {
                ScriptError(message: "line \(lineNumber): \(msg)")
            }

            switch cmd {
            case "line":
                guard tokens.count == 3, let a = parsePoint(tokens[1]), let b = parsePoint(tokens[2]) else {
                    throw fail("usage: line x1,y1 x2,y2")
                }
                let t0 = Date()
                coordinator.parsed.document.transact("Line") { tx in
                    _ = tx.add(EntityPrototype(type: .line, layerId: 0, owner: owner,
                                               payload: .line(LinePayload(a: Vec3(a), b: Vec3(b)))))
                }
                applyLastCommit(t0, label: "line")

            case "circle":
                guard tokens.count == 3, let c = parsePoint(tokens[1]), let r = Double(tokens[2]) else {
                    throw fail("usage: circle cx,cy r")
                }
                let t0 = Date()
                coordinator.parsed.document.transact("Circle") { tx in
                    _ = tx.add(EntityPrototype(type: .circle, layerId: 0, owner: owner,
                                               payload: .circle(CirclePayload(center: Vec3(c), radius: r))))
                }
                applyLastCommit(t0, label: "circle")

            case "text":
                guard tokens.count >= 4, let p = parsePoint(tokens[1]), let h = Double(tokens[2]) else {
                    throw fail("usage: text x,y h STR")
                }
                let str = tokens[3...].joined(separator: " ")
                let t0 = Date()
                coordinator.parsed.document.transact("Text") { tx in
                    let sid = coordinator.parsed.store.strings.intern(str)
                    _ = tx.add(EntityPrototype(type: .text, layerId: 0, owner: owner,
                                               payload: .text(TextPayload(position: Vec3(p), height: h, stringId: sid))))
                }
                applyLastCommit(t0, label: "text")

            case "erase":
                guard tokens.count == 2, let p = parsePoint(tokens[1]) else {
                    throw fail("usage: erase x,y")
                }
                guard let id = pickEntity(at: p) else {
                    print("edit-script: erase — nothing at \(tokens[1])")
                    return
                }
                let t0 = Date()
                coordinator.parsed.document.transact("Erase") { tx in tx.delete(id) }
                applyLastCommit(t0, label: "erase")
                selection.remove(id)

            case "move":
                guard tokens.count == 3, let p = parsePoint(tokens[1]), let d = parsePoint(tokens[2]) else {
                    throw fail("usage: move x,y dx,dy")
                }
                // Move whatever is currently selected if the selection is
                // non-empty AND contains something near `p` conceptually —
                // per the grammar's spirit ("move x,y dx,dy") this moves the
                // entity AT (x,y); a bulk move is expressed by first
                // `select-box`-ing a region, then issuing one `move` per
                // pixel is impractical, so: if the current selection is
                // non-empty, `move` translates the WHOLE selection by
                // (dx,dy) and (x,y) is used only as a fallback pick point
                // when selection is empty. This is what lets a scripted
                // `select-box ...` + `move ...` move thousands of entities
                // in one commit, matching the plan's "10k-entity scripted
                // move" perf scenario.
                let ids: [EntityID]
                if !selection.isEmpty {
                    ids = Array(selection)
                } else if let id = pickEntity(at: p) {
                    ids = [id]
                } else {
                    print("edit-script: move — nothing at \(tokens[1]) and no active selection")
                    return
                }
                let dx = Double(d.x), dy = Double(d.y)
                let t0 = Date()
                coordinator.parsed.document.transact("Move") { tx in
                    for id in ids {
                        tx.modifyPayload(id) { copy in copy.translate(dx: dx, dy: dy) }
                    }
                }
                applyLastCommit(t0, label: "move (\(ids.count) entities)")

            case "select":
                guard tokens.count == 2, let p = parsePoint(tokens[1]) else {
                    throw fail("usage: select x,y")
                }
                if let id = pickEntity(at: p) {
                    selection = [id]
                    print("edit-script: select — 1 entity (id \(id.raw))")
                } else {
                    selection = []
                    print("edit-script: select — nothing at \(tokens[1])")
                }

            case "select-box":
                guard tokens.count == 2 else { throw fail("usage: select-box x1,y1,x2,y2") }
                let parts = tokens[1].split(separator: ",").compactMap { Double($0) }
                guard parts.count == 4 else { throw fail("usage: select-box x1,y1,x2,y2") }
                let rect = CGRect(x: min(parts[0], parts[2]), y: min(parts[1], parts[3]),
                                  width: abs(parts[2] - parts[0]), height: abs(parts[3] - parts[1]))
                selection = HitTester.boxSelectEntityIDs(document: coordinator.document, usePaperSpace: isPaper,
                                                         rect: rect, visibility: visibility)
                print("edit-script: select-box — \(selection.count) entities")

            // Phase 4.1: explicit Window/Crossing rect selection through the
            // new SelectionEngine (select-box above stays as the legacy
            // Window-only alias via HitTester directly, unchanged).
            case "select-window", "select-crossing":
                guard tokens.count == 2 else { throw fail("usage: \(cmd) x1,y1,x2,y2") }
                let parts = tokens[1].split(separator: ",").compactMap { Double($0) }
                guard parts.count == 4 else { throw fail("usage: \(cmd) x1,y1,x2,y2") }
                let rect = CGRect(x: min(parts[0], parts[2]), y: min(parts[1], parts[3]),
                                  width: abs(parts[2] - parts[0]), height: abs(parts[3] - parts[1]))
                let mode: SelectionMode = cmd == "select-window" ? .window : .crossing
                let t0 = Date()
                selection = SelectionEngine.rectSelect(document: coordinator.document, usePaperSpace: isPaper,
                                                       rect: rect, mode: mode, visibility: visibility)
                let ms = Date().timeIntervalSince(t0) * 1000
                print(String(format: "edit-script: %@ — %.2fms, %d entities", cmd, ms, selection.count))

            case "select-lasso", "select-fence":
                guard tokens.count == 2 else { throw fail("usage: \(cmd) x1,y1;x2,y2;x3,y3;...") }
                let pts = tokens[1].split(separator: ";").compactMap { parsePoint(String($0)) }
                guard pts.count >= 2 else { throw fail("usage: \(cmd) x1,y1;x2,y2;x3,y3;... (>= 2 points)") }
                let t0 = Date()
                if cmd == "select-lasso" {
                    selection = SelectionEngine.lassoSelect(document: coordinator.document, usePaperSpace: isPaper,
                                                            polygon: pts, mode: .crossing, visibility: visibility)
                } else {
                    selection = SelectionEngine.fenceSelect(document: coordinator.document, usePaperSpace: isPaper,
                                                            fence: pts, visibility: visibility)
                }
                let ms = Date().timeIntervalSince(t0) * 1000
                print(String(format: "edit-script: %@ — %.2fms, %d entities", cmd, ms, selection.count))

            // Phase 4.2: transform verbs, all acting on the CURRENT selection.
            case "copy":
                guard tokens.count == 2, let d = parsePoint(tokens[1]) else {
                    throw fail("usage: copy dx,dy")
                }
                guard !selection.isEmpty else { throw fail("copy: no active selection") }
                let ids = Array(selection)
                let t = Transform2.translation(dx: Double(d.x), dy: Double(d.y))
                var newIds: [EntityID] = []
                let t0 = Date()
                coordinator.parsed.document.transact("Copy") { tx in
                    for id in ids {
                        if let newId = tx.copyTransformed(id, by: t, mirrtext: false) { newIds.append(newId) }
                    }
                }
                applyLastCommit(t0, label: "copy (\(newIds.count) entities)")
                selection = Set(newIds)

            case "rotate":
                guard tokens.count == 3, let c = parsePoint(tokens[1]), let degStr = Double(tokens[2]) else {
                    throw fail("usage: rotate cx,cy deg")
                }
                guard !selection.isEmpty else { throw fail("rotate: no active selection") }
                let ids = Array(selection)
                let t = Transform2.rotation(about: Vec2(c), angleRad: degStr * .pi / 180)
                let t0 = Date()
                coordinator.parsed.document.transact("Rotate") { tx in
                    for id in ids { tx.transform(id, by: t, mirrtext: false) }
                }
                applyLastCommit(t0, label: "rotate (\(ids.count) entities)")

            case "scale":
                guard tokens.count == 3, let c = parsePoint(tokens[1]), let factor = Double(tokens[2]) else {
                    throw fail("usage: scale cx,cy factor")
                }
                guard !selection.isEmpty else { throw fail("scale: no active selection") }
                guard factor > 1e-9 else { throw fail("scale: factor must be > 0") }
                let ids = Array(selection)
                let t = Transform2.scaling(about: Vec2(c), factor: factor)
                let t0 = Date()
                coordinator.parsed.document.transact("Scale") { tx in
                    for id in ids { tx.transform(id, by: t, mirrtext: false) }
                }
                applyLastCommit(t0, label: "scale (\(ids.count) entities)")

            case "mirror":
                guard tokens.count == 3, let a = parsePoint(tokens[1]), let b = parsePoint(tokens[2]) else {
                    throw fail("usage: mirror x1,y1 x2,y2")
                }
                guard !selection.isEmpty else { throw fail("mirror: no active selection") }
                let ids = Array(selection)
                let t = Transform2.mirror(across: Vec2(a), Vec2(b))
                let t0 = Date()
                coordinator.parsed.document.transact("Mirror") { tx in
                    for id in ids { tx.transform(id, by: t, mirrtext: false) }
                }
                applyLastCommit(t0, label: "mirror (\(ids.count) entities)")

            // Phase 4.3: TRIM/EXTEND. `ALL` (3rd token) means "resolve
            // boundaries lazily per target" (the live app's Enter-for-all-
            // visible); otherwise the CURRENT `selection` is the explicit
            // boundary/cutting-edge set (bridged once, up front — matching
            // `TrimExtendExecutor.resolveExplicitBoundaryCurves`'s own
            // "not re-resolved per target" contract).
            case "trim", "extend":
                guard tokens.count == 2 || (tokens.count == 3 && tokens[2].uppercased() == "ALL") else {
                    throw fail("usage: \(cmd) x,y [ALL]")
                }
                guard let p = parsePoint(tokens[1]) else { throw fail("usage: \(cmd) x,y [ALL]") }
                let useAll = tokens.count == 3
                guard let targetId = pickEntity(at: p) else {
                    print("edit-script: \(cmd) — nothing at \(tokens[1])")
                    return
                }
                var boundaryState = TrimExtendToolState.begin(cmd == "trim" ? .trim : .extend)
                boundaryState.withAcquiredBoundaries(useAll ? nil : selection)
                let tol = editScriptTolerance()
                let explicitCurves = useAll ? [] : TrimExtendExecutor.resolveExplicitBoundaryCurves(selection, store: coordinator.parsed.store)

                let t0 = Date()
                guard let resolution = TrimExtendExecutor.resolveClick(targetId: targetId, clickWorld: p, store: coordinator.parsed.store, tol: tol) else {
                    throw fail("\(cmd): target at \(tokens[1]) has no editable geometry")
                }
                let boundaries = TrimExtendExecutor.boundaryCurves(
                    for: targetId, state: boundaryState, explicitBoundaryCurves: explicitCurves,
                    document: coordinator.document, usePaperSpace: isPaper, store: coordinator.parsed.store, visibility: visibility)
                let outcome = cmd == "trim"
                    ? TrimExtendExecutor.trimAtClick(resolution, boundaries: boundaries, extendBoundaries: false, store: coordinator.parsed.store, tol: tol)
                    : TrimExtendExecutor.extendAtClick(resolution, boundaries: boundaries, extendBoundaries: false, store: coordinator.parsed.store, tol: tol)
                guard let outcome else {
                    let ms = Date().timeIntervalSince(t0) * 1000
                    print(String(format: "edit-script: %@ — %.2fms, no-op (edges do not intersect)", cmd, ms))
                    return
                }
                var applied = false
                coordinator.parsed.document.transact(cmd == "trim" ? "Trim" : "Extend") { tx in
                    applied = TrimExtendExecutor.apply(outcome, to: tx)
                }
                applyLastCommit(t0, label: "\(cmd) (applied=\(applied))")

            case "trim-fence":
                guard tokens.count == 2 else { throw fail("usage: trim-fence x1,y1;x2,y2;...") }
                let pts = tokens[1].split(separator: ";").compactMap { parsePoint(String($0)) }
                guard pts.count >= 2 else { throw fail("usage: trim-fence x1,y1;x2,y2;... (>= 2 points)") }
                var boundaryState = TrimExtendToolState.begin(.trim)
                boundaryState.withAcquiredBoundaries(selection.isEmpty ? nil : selection)
                let tol = editScriptTolerance()
                let explicitCurves = selection.isEmpty ? [] : TrimExtendExecutor.resolveExplicitBoundaryCurves(selection, store: coordinator.parsed.store)

                let t0 = Date()
                let outcomes = TrimExtendExecutor.trimFenceBatch(
                    fencePoints: pts, boundaryState: boundaryState, explicitBoundaryCurves: explicitCurves,
                    document: coordinator.document, usePaperSpace: isPaper, store: coordinator.parsed.store, visibility: visibility, tol: tol)
                var appliedCount = 0
                coordinator.parsed.document.transact("Trim (fence)") { tx in
                    for outcome in outcomes where TrimExtendExecutor.apply(outcome, to: tx) { appliedCount += 1 }
                }
                applyLastCommit(t0, label: "trim-fence (\(appliedCount)/\(outcomes.count) applied)")

            // Phase 4.4: FILLET/CHAMFER. Both take two click points (one on
            // each line) plus the command's own parameter(s); TRIMMODE
            // (whether the original lines are trimmed to their feet, vs.
            // left untouched with only the connector added) is read from
            // the session's live sysvar-equivalent -- since EditScriptRunner
            // has no SysVars instance of its own, trimMode is always TRUE
            // here (matching TRIMMODE's own default of 1) with no way to
            // script TRIMMODE=0 -- a deliberate, minor grammar gap (this
            // harness's job is geometry/performance verification, not
            // exhaustively re-testing sysvar plumbing already covered by
            // SysVarsTests.swift and the live-app FilletChamferExecutorTests).
            case "fillet":
                guard tokens.count == 4, let p1 = parsePoint(tokens[1]), let p2 = parsePoint(tokens[2]), let radius = Double(tokens[3]) else {
                    throw fail("usage: fillet x1,y1 x2,y2 radius")
                }
                guard let id1 = pickEntity(at: p1), let id2 = pickEntity(at: p2) else {
                    print("edit-script: fillet — nothing at one or both click points")
                    return
                }
                let tol = editScriptTolerance()
                guard let request = FilletChamferExecutor.resolveFillet(id1: id1, click1: p1, id2: id2, click2: p2, radius: radius, store: coordinator.parsed.store, tol: tol) else {
                    print("edit-script: fillet — could not resolve (non-line entities or degenerate geometry)")
                    return
                }
                let layerId1 = coordinator.parsed.store.header(id1)?.layerId ?? 0
                let t0 = Date()
                coordinator.parsed.document.transact("Fillet") { tx in
                    _ = FilletChamferExecutor.apply(request, trimMode: true, layerId1: layerId1, to: tx)
                }
                applyLastCommit(t0, label: "fillet")

            case "chamfer":
                guard tokens.count == 5, let p1 = parsePoint(tokens[1]), let p2 = parsePoint(tokens[2]),
                      let d1 = Double(tokens[3]), let d2 = Double(tokens[4]) else {
                    throw fail("usage: chamfer x1,y1 x2,y2 d1 d2")
                }
                guard let id1 = pickEntity(at: p1), let id2 = pickEntity(at: p2) else {
                    print("edit-script: chamfer — nothing at one or both click points")
                    return
                }
                let tol = editScriptTolerance()
                guard let request = FilletChamferExecutor.resolveChamfer(id1: id1, click1: p1, id2: id2, click2: p2, d1: d1, d2: d2, angleMode: false, store: coordinator.parsed.store, tol: tol) else {
                    print("edit-script: chamfer — could not resolve (non-line entities or degenerate geometry)")
                    return
                }
                let layerId1 = coordinator.parsed.store.header(id1)?.layerId ?? 0
                let t0 = Date()
                coordinator.parsed.document.transact("Chamfer") { tx in
                    _ = FilletChamferExecutor.apply(request, trimMode: true, layerId1: layerId1, to: tx)
                }
                applyLastCommit(t0, label: "chamfer")

            // Phase 4.5: OFFSET. `offset x,y distance side_x,side_y` offsets
            // the entity at (x,y) by `distance` toward whichever side
            // `side_x,side_y` is on. `offset-through x,y through_x,through_y`
            // derives the distance from the through point instead.
            case "offset":
                guard tokens.count == 4, let p = parsePoint(tokens[1]), let distance = Double(tokens[2]), let side = parsePoint(tokens[3]) else {
                    throw fail("usage: offset x,y distance side_x,side_y")
                }
                guard let id = pickEntity(at: p) else {
                    print("edit-script: offset — nothing at \(tokens[1])")
                    return
                }
                let tol = editScriptTolerance()
                guard let protos = OffsetExecutor.resolve(id: id, distance: distance, sidePoint: side, store: coordinator.parsed.store, tol: tol), !protos.isEmpty else {
                    print("edit-script: offset — could not resolve (unsupported entity type or degenerate result)")
                    return
                }
                let t0 = Date()
                coordinator.parsed.document.transact("Offset") { tx in
                    for proto in protos { _ = tx.add(proto) }
                }
                applyLastCommit(t0, label: "offset (\(protos.count) result(s))")

            case "offset-through":
                guard tokens.count == 3, let p = parsePoint(tokens[1]), let through = parsePoint(tokens[2]) else {
                    throw fail("usage: offset-through x,y through_x,through_y")
                }
                guard let id = pickEntity(at: p) else {
                    print("edit-script: offset-through — nothing at \(tokens[1])")
                    return
                }
                let tol = editScriptTolerance()
                guard let protos = OffsetExecutor.resolveThroughPoint(id: id, throughPoint: through, store: coordinator.parsed.store, tol: tol), !protos.isEmpty else {
                    print("edit-script: offset-through — could not resolve (unsupported entity type or degenerate result)")
                    return
                }
                let t0 = Date()
                coordinator.parsed.document.transact("Offset") { tx in
                    for proto in protos { _ = tx.add(proto) }
                }
                applyLastCommit(t0, label: "offset-through (\(protos.count) result(s))")

            // Phase 6.1/6.2 additions (BLOCK/INSERT/ATTDEF/ATTEDIT/EXPLODE):
            // block NAME bx,by                — blockifies the CURRENT selection (must be non-empty)
            // insert NAME x,y [sx sy rot]     — places an INSERT of an existing block
            // attr INSERT_ID TAG=VALUE        — sets one attribute on an existing INSERT
            // explode x,y                     — explodes the entity at (x,y) (falls back to CURRENT
            //                                    selection, matching `move`'s own "point or selection" convention,
            //                                    when nothing resolves at the point)
            // assert-block-exists NAME [N]    — asserts a block is registered, optionally with entityCount N
            case "block":
                guard tokens.count == 3, let base = parsePoint(tokens[2]) else {
                    throw fail("usage: block NAME bx,by (acts on the CURRENT selection)")
                }
                guard !selection.isEmpty else {
                    throw fail("block: selection is empty — select* first")
                }
                let name = tokens[1]
                guard coordinator.parsed.blocks[name] == nil else {
                    throw fail("block: a block named \"\(name)\" already exists")
                }
                let ids = Array(selection)
                let insertLayerId = coordinator.parsed.store.header(ids[0])?.layerId ?? 0
                let t0 = Date()
                var result: BlockEditor.CreateBlockResult?
                coordinator.parsed.document.transact("Block") { tx in
                    result = BlockEditor.createBlock(name: name, basePoint: base, from: ids,
                                                     insertLayerId: insertLayerId, in: coordinator.parsed, tx: tx)
                }
                guard let result else {
                    throw fail("block: createBlock failed (empty selection or name collision)")
                }
                selection = [result.insertId]
                applyLastCommit(t0, label: "block \(name) (\(ids.count) object(s))")

            case "insert":
                guard tokens.count == 3 || tokens.count == 6, let p = parsePoint(tokens[2]) else {
                    throw fail("usage: insert NAME x,y [sx sy rot]")
                }
                let name = tokens[1]
                var scale = CGPoint(x: 1, y: 1)
                var rotationDeg = 0.0
                if tokens.count == 6 {
                    guard let sx = Double(tokens[3]), let sy = Double(tokens[4]), let rot = Double(tokens[5]) else {
                        throw fail("usage: insert NAME x,y [sx sy rot]")
                    }
                    scale = CGPoint(x: sx, y: sy)
                    rotationDeg = rot
                }
                let t0 = Date()
                var newId: EntityID?
                coordinator.parsed.document.transact("Insert") { tx in
                    newId = BlockEditor.insert(blockName: name, at: p, scale: scale, rotationDeg: rotationDeg,
                                               layerId: 0, owner: owner, in: coordinator.parsed, tx: tx)
                }
                guard let newId else {
                    print("edit-script: insert — could not insert \"\(name)\" (unknown or empty block)")
                    return
                }
                selection = [newId]
                applyLastCommit(t0, label: "insert \(name) (id \(newId.raw))")

            case "attr":
                guard tokens.count == 3, let raw = Int32(tokens[1]) else {
                    throw fail("usage: attr INSERT_ID TAG=VALUE")
                }
                let parts = tokens[2].split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { throw fail("usage: attr INSERT_ID TAG=VALUE") }
                let insertId = EntityID(raw: raw)
                let t0 = Date()
                var ok = false
                coordinator.parsed.document.transact("Edit attribute") { tx in
                    ok = BlockEditor.setAttribute(insertId, tag: parts[0], value: parts[1], in: coordinator.parsed, tx: tx)
                }
                guard ok else {
                    print("edit-script: attr — INSERT \(raw) has no attribute tagged \"\(parts[0])\"")
                    return
                }
                applyLastCommit(t0, label: "attr \(raw) \(parts[0])=\(parts[1])")

            case "explode":
                guard tokens.count == 2, let p = parsePoint(tokens[1]) else {
                    throw fail("usage: explode x,y")
                }
                let ids: [EntityID]
                if let id = pickEntity(at: p) {
                    ids = [id]
                } else if !selection.isEmpty {
                    ids = Array(selection)
                } else {
                    print("edit-script: explode — nothing at \(tokens[1]) and no active selection")
                    return
                }
                let t0 = Date()
                var result: EntityExploder.Result!
                coordinator.parsed.document.transact("Explode") { tx in
                    result = EntityExploder.explode(ids: ids, store: coordinator.parsed.store, parsed: coordinator.parsed, tx: tx)
                }
                selection = Set(result.newIDs)
                applyLastCommit(t0, label: "explode (\(result.explodedCount) object(s) -> \(result.newIDs.count) entities, \(result.skippedCount) skipped)")

            // JOIN — merges the CURRENT selection's connected/collinear
            // lines/arcs/polylines into as few entities as possible (see
            // `Join.swift`/`JoinExecutor.swift`). Acts on the current
            // selection, same "inherently a multi-object batch" convention
            // as array-rect/array-polar above.
            case "join":
                guard !selection.isEmpty else { throw fail("join: no active selection") }
                let ids = Array(selection)
                guard let request = JoinExecutor.resolveJoin(ids: ids, store: coordinator.parsed.store, tol: editScriptTolerance()) else {
                    print("edit-script: join — nothing in the selection could be joined")
                    return
                }
                let t0 = Date()
                var created: [EntityID] = []
                coordinator.parsed.document.transact("Join") { tx in
                    created = JoinExecutor.apply(request, to: tx)
                }
                selection = Set(created)
                let joinedCount = request.results.reduce(0) { $0 + $1.sourceIds.count }
                applyLastCommit(t0, label: "join (\(joinedCount) object(s) -> \(created.count) entity(ies))")

            // Phase 6.4 additions (ARRAY):
            // array-rect rows cols rowSpacing colSpacing [axisAngleDeg]  — arrays the CURRENT selection
            // array-polar cx,cy count fillAngleDeg [rotateItems(0|1)]    — arrays the CURRENT selection
            // array-edit ANCHOR_ID rect rows cols rowSpacing colSpacing [axisAngleDeg]
            // array-edit ANCHOR_ID polar cx,cy count fillAngleDeg [rotateItems(0|1)]
            // assert-array-exists ANCHOR_ID [memberCount]
            // Both `array-rect`/`array-polar` act on the CURRENT selection
            // (set by a prior `select*` command), matching the transform
            // verbs' (copy/rotate/scale/mirror) "act on current selection"
            // convention — an ARRAY operation is inherently a multi-object
            // batch, same rationale as `block`'s own grammar comment above.
            case "array-rect":
                guard tokens.count == 5 || tokens.count == 6,
                      let rows = Int(tokens[1]), let cols = Int(tokens[2]),
                      let rowSpacing = Double(tokens[3]), let colSpacing = Double(tokens[4]) else {
                    throw fail("usage: array-rect rows cols rowSpacing colSpacing [axisAngleDeg]")
                }
                let axisAngle = tokens.count == 6 ? (Double(tokens[5]) ?? 0) : 0
                guard !selection.isEmpty else { throw fail("array-rect: no active selection") }
                let ids = Array(selection)
                let t0 = Date()
                var def: ArrayDefinition?
                coordinator.parsed.document.transact("Array") { tx in
                    def = ArrayTool.commitRectangular(sourceIDs: ids, rows: rows, cols: cols, rowSpacing: rowSpacing,
                                                      colSpacing: colSpacing, axisAngleDeg: axisAngle,
                                                      store: coordinator.parsed.store, tx: tx)
                }
                guard let def else { throw fail("array-rect: could not create (empty selection)") }
                arrays[ids[0]] = def
                selection = Set(def.memberHandles)
                applyLastCommit(t0, label: "array-rect (\(def.memberHandles.count) member(s))")

            case "array-polar":
                guard tokens.count == 4 || tokens.count == 5,
                      let center = parsePoint(tokens[1]), let count = Int(tokens[2]),
                      let fillAngle = Double(tokens[3]) else {
                    throw fail("usage: array-polar cx,cy count fillAngleDeg [rotateItems(0|1)]")
                }
                let rotateItems = tokens.count == 5 ? (tokens[4] != "0") : true
                guard !selection.isEmpty else { throw fail("array-polar: no active selection") }
                let ids = Array(selection)
                let t0 = Date()
                var def: ArrayDefinition?
                coordinator.parsed.document.transact("Array") { tx in
                    def = ArrayTool.commitPolar(sourceIDs: ids, center: center, count: count, fillAngleDeg: fillAngle,
                                                rotateItems: rotateItems, store: coordinator.parsed.store, tx: tx)
                }
                guard let def else { throw fail("array-polar: could not create (empty selection)") }
                arrays[ids[0]] = def
                selection = Set(def.memberHandles)
                applyLastCommit(t0, label: "array-polar (\(def.memberHandles.count) member(s))")

            case "array-edit":
                guard tokens.count >= 3, let rawAnchor = Int32(tokens[1]) else {
                    throw fail("usage: array-edit ANCHOR_ID rect|polar ...")
                }
                let anchor = EntityID(raw: rawAnchor)
                guard let oldDef = arrays[anchor] else { throw fail("array-edit: no array registered at id \(rawAnchor)") }
                let sourceIDs = oldDef.sourceHandles
                let kindParams: ArrayDefinition.Kind
                switch tokens[2] {
                case "rect":
                    guard tokens.count == 7 || tokens.count == 8,
                          let rows = Int(tokens[3]), let cols = Int(tokens[4]),
                          let rowSpacing = Double(tokens[5]), let colSpacing = Double(tokens[6]) else {
                        throw fail("usage: array-edit ANCHOR_ID rect rows cols rowSpacing colSpacing [axisAngleDeg]")
                    }
                    let axisAngle = tokens.count == 8 ? (Double(tokens[7]) ?? 0) : 0
                    kindParams = .rectangular(rows: rows, cols: cols, rowSpacing: rowSpacing, colSpacing: colSpacing, axisAngle: axisAngle)
                case "polar":
                    guard tokens.count == 6 || tokens.count == 7,
                          let center = parsePoint(tokens[3]), let count = Int(tokens[4]),
                          let fillAngle = Double(tokens[5]) else {
                        throw fail("usage: array-edit ANCHOR_ID polar cx,cy count fillAngleDeg [rotateItems(0|1)]")
                    }
                    let rotateItems = tokens.count == 7 ? (tokens[6] != "0") : true
                    kindParams = .polar(center: ArrayDefinition.CodableVec2(center), count: count, fillAngle: fillAngle, rotateItems: rotateItems)
                default:
                    throw fail("array-edit: kind must be 'rect' or 'polar'")
                }
                let t0 = Date()
                var newDef: ArrayDefinition?
                coordinator.parsed.document.transact("Edit Array") { tx in
                    newDef = ArrayTool.regenerate(oldDef, sourceIDs: sourceIDs, newKindParams: kindParams,
                                                  store: coordinator.parsed.store, tx: tx)
                }
                guard let newDef else { throw fail("array-edit: regenerate failed") }
                arrays[anchor] = newDef
                selection = Set(newDef.memberHandles)
                applyLastCommit(t0, label: "array-edit (\(newDef.memberHandles.count) member(s))")

            case "assert-array-exists":
                guard tokens.count == 2 || tokens.count == 3, let rawAnchor = Int32(tokens[1]) else {
                    throw fail("usage: assert-array-exists ANCHOR_ID [memberCount]")
                }
                guard let def = arrays[EntityID(raw: rawAnchor)] else {
                    throw fail("assert-array-exists \(rawAnchor): no such array")
                }
                if tokens.count == 3 {
                    guard let n = Int(tokens[2]), def.memberHandles.count == n else {
                        throw fail("assert-array-exists \(rawAnchor): memberHandles.count is \(def.memberHandles.count), expected \(tokens[2])")
                    }
                }
                print("edit-script: assert-array-exists \(rawAnchor) — OK (\(def.memberHandles.count) members)")

            case "assert-block-exists":
                guard tokens.count == 2 || tokens.count == 3 else {
                    throw fail("usage: assert-block-exists NAME [entityCount]")
                }
                guard let block = coordinator.parsed.blocks[tokens[1]] else {
                    throw fail("assert-block-exists \(tokens[1]): no such block")
                }
                if tokens.count == 3 {
                    guard let n = Int32(tokens[2]), block.entityCount == n else {
                        throw fail("assert-block-exists \(tokens[1]): entityCount is \(block.entityCount), expected \(tokens[2])")
                    }
                }
                print("edit-script: assert-block-exists \(tokens[1]) — OK (\(block.entityCount) entities)")

            case "assert-entity-exists", "assert-entity-deleted":
                guard tokens.count == 2, let raw = Int32(tokens[1]) else {
                    throw fail("usage: \(cmd) ID")
                }
                let id = EntityID(raw: raw)
                let isDeleted = coordinator.parsed.store.isDeleted(id)
                if cmd == "assert-entity-exists" {
                    guard !isDeleted else { throw fail("assert-entity-exists \(raw): entity is deleted") }
                } else {
                    guard isDeleted else { throw fail("assert-entity-deleted \(raw): entity is NOT deleted") }
                }
                print("edit-script: \(cmd) \(raw) — OK")

            case "assert-selection-count":
                guard tokens.count == 2, let n = Int(tokens[1]) else {
                    throw fail("usage: assert-selection-count N")
                }
                guard selection.count == n else {
                    throw fail("assert-selection-count \(n): actual selection count is \(selection.count)")
                }
                print("edit-script: assert-selection-count \(n) — OK")

            case "assert-geometry-equal":
                guard tokens.count >= 3, let rawA = Int32(tokens[1]), let rawB = Int32(tokens[2]) else {
                    throw fail("usage: assert-geometry-equal ID1 ID2 [TOL]")
                }
                let tol = tokens.count >= 4 ? (Double(tokens[3]) ?? 1e-6) : 1e-6
                let idA = EntityID(raw: rawA), idB = EntityID(raw: rawB)
                guard let imageA = coordinator.parsed.store.snapshot(idA),
                      let imageB = coordinator.parsed.store.snapshot(idB) else {
                    throw fail("assert-geometry-equal: one or both ids do not resolve")
                }
                guard EditScriptRunner.payloadsApproximatelyEqual(imageA.payloadCopy, imageB.payloadCopy, tol: tol) else {
                    throw fail("assert-geometry-equal \(rawA) \(rawB): geometry differs beyond tolerance \(tol)")
                }
                print("edit-script: assert-geometry-equal \(rawA) \(rawB) — OK")

            case "undo":
                coordinator.parsed.document.undo()
                try reconcileAfterUndoRedo()
                print("edit-script: undo")

            case "redo":
                coordinator.parsed.document.redo()
                try reconcileAfterUndoRedo()
                print("edit-script: redo")

            case "compact":
                let t0 = Date()
                coordinator.fullRebuild()
                let ms = Date().timeIntervalSince(t0) * 1000
                print(String(format: "edit-script: compact — %.1fms, %d model groups, %d paper groups",
                             ms, coordinator.document.modelGroups.count, coordinator.document.paperGroups.count))

            case "save":
                guard tokens.count >= 2 else { throw fail("usage: save PATH [VER]") }
                let path = tokens[1]
                let version = tokens.count >= 3 ? tokens[2] : "1"
                let cp = coordinator.parsed.store.checkpoint()
                checkpoints[path] = cp
                let marker = "novacad-edit-script-checkpoint\nversion: \(version)\nentities: \(cp.entityCount)\nrevision: \(coordinator.revision)\n"
                try? marker.write(toFile: path, atomically: true, encoding: .utf8)
                print("edit-script: save \(path) (version \(version), \(cp.entityCount) entities)")

            case "snapshot":
                guard tokens.count == 2 else { throw fail("usage: snapshot PATH") }
                try writeSnapshot(to: tokens[1])
                print("edit-script: snapshot \(tokens[1])")

            case "assert-count":
                guard tokens.count == 3, let n = Int(tokens[2]) else {
                    throw fail("usage: assert-count TYPE N")
                }
                guard let type = DXFEntityType.byName(tokens[1]) else {
                    throw fail("assert-count: unknown entity type '\(tokens[1])'")
                }
                let actual = coordinator.parsed.store.headers.filter {
                    $0.type == type && !$0.flags.contains(.deleted)
                }.count
                guard actual == n else {
                    throw fail("assert-count \(tokens[1]) \(n): actual count is \(actual)")
                }
                print("edit-script: assert-count \(tokens[1]) \(n) — OK")

            case "assert-rss":
                guard tokens.count == 2, let maxMB = Double(tokens[1]) else {
                    throw fail("usage: assert-rss MB")
                }
                let rssMB = Double(currentRSSBytesForScript()) / 1_048_576
                guard rssMB <= maxMB else {
                    throw fail("assert-rss \(tokens[1]): actual RSS is \(String(format: "%.1f", rssMB)) MB")
                }
                print(String(format: "edit-script: assert-rss %.0f — OK (actual %.1f MB)", maxMB, rssMB))

            default:
                throw fail("unknown command '\(cmd)'")
            }
        }

        // MARK: - Undo/redo reconciliation
        //
        // `EditableDocument.undo()`/`redo()` mutate the EntityStore directly
        // (via `applyInverse`/`applyForward`) WITHOUT going through
        // `Transaction.finalize()` — so `RegenCoordinator.apply(_:)`, which
        // expects a `[Transaction.Op]`, has nothing to consume. The
        // correctness-preserving (if not maximally incremental) choice here:
        // after an undo/redo, tombstone+re-emit every entity whose CURRENT
        // header differs in observable ways is complex to detect generically,
        // so instead we do a full `fullRebuild()` — always correct, and
        // still fast enough for a test harness (the perf-critical path the
        // plan actually gates on is COMMIT latency, not undo latency; a real
        // live-app cutover would refine this by having `undo`/`redo` return
        // their own op list, which is a small, additive future change to
        // `EditableDocument` that's out of this phase's file scope for
        // `Transactions.swift` beyond what's already there).
        mutating func reconcileAfterUndoRedo() throws {
            coordinator.fullRebuild()
            // Selection may reference entities that undo just deleted (e.g.
            // undoing an add) — drop any that are no longer live, matching
            // how a real UI would clear stale selection.
            selection = selection.filter { !coordinator.parsed.store.isDeleted($0) }
        }

        mutating func applyLastCommit(_ t0: Date, label: String) {
            guard let ops = coordinator.parsed.document.undoStack.last?.ops else { return }
            let delta = coordinator.apply(ops)
            let ms = Date().timeIntervalSince(t0) * 1000
            print(String(format: "edit-script: %@ — %.2fms (appended %d/%d groups, tombstoned %d, fullRebuild=%@)",
                         label, ms, delta.appendedModelGroups.count, delta.appendedPaperGroups.count,
                         coordinator.tombstonedCount, delta.fullRebuild ? "true" : "false"))
        }

        // MARK: - Picking

        func pickEntity(at p: CGPoint) -> EntityID? {
            let tol: CGFloat = 0.5
            return HitTester.hitTestEntityID(document: coordinator.document, usePaperSpace: isPaper,
                                             at: p, tolerance: tol, visibility: visibility)
        }

        /// World-unit tolerance for TRIM/EXTEND's geometry queries, derived
        /// from the document's own extents — same `Tolerance.forExtents`
        /// convention `ContentView.trimExtendTolerance` uses live.
        func editScriptTolerance() -> Tolerance {
            let bounds = isPaper ? coordinator.document.paperBounds : coordinator.document.modelBounds
            let diag = hypot(bounds.width, bounds.height)
            return Tolerance.forExtents(diagonal: Double(diag))
        }

        // MARK: - Snapshot

        func writeSnapshot(to path: String) throws {
            let doc = coordinator.document
            let target = isPaper ? doc.paperFitBounds : doc.modelFitBounds
            guard target.width > 0, target.height > 0 else {
                throw ScriptError(message: "snapshot: empty drawing bounds")
            }
            var params = RenderParams()
            let size = CGSize(width: 1600, height: 1000)
            params.viewSize = size
            params.backingScale = 2
            params.zoom = min(size.width / target.width, size.height / target.height) * 0.94
            params.darkBackground = true
            params.usePaperSpace = isPaper
            params.visibility = visibility
            params.selection = []
            var t = CGAffineTransform.identity
            t = t.translatedBy(x: size.width / 2, y: size.height / 2)
            t = t.scaledBy(x: params.zoom, y: -params.zoom)
            t = t.translatedBy(x: -target.midX, y: -target.midY)
            params.worldToView = t
            guard let frame = BitmapRenderer.render(document: doc, params: params) else {
                throw ScriptError(message: "snapshot: render failed")
            }
            let url = URL(fileURLWithPath: path)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw ScriptError(message: "snapshot: cannot create \(path)")
            }
            CGImageDestinationAddImage(dest, frame.image, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}

// MARK: - Helpers

private func parsePoint(_ s: String) -> CGPoint? {
    let parts = s.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 2 else { return nil }
    return CGPoint(x: parts[0], y: parts[1])
}

private extension Vec3 {
    init(_ p: CGPoint) { self.init(x: Double(p.x), y: Double(p.y)) }
}

private extension DXFEntityType {
    /// Case-insensitive lookup by the grammar's TYPE token (`assert-count`).
    /// Accepts both the Swift case name (`lwpolyline`) and common DXF
    /// spelling variants a script author would reach for first.
    static func byName(_ name: String) -> DXFEntityType? {
        let lower = name.lowercased()
        let aliases: [String: DXFEntityType] = [
            "line": .line, "point": .point, "circle": .circle, "arc": .arc, "ellipse": .ellipse,
            "lwpolyline": .lwpolyline, "polyline": .lwpolyline, "polyline2d": .polyline2d,
            "polyline3d": .polyline3d, "spline": .spline, "solid": .solid, "trace": .trace,
            "face3d": .face3d, "3dface": .face3d, "hatch": .hatch, "text": .text, "mtext": .mtext,
            "attdef": .attdef, "attrib": .attrib, "insert": .insert, "dimension": .dimension,
            "leader": .leader, "mleader": .mleader, "xline": .xline, "ray": .ray, "wipeout": .wipeout,
            "image": .image, "viewport": .viewport, "acadtable": .acadTable, "unknown": .unknown
        ]
        return aliases[lower]
    }
}

/// Process RSS, duplicated from `SnapshotMode.currentRSSBytes` (that one is
/// `private` to `SnapshotMode`) — same `mach_task_basic_info` call, used by
/// `assert-rss`.
private func currentRSSBytesForScript() -> UInt64 {
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
