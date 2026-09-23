import Foundation
import CADCore

// MARK: - Phase 3: per-entity DXF record emission
//
// Writes ONE entity's full group-code record (common properties + its typed
// geometry) to a `DXFOutputStream`. Called by `DXFStructuralWriter`'s
// ENTITIES/BLOCKS pass-2 walk for every non-deleted header in the store.
// Kept as a standalone enum (not a method on the writer) so its surface
// (entity-shape knowledge) is cleanly separated from section/handle-graph
// orchestration.
enum EntityRecordWriter {

    /// Emits every visible/known entity type in `DXFEntityType`. `.unknown`
    /// entities (residual-only, no typed payload) are handled entirely via
    /// `residualPairs` by the caller instead — see `DXFStructuralWriter`.
    ///
    /// - Parameters:
    ///   - ownerHandle: BLOCK_RECORD handle of the space/block this entity
    ///     belongs to (group 330 on `AcDbEntity`).
    ///   - version: controls handle/subclass-marker emission and the
    ///     version-degrade paths (LWPOLYLINE -> POLYLINE, MTEXT -> TEXT,
    ///     true color -> ACI, etc.)
    ///   - nextHandle: allocates one fresh, never-before-used handle on
    ///     demand — needed because some entities expand into MULTIPLE DXF
    ///     records at write time (POLYLINE's VERTEX/SEQEND children,
    ///     degraded MTEXT's per-line TEXT records, degraded HATCH's
    ///     boundary POLYLINE/VERTEX/SEQEND chains) whose exact count isn't
    ///     known until this function actually runs. Backed by the SAME
    ///     `HandleAllocator` pass 1 used, so every handle handed out here is
    ///     guaranteed unique across the whole file.
    ///   - hasAttribChildren: true when this is an `.insert` whose ATTRIB
    ///     children the caller (`DXFBlocksEntitiesEmitter.writeOneEntityAndChildren`)
    ///     is about to write immediately after this record, via
    ///     `graph.childrenByParent`. `writeInsert` has no independent way to
    ///     know this (that adjacency data lives entirely in the caller's
    ///     `HandleGraph`), so it must be threaded through explicitly — used
    ///     to emit DXF group 66 ("attributes follow") correctly. Ignored by
    ///     every other entity type.
    ///   - viewportID: for `.viewport` only — the sequential, 1-based DXF
    ///     group 69 ("viewport ID") value this VIEWPORT should claim within
    ///     its space/block, computed by the caller (which owns the
    ///     per-space counter — see `DXFBlocksEntitiesEmitter.writeEntitiesSection`/
    ///     `writeBlocksSection`) since `EntityRecordWriter` itself has no
    ///     visibility into sibling VIEWPORTs. Ignored by every other type.
    static func write(id: EntityID, header h: EntityHeader, store: EntityStore,
                      ownerHandle: UInt64, handle: UInt64,
                      layerName: String, linetypeName: String?,
                      version: DXFVersion, out: DXFOutputStream,
                      nextHandle: () -> UInt64,
                      warnings: inout [WriteWarning],
                      hasAttribChildren: Bool = false,
                      viewportID: Int = 0) {
        // `.unknown` AND the .xline/.ray/.wipeout/.mleader/.acadTable group
        // all legitimately carry `payload == -1` — none of them have a
        // typed payload representation in this codebase (see
        // EntityStore.swift's DXFEntityType doc comment and the `.xline`
        // case below) — so both must be allowed past this guard. Before this
        // fix, only `.unknown` was exempted, which meant the entire
        // `.xline`/`.ray`/`.wipeout`/`.mleader`/`.acadTable` case in the
        // switch below was silently DEAD CODE: any such entity (payload -1,
        // not `.unknown`) hit this guard and returned immediately, before
        // ever reaching its own case — so even after that case was fixed to
        // call `writeXData`, it still never ran.
        let hasNoTypedPayload = h.type == .unknown || h.type == .xline || h.type == .ray
            || h.type == .wipeout || h.type == .mleader || h.type == .acadTable
        guard h.payload >= 0 || hasNoTypedPayload else { return }

        // Whether this entity's own residual pairs + XDATA (see
        // `writeExtras`'s doc comment) still need to be appended after the
        // switch below runs. Every SINGLE-record case leaves this true and
        // gets it appended generically at the end of this function. Cases
        // that expand into MULTIPLE records (POLYLINE/VERTEX chains,
        // degraded MTEXT/HATCH/tessellated-curve paths) append it
        // THEMSELVES, inline, right after their first record's own fields
        // (attached to the record that reuses the entity's original
        // `handle`) — those set this to false so it isn't ALSO (wrongly)
        // appended a second time, to a record it doesn't belong to, by the
        // generic path below.
        var needsGenericExtras = true

        switch h.type {
        case .line:
            let p = store.lines[Int(h.payload)]
            common("LINE", "AcDbLine", h, handle, ownerHandle, layerName, linetypeName, version, out)
            out.pair(10, p.a.x); out.pair(20, p.a.y); out.pair(30, p.a.z)
            out.pair(11, p.b.x); out.pair(21, p.b.y); out.pair(31, p.b.z)
            writeExtrusion(h, out)

        case .point:
            let p = store.points[Int(h.payload)]
            common("POINT", "AcDbPoint", h, handle, ownerHandle, layerName, linetypeName, version, out)
            out.pair(10, p.p.x); out.pair(20, p.p.y); out.pair(30, p.p.z)

        case .circle:
            let p = store.circles[Int(h.payload)]
            common("CIRCLE", "AcDbCircle", h, handle, ownerHandle, layerName, linetypeName, version, out)
            out.pair(10, p.center.x); out.pair(20, p.center.y); out.pair(30, p.center.z)
            out.pair(40, p.radius)
            writeExtrusionZ(p.extrusionZ, h, out)

        case .arc:
            let p = store.arcs[Int(h.payload)]
            common("ARC", "AcDbCircle", h, handle, ownerHandle, layerName, linetypeName, version, out)
            out.pair(10, p.center.x); out.pair(20, p.center.y); out.pair(30, p.center.z)
            out.pair(40, p.radius)
            if version.hasHandles { out.pair(100, "AcDbArc") }
            out.pair(50, p.startAngleDeg); out.pair(51, p.endAngleDeg)
            writeExtrusionZ(p.extrusionZ, h, out)

        case .ellipse:
            if version < .r14 {
                writeTessellatedEllipseAsPolyline(id: id, h: h, store: store, ownerHandle: ownerHandle,
                                                  handle: handle, layerName: layerName, linetypeName: linetypeName,
                                                  version: version, out: out, nextHandle: nextHandle, warnings: &warnings)
                needsGenericExtras = false
            } else {
                let p = store.ellipses[Int(h.payload)]
                common("ELLIPSE", "AcDbEllipse", h, handle, ownerHandle, layerName, linetypeName, version, out)
                out.pair(10, p.center.x); out.pair(20, p.center.y); out.pair(30, p.center.z)
                out.pair(11, p.majorAxisEndpoint.x); out.pair(21, p.majorAxisEndpoint.y); out.pair(31, p.majorAxisEndpoint.z)
                out.pair(40, p.ratio)
                out.pair(41, p.startParam); out.pair(42, p.endParam)
            }

        case .lwpolyline:
            writePolyline(id: id, h: h, store: store, ownerHandle: ownerHandle, handle: handle,
                         layerName: layerName, linetypeName: linetypeName, version: version,
                         out: out, nextHandle: nextHandle, warnings: &warnings, preferLW: true)
            needsGenericExtras = version.supportsLWPolyline   // legacy POLYLINE/VERTEX form already wrote extras itself

        case .polyline2d, .polyline3d, .solid, .trace, .face3d, .leader:
            writeLegacyShapeEntity(id: id, h: h, store: store, ownerHandle: ownerHandle, handle: handle,
                                   layerName: layerName, linetypeName: linetypeName, version: version,
                                   out: out, nextHandle: nextHandle)
            needsGenericExtras = (h.type == .solid || h.type == .trace || h.type == .face3d)   // single-record types only

        case .spline:
            if version < .r14 {
                writeTessellatedSplineAsPolyline(id: id, h: h, store: store, ownerHandle: ownerHandle,
                                                 handle: handle, layerName: layerName, linetypeName: linetypeName,
                                                 version: version, out: out, nextHandle: nextHandle, warnings: &warnings)
                needsGenericExtras = false
            } else {
                writeSpline(h: h, store: store, ownerHandle: ownerHandle, handle: handle,
                           layerName: layerName, linetypeName: linetypeName, version: version, out: out)
            }

        case .text:
            writeText(h: h, store: store, ownerHandle: ownerHandle, handle: handle,
                     layerName: layerName, linetypeName: linetypeName, version: version, out: out, entityType: "TEXT")

        case .attdef:
            writeAttribLike(h: h, store: store, ownerHandle: ownerHandle, handle: handle,
                           layerName: layerName, linetypeName: linetypeName, version: version, out: out, isAttdef: true)

        case .attrib:
            writeAttribLike(h: h, store: store, ownerHandle: ownerHandle, handle: handle,
                           layerName: layerName, linetypeName: linetypeName, version: version, out: out, isAttdef: false)

        case .mtext:
            if version < .r14 {
                writeMTextAsText(id: id, h: h, store: store, ownerHandle: ownerHandle, handle: handle,
                                layerName: layerName, linetypeName: linetypeName, version: version,
                                out: out, nextHandle: nextHandle, warnings: &warnings)
                needsGenericExtras = false
            } else {
                writeMText(h: h, store: store, ownerHandle: ownerHandle, handle: handle,
                          layerName: layerName, linetypeName: linetypeName, version: version, out: out)
            }

        case .insert:
            writeInsert(h: h, store: store, ownerHandle: ownerHandle, handle: handle,
                       layerName: layerName, linetypeName: linetypeName, version: version, out: out,
                       hasAttribChildren: hasAttribChildren)

        case .dimension:
            writeDimension(h: h, store: store, ownerHandle: ownerHandle, handle: handle,
                          layerName: layerName, linetypeName: linetypeName, version: version, out: out)

        case .hatch:
            if version < .r14 {
                writeHatchAsPolylines(id: id, h: h, store: store, ownerHandle: ownerHandle, handle: handle,
                                     layerName: layerName, linetypeName: linetypeName, version: version,
                                     out: out, nextHandle: nextHandle, warnings: &warnings)
                needsGenericExtras = false
            } else {
                writeHatch(h: h, store: store, ownerHandle: ownerHandle, handle: handle,
                          layerName: layerName, linetypeName: linetypeName, version: version, out: out)
            }

        case .image:
            writeImage(h: h, store: store, ownerHandle: ownerHandle, handle: handle,
                      layerName: layerName, linetypeName: linetypeName, version: version, out: out, warnings: &warnings)

        case .viewport:
            writeViewport(h: h, store: store, ownerHandle: ownerHandle, handle: handle,
                         layerName: layerName, linetypeName: linetypeName, version: version, out: out,
                         viewportID: viewportID)

        case .xline, .ray, .wipeout, .mleader, .acadTable:
            // Not authored/round-tripped as typed payloads by this codebase
            // today (see EntityStore.swift's DXFEntityType doc comment — the
            // parser discards these into `skippedTypes` rather than storing
            // them, so no EntityStore entity ever actually carries one of
            // these types in practice yet). Handled here only for
            // exhaustiveness against the enum; if one ever appears, treat it
            // like `.unknown` (residual-only echo) rather than crashing.
            needsGenericExtras = false
            // Write the owning record whenever there's EITHER residual pairs
            // OR XDATA to attach to it — an XDATA-only entity (no residual
            // pairs) still needs its "0/<TYPE>" header written before
            // writeXData appends group 1001+, or the XDATA ends up orphaned
            // with no owning record ahead of it (see writeResidualOnly's doc
            // comment for the bug this guards against).
            if store.residualPairs[id.raw] != nil || store.xdata[id.raw] != nil {
                writeResidualOnly(recordType: recordTypeName(for: h.type), h: h, store: store, id: id,
                                  ownerHandle: ownerHandle, handle: handle, layerName: layerName,
                                  linetypeName: linetypeName, version: version, out: out)
                writeXData(id: id, store: store, out: out)
            }

        case .unknown:
            // `writeResidualOnly` always writes the owning "0/<TYPE>" header
            // (even with zero residual pairs) — see that function's doc
            // comment — so XDATA can safely be appended unconditionally
            // right after, with no risk of orphaning it.
            writeResidualOnly(recordType: nil, h: h, store: store, id: id, ownerHandle: ownerHandle,
                             handle: handle, layerName: layerName, linetypeName: linetypeName,
                             version: version, out: out)
            writeXData(id: id, store: store, out: out)
            needsGenericExtras = false
        }

        if needsGenericExtras {
            writeExtras(id: id, store: store, out: out)
        }
    }

    /// Appends an entity's RESIDUAL group codes (unrecognized fields on an
    /// otherwise-typed entity — see `RawPairBlob`'s doc comment) followed by
    /// its XDATA (group 1001+ — see `XDataBlob`), if either is present.
    /// Called once per entity, immediately after all of that entity's own
    /// known fields have been written, so both land inside the correct
    /// record rather than bleeding into whatever comes next. This is the
    /// mechanism that satisfies the non-negotiable "never silently drop
    /// residual/XDATA content" requirement — every entity type in this
    /// switch reaches this call exactly once (single-record types via the
    /// generic path at the end of `write`; multi-record degrade paths call
    /// it themselves, inline, on the record that reuses the entity's own
    /// original handle — see each such function's own call site).
    private static func writeExtras(id: EntityID, store: EntityStore, out: DXFOutputStream) {
        if let residual = store.residualPairs[id.raw] {
            for p in residual.pairs where p.code != 330 { out.pair(Int(p.code), p.value) }
        }
        writeXData(id: id, store: store, out: out)
    }

    /// XDATA is stored per-entity as (at most) one `XDataBlob` in
    /// `EntityStore.xdata` — but `EntityStoreParser.commonProps` documents
    /// that MULTIPLE app-id XDATA groups in the source get flattened into
    /// that single blob (`appId` fields joined with "," , `pairs`
    /// concatenated) rather than kept as separate per-appid groups (see
    /// `EntityStoreParser.emit`'s comment: "xdata.count == 1 ? xdata[0] :
    /// XDataBlob(appId: ... joined ..., pairs: ... flatMap ...)"). This is a
    /// PRE-EXISTING lossy-merge on the READ side (not introduced by this
    /// writer) — re-emitting it means a source file with N separate XDATA
    /// app-id groups on one entity round-trips as ONE group carrying the
    /// concatenation. Documented here as a known, inherited limitation
    /// rather than something this writer could fix without changing
    /// `EntityStore`'s storage shape (out of scope for this session — see
    /// the file scope constraints in the task brief).
    private static func writeXData(id: EntityID, store: EntityStore, out: DXFOutputStream) {
        guard let blob = store.xdata[id.raw] else { return }
        out.pair(1001, blob.appId)
        for (code, value) in blob.pairs {
            switch value {
            case .string(let s): out.pair(Int(code), s)
            case .double(let d): out.pair(Int(code), d)
            case .int(let i): out.pair(Int(code), Int(i))
            case .handle(let h): out.handlePair(Int(code), h)
            }
        }
    }

    private static func recordTypeName(for type: DXFEntityType) -> String {
        switch type {
        case .xline: return "XLINE"
        case .ray: return "RAY"
        case .wipeout: return "WIPEOUT"
        case .mleader: return "MULTILEADER"
        case .acadTable: return "ACAD_TABLE"
        default: return "UNKNOWN"
        }
    }

    // MARK: - Common property emission

    /// Emits `0/<type>` plus the AcDbEntity common block (handle, owner,
    /// layer, color, linetype, lineweight) and the type's own subclass
    /// marker. Every concrete entity writer calls this first.
    private static func common(_ recordType: String, _ subclass: String, _ h: EntityHeader,
                               _ handle: UInt64, _ ownerHandle: UInt64,
                               _ layerName: String, _ linetypeName: String?,
                               _ version: DXFVersion, _ out: DXFOutputStream) {
        out.pair(0, recordType)
        if version.hasHandles {
            out.handlePair(5, handle)
            if ownerHandle != 0 { out.handlePair(330, ownerHandle) }
            out.pair(100, "AcDbEntity")
        }
        if h.flags.contains(.paperSpace) { out.pair(67, 1) }
        out.pair(8, layerName)
        writeColor(h, version, out)
        if let lt = linetypeName, lt.uppercased() != "BYLAYER" {
            out.pair(6, lt)
        }
        if h.ltScale != 1.0 { out.pair(48, Double(h.ltScale)) }
        if h.flags.contains(.invisible) { out.pair(60, 1) }
        writeLineweight(h, version, out)
        if version.hasHandles { out.pair(100, subclass) }
    }

    /// ACI (group 62) always; true color (group 420) only on versions that
    /// support it (AC1018/2004+ per the plan's degrade table) — on earlier
    /// versions, a true-color entity degrades to its nearest ACI so color
    /// fidelity is approximated rather than silently lost.
    private static func writeColor(_ h: EntityHeader, _ version: DXFVersion, _ out: DXFOutputStream) {
        let hasTrueColor = (h.trueColor >> 24) != 0xFF
        if hasTrueColor && version.supportsTrueColor {
            // ACI still gets a sane fallback value alongside the true color
            // (AutoCAD itself always writes both) — 256 (BYLAYER) unless the
            // entity's `aci` explicitly says otherwise.
            if h.aci != 256 { out.pair(62, Int(h.aci)) }
            out.pair(420, Int(h.trueColor & 0x00FF_FFFF))
        } else if hasTrueColor {
            // Degrade: nearest ACI approximation (documented version-degrade
            // path — R12/R14 have no true-color group).
            let nearest = ACIPalette.nearestACI(forRGB: h.trueColor & 0x00FF_FFFF)
            out.pair(62, nearest)
        } else if h.aci != 256 {
            out.pair(62, Int(h.aci))
        }
    }

    /// Lineweight (group 370) only on versions that support it (AC1015+ per
    /// the degrade table's "R14 — still no lineweight" note — this codebase
    /// treats 2000/AC1015 as the first lineweight-capable version, matching
    /// the plan's version-degrade table which lists lineweight as ok
    /// starting at "2000").
    private static func writeLineweight(_ h: EntityHeader, _ version: DXFVersion, _ out: DXFOutputStream) {
        guard version.supportsLineweight, h.lineweight != -1 else { return }
        out.pair(370, Int(h.lineweight))
    }

    /// Extrusion direction (210/220/230) for entities whose payload retains
    /// only the `mirrorOCS` boolean proxy (LINE has no typed extrusionZ
    /// field at all in `LinePayload` — matches `DXFParser`'s own rule that
    /// LINE coordinates are WCS and 210/230 only matters for
    /// thickness/mirroring bookkeeping, never geometric mirroring for this
    /// entity type). See the file-level doc comment on the known limitation:
    /// only (0,0,1)/(0,0,-1) is ever representable, never an arbitrary tilted
    /// OCS, because no payload in this codebase stores a full extrusion
    /// vector.
    private static func writeExtrusion(_ h: EntityHeader, _ out: DXFOutputStream) {
        guard h.flags.contains(.mirrorOCS) else { return }
        out.pair(210, 0.0); out.pair(220, 0.0); out.pair(230, -1.0)
    }

    /// Same as `writeExtrusion` but for CIRCLE/ARC, which retain a scalar
    /// `extrusionZ` on their own payload (±1 magnitude only, per
    /// `CirclePayload`/`ArcPayload`'s doc comments) rather than relying on
    /// the header-level `mirrorOCS` flag.
    private static func writeExtrusionZ(_ z: Double, _ h: EntityHeader, _ out: DXFOutputStream) {
        if z != 1.0 {
            out.pair(210, 0.0); out.pair(220, 0.0); out.pair(230, z)
        } else if h.flags.contains(.mirrorOCS) {
            out.pair(210, 0.0); out.pair(220, 0.0); out.pair(230, -1.0)
        }
    }

    // MARK: - POLYLINE family (LWPOLYLINE preferred; POLYLINE for legacy/degrade)

    private static func writePolyline(id: EntityID, h: EntityHeader, store: EntityStore,
                                      ownerHandle: UInt64, handle: UInt64,
                                      layerName: String, linetypeName: String?, version: DXFVersion,
                                      out: DXFOutputStream, nextHandle: () -> UInt64,
                                      warnings: inout [WriteWarning], preferLW: Bool) {
        let p = store.polylines[Int(h.payload)]
        let verts = Array(store.vertexArena[Int(p.vertsStart)..<Int(p.vertsStart + p.vertsCount)])
        let bulges = Array(store.scalarArena[Int(p.bulgesStart)..<Int(p.bulgesStart) + Int(p.vertsCount)])

        if version.supportsLWPolyline && preferLW && !p.is3D {
            common("LWPOLYLINE", "AcDbPolyline", h, handle, ownerHandle, layerName, linetypeName, version, out)
            out.pair(90, verts.count)
            var flags = 0
            if p.closed { flags |= 1 }
            out.pair(70, flags)
            if p.constantWidth != 0 { out.pair(43, p.constantWidth) }
            if p.elevation != 0 { out.pair(38, p.elevation) }
            for (i, v) in verts.enumerated() {
                out.pair(10, v.x); out.pair(20, v.y)
                if bulges[i] != 0 { out.pair(42, bulges[i]) }
            }
        } else {
            // Legacy POLYLINE/VERTEX/SEQEND form — used for R12 degrade
            // (LWPOLYLINE -> POLYLINE/VERTEX per the plan's degrade table)
            // and for genuine 3D polylines (which LWPOLYLINE can't represent
            // at all — it's inherently a 2D/planar entity per spec).
            if preferLW, version.supportsLWPolyline == false {
                warnings.append(WriteWarning(kind: .degraded,
                    message: "LWPOLYLINE degraded to POLYLINE/VERTEX for \(version.rawValue)"))
            }
            common("POLYLINE", "AcDbPolyline", h, handle, ownerHandle, layerName, linetypeName, version, out)
            out.pair(66, 1)
            var flags = 0
            if p.closed { flags |= 1 }
            if p.is3D { flags |= 8 }
            out.pair(70, flags)
            out.pair(10, 0.0); out.pair(20, 0.0); out.pair(30, p.elevation)
            if version.hasHandles { out.pair(100, "AcDb3dPolyline") }
            writeExtras(id: id, store: store, out: out)
            for (i, v) in verts.enumerated() {
                writeVertexRecord(x: v.x, y: v.y, z: p.is3D ? v.z : p.elevation, bulge: bulges[i],
                                  is3D: p.is3D, ownerHandle: handle, layerName: layerName,
                                  version: version, out: out, nextHandle: nextHandle)
            }
            writeSeqend(ownerHandle: handle, layerName: layerName, version: version, out: out, nextHandle: nextHandle)
        }
    }

    /// One VERTEX child record (POLYLINE's, or a degrade path's synthesized
    /// legacy polyline). `ownerHandle` here is the OWNING POLYLINE's handle
    /// (330 = parent entity, matching this codebase's own
    /// `OwnerRef.parentEntity` convention for ATTRIB/VERTEX children) — not
    /// to be confused with the block/space owner handle used elsewhere in
    /// this file.
    private static func writeVertexRecord(x: Double, y: Double, z: Double, bulge: Double, is3D: Bool,
                                          ownerHandle: UInt64, layerName: String, version: DXFVersion,
                                          out: DXFOutputStream, nextHandle: () -> UInt64) {
        out.pair(0, "VERTEX")
        if version.hasHandles {
            out.handlePair(5, nextHandle())
            out.handlePair(330, ownerHandle)
            out.pair(100, "AcDbEntity")
        }
        out.pair(8, layerName)
        if version.hasHandles { out.pair(100, "AcDbVertex"); out.pair(100, is3D ? "AcDb3dPolylineVertex" : "AcDb2dVertex") }
        out.pair(10, x); out.pair(20, y); out.pair(30, z)
        if bulge != 0 { out.pair(42, bulge) }
        if is3D { out.pair(70, 32) }
    }

    private static func writeSeqend(ownerHandle: UInt64, layerName: String, version: DXFVersion,
                                    out: DXFOutputStream, nextHandle: () -> UInt64) {
        out.pair(0, "SEQEND")
        if version.hasHandles {
            out.handlePair(5, nextHandle())
            out.handlePair(330, ownerHandle)
            out.pair(100, "AcDbEntity")
        }
        out.pair(8, layerName)
    }

    /// SOLID/TRACE/3DFACE/legacy POLYLINE2D/3D/LEADER all share
    /// `PolylinePayload`'s storage shape in this codebase (see
    /// `EntityStore.copyPayload`'s comment) — reconstructs the correct DXF
    /// record type from the small fixed vertex count for SOLID/TRACE/3DFACE,
    /// or a genuine POLYLINE/VERTEX chain for POLYLINE2D/3D, or a lightweight
    /// open polyline for LEADER (this codebase never authors a "real" typed
    /// LEADER record with annotation/arrowhead data — see EntityStoreParser's
    /// simplified vertex-chain capture — so degrading it to a lightweight
    /// polyline-shaped echo is the most faithful GEOMETRY round trip
    /// available from what's actually stored).
    private static func writeLegacyShapeEntity(id: EntityID, h: EntityHeader, store: EntityStore,
                                               ownerHandle: UInt64, handle: UInt64,
                                               layerName: String, linetypeName: String?, version: DXFVersion,
                                               out: DXFOutputStream, nextHandle: () -> UInt64) {
        let p = store.polylines[Int(h.payload)]
        let verts = Array(store.vertexArena[Int(p.vertsStart)..<Int(p.vertsStart + p.vertsCount)])

        switch h.type {
        case .solid, .trace:
            common(h.type == .solid ? "SOLID" : "TRACE", "AcDbTrace", h, handle, ownerHandle, layerName, linetypeName, version, out)
            var pts = verts
            if pts.count == 3 { pts.append(pts[2]) }   // SOLID/TRACE always emit 4 corners (3rd repeated if triangular)
            let codes: [(Int32, Int32, Int32)] = [(10, 20, 30), (11, 21, 31), (12, 22, 32), (13, 23, 33)]
            for (i, v) in pts.prefix(4).enumerated() {
                out.pair(Int(codes[i].0), v.x); out.pair(Int(codes[i].1), v.y); out.pair(Int(codes[i].2), v.z)
            }

        case .face3d:
            // `EntityStoreParser`'s 3DFACE handling has TWO distinct shapes
            // sharing this one `.face3d` type: a normal whole-face record
            // (3-4 vertices) and — when the SOURCE 3DFACE had per-edge
            // invisibility flags (group 70) — the VISIBLE EDGES split out
            // as independent 2-vertex fragments (EntityStoreParser.swift's
            // `invisible != 0` branch). A real 3DFACE record needs >= 3
            // vertices (`guard pts.count >= 3` on reparse) — writing a
            // 2-vertex fragment as a "3DFACE" with only groups 10/11 present
            // produced an invalid record that silently failed that guard
            // and vanished on reparse (19,855 of ~19,971 face3d entities
            // lost round-tripping the real 731MB production file, almost
            // entirely from ONE building's dense edge-fragment mesh — found
            // via `--roundtrip`'s entity-count-delta check). A 2-vertex
            // fragment's correct DXF shape is just a LINE.
            if verts.count < 3 {
                common("LINE", "AcDbLine", h, handle, ownerHandle, layerName, linetypeName, version, out)
                let a = verts.first ?? Vec3(x: 0, y: 0, z: 0)
                let b = verts.count > 1 ? verts[1] : a
                out.pair(10, a.x); out.pair(20, a.y); out.pair(30, a.z)
                out.pair(11, b.x); out.pair(21, b.y); out.pair(31, b.z)
            } else {
                common("3DFACE", "AcDbFace", h, handle, ownerHandle, layerName, linetypeName, version, out)
                var pts = verts
                if pts.count == 3 { pts.append(pts[2]) }
                let codes: [(Int32, Int32, Int32)] = [(10, 20, 30), (11, 21, 31), (12, 22, 32), (13, 23, 33)]
                for (i, v) in pts.prefix(4).enumerated() {
                    out.pair(Int(codes[i].0), v.x); out.pair(Int(codes[i].1), v.y); out.pair(Int(codes[i].2), v.z)
                }
            }

        case .leader:
            // Lightweight round trip: an open POLYLINE/VERTEX chain on this
            // entity's own layer (no arrowhead/annotation semantics are
            // retained anywhere upstream of this — see EntityStoreParser's
            // LEADER capture, which stores only its vertex chain).
            common("POLYLINE", "AcDbPolyline", h, handle, ownerHandle, layerName, linetypeName, version, out)
            out.pair(66, 1); out.pair(70, 0)
            out.pair(10, 0.0); out.pair(20, 0.0); out.pair(30, 0.0)
            writeExtras(id: id, store: store, out: out)
            for v in verts {
                writeVertexRecord(x: v.x, y: v.y, z: v.z, bulge: 0, is3D: true, ownerHandle: handle,
                                  layerName: layerName, version: version, out: out, nextHandle: nextHandle)
            }
            writeSeqend(ownerHandle: handle, layerName: layerName, version: version, out: out, nextHandle: nextHandle)

        case .polyline2d, .polyline3d:
            let is3D = h.type == .polyline3d
            common("POLYLINE", "AcDbPolyline", h, handle, ownerHandle, layerName, linetypeName, version, out)
            out.pair(66, 1)
            var flags = 0
            if p.closed { flags |= 1 }
            if is3D { flags |= 8 }
            out.pair(70, flags)
            out.pair(10, 0.0); out.pair(20, 0.0); out.pair(30, p.elevation)
            if version.hasHandles { out.pair(100, is3D ? "AcDb3dPolyline" : "AcDb2dPolyline") }
            writeExtras(id: id, store: store, out: out)
            let bulges = Array(store.scalarArena[Int(p.bulgesStart)..<Int(p.bulgesStart) + Int(p.vertsCount)])
            for (i, v) in verts.enumerated() {
                writeVertexRecord(x: v.x, y: v.y, z: is3D ? v.z : p.elevation, bulge: bulges[i], is3D: is3D,
                                  ownerHandle: handle, layerName: layerName, version: version, out: out, nextHandle: nextHandle)
            }
            writeSeqend(ownerHandle: handle, layerName: layerName, version: version, out: out, nextHandle: nextHandle)

        default:
            break
        }
    }

    // MARK: - SPLINE

    private static func writeSpline(h: EntityHeader, store: EntityStore, ownerHandle: UInt64, handle: UInt64,
                                    layerName: String, linetypeName: String?, version: DXFVersion, out: DXFOutputStream) {
        let p = store.splines[Int(h.payload)]
        let control = Array(store.vertexArena[Int(p.controlStart)..<Int(p.controlStart + p.controlCount)])
        let knots = Array(store.scalarArena[Int(p.knotStart)..<Int(p.knotStart + p.knotCount)])
        let weights = Array(store.scalarArena[Int(p.weightStart)..<Int(p.weightStart + p.weightCount)])
        let rational = !weights.isEmpty

        common("SPLINE", "AcDbSpline", h, handle, ownerHandle, layerName, linetypeName, version, out)
        var flags = 0
        if p.closed { flags |= 1 }
        if rational { flags |= 4 }
        out.pair(70, flags)
        out.pair(71, Int(p.degree))
        out.pair(72, knots.count)
        out.pair(73, control.count)
        out.pair(74, 0)
        for k in knots { out.pair(40, k) }
        if rational {
            for w in weights { out.pair(41, w) }
        }
        for v in control {
            out.pair(10, v.x); out.pair(20, v.y); out.pair(30, v.z)
        }
    }

    // MARK: - TEXT / ATTRIB / ATTDEF

    private static func writeText(h: EntityHeader, store: EntityStore, ownerHandle: UInt64, handle: UInt64,
                                  layerName: String, linetypeName: String?, version: DXFVersion,
                                  out: DXFOutputStream, entityType: String) {
        let p = store.texts[Int(h.payload)]
        common(entityType, "AcDbText", h, handle, ownerHandle, layerName, linetypeName, version, out)
        out.pair(1, escapeUnicodeIfNeeded(sanitizeSingleLine(store.strings.string(for: p.stringId)), version))
        out.pair(10, p.position.x); out.pair(20, p.position.y); out.pair(30, p.position.z)
        out.pair(40, p.height)
        if p.rotationDeg != 0 { out.pair(50, p.rotationDeg) }
        if p.widthFactor != 1 { out.pair(41, p.widthFactor) }
        if p.obliqueDeg != 0 { out.pair(51, p.obliqueDeg) }
        if p.styleNameId >= 0 { out.pair(7, store.strings.string(for: p.styleNameId)) }
        let hCode = [0: 0, 1: 1, 2: 2][Int(p.hAlign)] ?? 0
        if hCode != 0 || p.vAlign != 0 { out.pair(72, hCode) }
        if p.vAlign != 0 || hCode != 0 {
            out.pair(11, p.alignPosition.x); out.pair(21, p.alignPosition.y); out.pair(31, p.alignPosition.z)
        }
        if version.hasHandles, (hCode != 0 || p.vAlign != 0) { out.pair(100, "AcDbText") }
        if p.vAlign != 0 { out.pair(73, Int(p.vAlign)) }
    }

    private static func writeAttribLike(h: EntityHeader, store: EntityStore, ownerHandle: UInt64, handle: UInt64,
                                        layerName: String, linetypeName: String?, version: DXFVersion,
                                        out: DXFOutputStream, isAttdef: Bool) {
        let p = store.texts[Int(h.payload)]
        let type = isAttdef ? "ATTDEF" : "ATTRIB"
        common(type, "AcDbText", h, handle, ownerHandle, layerName, linetypeName, version, out)
        let text = sanitizeSingleLine(store.strings.string(for: p.stringId))
        out.pair(1, escapeUnicodeIfNeeded(text, version))
        out.pair(10, p.position.x); out.pair(20, p.position.y); out.pair(30, p.position.z)
        out.pair(40, p.height)
        if p.rotationDeg != 0 { out.pair(50, p.rotationDeg) }
        if p.widthFactor != 1 { out.pair(41, p.widthFactor) }
        if p.styleNameId >= 0 { out.pair(7, store.strings.string(for: p.styleNameId)) }
        // Horizontal (72) / vertical (vAlign, group 74 for ATTRIB/ATTDEF —
        // NOT group 73, which is TEXT's own vAlign code) justification —
        // mirrors `writeText`'s handling of the identical `TextPayload`
        // fields exactly (this used to drop group 72 entirely and could
        // emit a bare group 74 with no accompanying 11/21/31 alignment
        // point, which the DXF spec requires whenever either justification
        // is non-default: a reader has no defined fallback position without
        // it). Same hAlign-code mapping and "either non-default triggers
        // both the code AND the alignment point" logic as writeText.
        let hCode = [0: 0, 1: 1, 2: 2][Int(p.hAlign)] ?? 0
        if hCode != 0 || p.vAlign != 0 { out.pair(72, hCode) }
        if p.vAlign != 0 || hCode != 0 {
            out.pair(11, p.alignPosition.x); out.pair(21, p.alignPosition.y); out.pair(31, p.alignPosition.z)
        }
        if version.hasHandles { out.pair(100, isAttdef ? "AcDbAttributeDefinition" : "AcDbAttribute") }
        // TAG (group 2): use the entity's own retained tag when present
        // (populated by the parser from a real group-2 tag, or by
        // BlockEditor for interactively-created attributes) so it round-
        // trips faithfully. Only when NO distinct tag was retained
        // (`tagStringId == -1` — e.g. a legacy TEXT-shaped entity, or an
        // ATTRIB from a source file that genuinely omitted group 2) fall
        // back to deriving a sensible identifier from the value text, so
        // this required field is never emitted empty/missing.
        if p.tagStringId >= 0 {
            out.pair(2, sanitizeTag(store.strings.string(for: p.tagStringId)))
        } else {
            out.pair(2, sanitizeTag(text))
        }
        // PROMPT (group 3, ATTDEF only) — retained on the payload if present.
        if isAttdef { out.pair(3, p.promptStringId >= 0 ? store.strings.string(for: p.promptStringId) : "") }
        // Flags (group 70): preserve the invisible bit so an invisible
        // attribute stays invisible across a save→reload (it's marked
        // EntityFlags.invisible in the store — see EntityStoreParser's
        // ATTRIB case). Other flag bits (constant/verify/preset) aren't
        // modeled and stay 0.
        out.pair(70, h.flags.contains(.invisible) ? 1 : 0)
        if p.vAlign != 0 { out.pair(74, Int(p.vAlign)) }
    }

    /// TEXT/ATTRIB/ATTDEF group 1 is fundamentally single-line in DXF — a
    /// literal newline byte would desync the file's code/value line pairing
    /// for everything written after it (see `writeMText`'s doc comment on
    /// the identical MTEXT bug this guards TEXT-family entities against
    /// too, defensively, even though no current code path is known to
    /// actually populate a TextPayload with an embedded "\n").
    private static func sanitizeSingleLine(_ s: String) -> String {
        guard s.contains("\n") || s.contains("\r") else { return s }
        return s.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// ATTRIB/ATTDEF tag (group 2) may not contain spaces or most
    /// punctuation per DXF convention — collapse to a safe identifier-ish
    /// form derived from the value text rather than emitting an invalid tag.
    private static func sanitizeTag(_ s: String) -> String {
        let cleaned = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        let result = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return result.isEmpty ? "TAG" : String(result.prefix(64))
    }

    // MARK: - MTEXT

    private static func writeMText(h: EntityHeader, store: EntityStore, ownerHandle: UInt64, handle: UInt64,
                                   layerName: String, linetypeName: String?, version: DXFVersion, out: DXFOutputStream) {
        let p = store.mtexts[Int(h.payload)]
        common("MTEXT", "AcDbMText", h, handle, ownerHandle, layerName, linetypeName, version, out)
        out.pair(10, p.insertion.x); out.pair(20, p.insertion.y); out.pair(30, p.insertion.z)
        out.pair(40, p.height)
        if p.refWidth != 0 { out.pair(41, p.refWidth) }
        out.pair(71, Int(p.attachPoint))
        out.pair(72, 1)   // left-to-right — this codebase doesn't retain the original drawing-direction flag
        // `MTextPayload.stringId` holds PLAIN text with real "\n" characters
        // for paragraph breaks (see `MTextParser.plainText` — inline
        // formatting codes like the original `\P` are stripped at parse
        // time and never retained anywhere). DXF group 1/3 values are
        // fundamentally single-line — a literal newline byte inside one
        // desyncs every subsequent code/value line pairing for the REST OF
        // THE FILE (this exact bug was caught by RoundTripTests: it silently
        // truncated parsing after the first multi-line MTEXT, dropping every
        // entity that followed). Re-escape "\n" back to the `\P` control
        // sequence AutoCAD itself uses for a paragraph break before writing.
        let escaped = store.strings.string(for: p.stringId).replacingOccurrences(of: "\n", with: "\\P")
        let text = escapeUnicodeIfNeeded(escaped, version)
        // Group 1 caps at 250 chars per DXF convention; overflow goes into
        // repeated group-3 continuation lines, the last chunk in group 1.
        let chunks = chunk(text, maxLen: 250)
        if chunks.isEmpty {
            out.pair(1, "")
        } else {
            for c in chunks.dropLast() { out.pair(3, c) }
            out.pair(1, chunks.last!)
        }
        if p.styleNameId >= 0 { out.pair(7, store.strings.string(for: p.styleNameId)) }
        if p.rotationDeg != 0 { out.pair(50, p.rotationDeg) }
    }

    private static func chunk(_ s: String, maxLen: Int) -> [String] {
        guard !s.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        for ch in s {
            current.append(ch)
            if current.utf8.count >= maxLen { result.append(current); current = "" }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// R12/pre-R14 MTEXT degrade: split on existing newlines into individual
    /// single-line TEXT entities, stacked downward from the MTEXT's
    /// insertion point by its cap height — a lossy but documented degrade
    /// (loses paragraph formatting/word-wrap, which R12 TEXT can't represent
    /// at all) per the plan's version-degrade table ("MTEXT -> per-line TEXT").
    private static func writeMTextAsText(id: EntityID, h: EntityHeader, store: EntityStore, ownerHandle: UInt64, handle: UInt64,
                                         layerName: String, linetypeName: String?, version: DXFVersion,
                                         out: DXFOutputStream, nextHandle: () -> UInt64, warnings: inout [WriteWarning]) {
        let p = store.mtexts[Int(h.payload)]
        let text = store.strings.string(for: p.stringId)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        warnings.append(WriteWarning(kind: .degraded,
            message: "MTEXT degraded to \(lines.count) TEXT entit\(lines.count == 1 ? "y" : "ies") for \(version.rawValue)"))
        let lineSpacing = p.height * 1.66
        for (i, line) in lines.enumerated() {
            out.pair(0, "TEXT")
            if version.hasHandles {
                // First line reuses the MTEXT's own already-allocated
                // `handle`; every subsequent line needs a FRESH one (this is
                // genuinely N independent top-level entities in the
                // degraded output, not one entity with children) —
                // `nextHandle()` draws from the same allocator pass 1 seeded,
                // so uniqueness holds across the whole file.
                out.handlePair(5, i == 0 ? handle : nextHandle())
                if ownerHandle != 0 { out.handlePair(330, ownerHandle) }
                out.pair(100, "AcDbEntity")
            }
            out.pair(8, layerName)
            writeColor(h, version, out)
            if version.hasHandles { out.pair(100, "AcDbText") }
            out.pair(10, p.insertion.x)
            out.pair(20, p.insertion.y - Double(i) * lineSpacing)
            out.pair(30, p.insertion.z)
            out.pair(40, p.height)
            out.pair(1, escapeUnicodeIfNeeded(String(line), version))
            if p.rotationDeg != 0 { out.pair(50, p.rotationDeg) }
            // The ORIGINAL MTEXT's residual/XDATA (there is only ever ONE
            // such blob, keyed by the MTEXT entity's own `EntityID`) belongs
            // on the first degraded TEXT line, which is the one carrying
            // that original entity's own `handle`.
            if i == 0 { writeExtras(id: id, store: store, out: out) }
        }
    }

    // MARK: - INSERT

    private static func writeInsert(h: EntityHeader, store: EntityStore, ownerHandle: UInt64, handle: UInt64,
                                    layerName: String, linetypeName: String?, version: DXFVersion, out: DXFOutputStream,
                                    hasAttribChildren: Bool = false) {
        let p = store.inserts[Int(h.payload)]
        common("INSERT", "AcDbBlockReference", h, handle, ownerHandle, layerName, linetypeName, version, out)
        // Group 66 ("attributes follow") — per DXF spec convention this is
        // omitted/0 when no ATTRIB records follow this INSERT, and MUST be 1
        // when they do (real AutoCAD writes it immediately after the
        // AcDbBlockReference subclass marker, before group 2). Without this,
        // a reader has no reliable way to know ATTRIB records immediately
        // following belong to THIS INSERT rather than being stray/malformed
        // — `hasAttribChildren` is threaded in from the caller
        // (`DXFBlocksEntitiesEmitter.writeOneEntityAndChildren`), which is
        // the only place that actually knows (via `graph.childrenByParent`)
        // whether this INSERT has any ATTRIB children about to be written.
        if hasAttribChildren { out.pair(66, 1) }
        out.pair(2, store.strings.string(for: p.blockNameId))
        out.pair(10, p.position.x); out.pair(20, p.position.y); out.pair(30, p.position.z)
        if p.scale.x != 1 { out.pair(41, p.scale.x) }
        if p.scale.y != 1 { out.pair(42, p.scale.y) }
        if p.scale.z != 1 { out.pair(43, p.scale.z) }
        if p.rotationDeg != 0 { out.pair(50, p.rotationDeg) }
        if p.cols > 1 || p.rows > 1 {
            out.pair(70, Int(p.cols)); out.pair(71, Int(p.rows))
            out.pair(44, p.colSpacing); out.pair(45, p.rowSpacing)
        }
    }

    // MARK: - DIMENSION
    //
    // Retained as an INSERT-like reference to its anonymous dimension block
    // (see EntityStore.swift's DimensionPayload doc comment and
    // Regenerator's InsertLike-shaped handling) — this codebase doesn't
    // author true dimension measurement data (definition points beyond the
    // primary one, arrow styles, text override rendering) so the DIMENSION
    // record written here is a faithful but minimal echo: enough for
    // AutoCAD to at least recognize the entity type and re-associate it with
    // its (also round-tripped, if present) anonymous `*D#` block. Full
    // dimension authoring is out of scope for this session per the task brief.

    private static func writeDimension(h: EntityHeader, store: EntityStore, ownerHandle: UInt64, handle: UInt64,
                                       layerName: String, linetypeName: String?, version: DXFVersion, out: DXFOutputStream) {
        let p = store.dimensions[Int(h.payload)]
        common("DIMENSION", "AcDbDimension", h, handle, ownerHandle, layerName, linetypeName, version, out)
        out.pair(2, store.strings.string(for: p.blockNameId))
        out.pair(10, p.defPoint.x); out.pair(20, p.defPoint.y); out.pair(30, p.defPoint.z)
        out.pair(70, 0)
        if p.textOverrideId >= 0 { out.pair(1, store.strings.string(for: p.textOverrideId)) }
        if p.dimStyleNameId >= 0 { out.pair(3, store.strings.string(for: p.dimStyleNameId)) }
        else { out.pair(3, "STANDARD") }
    }

    // MARK: - HATCH

    private static func writeHatch(h: EntityHeader, store: EntityStore, ownerHandle: UInt64, handle: UInt64,
                                   layerName: String, linetypeName: String?, version: DXFVersion, out: DXFOutputStream) {
        let p = store.hatches[Int(h.payload)]
        common("HATCH", "AcDbHatch", h, handle, ownerHandle, layerName, linetypeName, version, out)
        // This hatch's OWN transparency (entity-level group 440, distinct
        // from the SAME group code on its LAYER table entry) — see
        // `HatchPayload.transparency`'s own doc comment. `common(...)` above
        // doesn't write this (it's scoped to HATCH only, unlike the
        // color/lineweight/linetype fields `common` handles for every entity
        // type), and only where the DXF version actually supports
        // transparency at all (R2004+, same gate `writeColor`'s true-color
        // group 420 already uses).
        if version.supportsTrueColor, p.transparency > 0 {
            let alphaByte = 255 - Int((min(max(p.transparency, 0), 100) / 100 * 255).rounded())
            out.pair(440, 0x0200_0000 | alphaByte)
        }
        out.pair(10, p.origin.x); out.pair(20, p.origin.y); out.pair(30, 0.0)
        out.pair(210, 0.0); out.pair(220, 0.0); out.pair(230, 1.0)
        out.pair(2, p.isSolid ? "SOLID" : (p.patternNameId >= 0 ? store.strings.string(for: p.patternNameId) : "ANSI31"))
        out.pair(70, p.isSolid ? 1 : 0)
        out.pair(71, p.associative ? 1 : 0)
        out.pair(91, Int(p.loopRangeCount))
        for r in Int(p.loopRangeStart)..<Int(p.loopRangeStart + p.loopRangeCount) {
            let range = store.hatchLoopRanges[r]
            let loop = Array(store.vertexArena[Int(range.vertStart)..<Int(range.vertStart + range.vertCount)])
            // Boundary type 2 = polyline (bulge-free — this codebase's
            // stored loops are already tessellated point loops, per
            // HatchPayload's doc comment, so every edge is emitted as a
            // straight polyline segment with bulge 0; the ORIGINAL
            // arc/spline edge typing was lost at parse time, a known,
            // pre-existing limitation this writer inherits, not introduces).
            out.pair(92, 2)
            out.pair(72, 0)   // has-bulge = 0
            out.pair(73, 1)   // is-closed
            out.pair(93, loop.count)
            for v in loop { out.pair(10, v.x); out.pair(20, v.y) }
            out.pair(97, 0)   // 0 source boundary objects
        }
        out.pair(75, 0)   // hatch style: normal
        out.pair(76, 1)   // pattern type: predefined
        if !p.isSolid {
            out.pair(52, p.angle)
            out.pair(41, p.scale)
            out.pair(77, 0)
            out.pair(78, 0)
        }
        out.pair(98, 0)   // 0 seed points
    }

    /// R12 degrade: HATCH -> boundary polylines (per the plan's degrade
    /// table). Loses fill entirely (R12 has no HATCH entity) but preserves
    /// the boundary shape as visible geometry, which is the documented
    /// trade-off.
    private static func writeHatchAsPolylines(id: EntityID, h: EntityHeader, store: EntityStore,
                                              ownerHandle: UInt64, handle: UInt64,
                                              layerName: String, linetypeName: String?, version: DXFVersion,
                                              out: DXFOutputStream, nextHandle: () -> UInt64, warnings: inout [WriteWarning]) {
        let p = store.hatches[Int(h.payload)]
        warnings.append(WriteWarning(kind: .degraded,
            message: "HATCH degraded to \(p.loopRangeCount) boundary polyline(s) for \(version.rawValue)"))
        var first = true
        for r in Int(p.loopRangeStart)..<Int(p.loopRangeStart + p.loopRangeCount) {
            let range = store.hatchLoopRanges[r]
            let loop = Array(store.vertexArena[Int(range.vertStart)..<Int(range.vertStart + range.vertCount)])
            // First loop reuses the HATCH's own pre-allocated `handle`;
            // subsequent loops (a HATCH with multiple boundary loops) are
            // independent top-level entities needing fresh handles.
            let polyHandle = first ? handle : nextHandle()
            first = false
            out.pair(0, "POLYLINE")
            if version.hasHandles {
                out.handlePair(5, polyHandle)
                if ownerHandle != 0 { out.handlePair(330, ownerHandle) }
                out.pair(100, "AcDbEntity")
            }
            out.pair(8, layerName)
            writeColor(h, version, out)
            if version.hasHandles { out.pair(100, "AcDbPolyline") }
            out.pair(66, 1); out.pair(70, 1)
            out.pair(10, 0.0); out.pair(20, 0.0); out.pair(30, 0.0)
            // The ORIGINAL HATCH's residual/XDATA belongs on the loop that
            // reused its own `handle` (the first one written above).
            if polyHandle == handle { writeExtras(id: id, store: store, out: out) }
            for v in loop {
                writeVertexRecord(x: v.x, y: v.y, z: v.z, bulge: 0, is3D: true, ownerHandle: polyHandle,
                                  layerName: layerName, version: version, out: out, nextHandle: nextHandle)
            }
            writeSeqend(ownerHandle: polyHandle, layerName: layerName, version: version, out: out, nextHandle: nextHandle)
        }
    }

    // MARK: - IMAGE

    private static func writeImage(h: EntityHeader, store: EntityStore, ownerHandle: UInt64, handle: UInt64,
                                   layerName: String, linetypeName: String?, version: DXFVersion,
                                   out: DXFOutputStream, warnings: inout [WriteWarning]) {
        guard version >= .r14 else {
            warnings.append(WriteWarning(kind: .dropped, message: "IMAGE entity dropped (unsupported before R14) for \(version.rawValue)"))
            return
        }
        let p = store.images[Int(h.payload)]
        common("IMAGE", "AcDbRasterImage", h, handle, ownerHandle, layerName, linetypeName, version, out)
        out.pair(90, 0)
        out.pair(10, p.origin.x); out.pair(20, p.origin.y); out.pair(30, p.origin.z)
        out.pair(11, p.uVector.x); out.pair(21, p.uVector.y); out.pair(31, p.uVector.z)
        out.pair(12, p.vVector.x); out.pair(22, p.vVector.y); out.pair(32, p.vVector.z)
        out.pair(13, p.sizePxWidth); out.pair(23, p.sizePxHeight)
        if p.imageDefHandle != 0 { out.handlePair(340, p.imageDefHandle) }
        out.pair(70, p.displayFlags); out.pair(280, p.clipping ? 1 : 0)
        out.pair(281, p.brightness); out.pair(282, p.contrast); out.pair(283, p.fade)
        if !p.clipVertices.isEmpty {
            out.pair(71, p.clipVertices.count == 2 ? 1 : 2)
            out.pair(91, p.clipVertices.count)
            for vertex in p.clipVertices { out.pair(14, vertex.x); out.pair(24, vertex.y) }
        }
        out.pair(290, p.clipInverted ? 1 : 0)
    }

    // MARK: - VIEWPORT

    private static func writeViewport(h: EntityHeader, store: EntityStore, ownerHandle: UInt64, handle: UInt64,
                                      layerName: String, linetypeName: String?, version: DXFVersion, out: DXFOutputStream,
                                      viewportID: Int) {
        let p = store.viewports[Int(h.payload)]
        common("VIEWPORT", "AcDbViewport", h, handle, ownerHandle, layerName, linetypeName, version, out)
        out.pair(10, p.centerPaper.x); out.pair(20, p.centerPaper.y); out.pair(30, p.centerPaper.z)
        out.pair(40, p.widthPaper); out.pair(41, p.heightPaper)
        out.pair(68, Int(p.status)); out.pair(69, p.viewportID > 0 ? p.viewportID : max(1, viewportID))
        out.pair(12, p.viewCenter.x); out.pair(22, p.viewCenter.y)
        out.pair(16, p.direction.x); out.pair(26, p.direction.y); out.pair(36, p.direction.z)
        out.pair(17, p.target.x); out.pair(27, p.target.y); out.pair(37, p.target.z)
        out.pair(45, p.viewHeight)
        out.pair(51, p.twistDeg)
        out.pair(90, p.flags)
        for handle in p.frozenLayerHandles { out.handlePair(331, handle) }
        if p.clipHandle != 0 { out.handlePair(340, p.clipHandle) }
    }

    // MARK: - Degraded curve->polyline tessellation (R12/R13 fallback for ELLIPSE/SPLINE)

    private static func writeTessellatedEllipseAsPolyline(id: EntityID, h: EntityHeader, store: EntityStore,
                                                           ownerHandle: UInt64, handle: UInt64,
                                                           layerName: String, linetypeName: String?, version: DXFVersion,
                                                           out: DXFOutputStream, nextHandle: () -> UInt64,
                                                           warnings: inout [WriteWarning]) {
        let p = store.ellipses[Int(h.payload)]
        warnings.append(WriteWarning(kind: .degraded, message: "ELLIPSE tessellated to POLYLINE for \(version.rawValue)"))
        let pts = tessellateEllipse(p)
        common("POLYLINE", "AcDbPolyline", h, handle, ownerHandle, layerName, linetypeName, version, out)
        out.pair(66, 1)
        let closed = abs((p.endParam - p.startParam).truncatingRemainder(dividingBy: 2 * .pi)) < 1e-9
        out.pair(70, closed ? 1 : 0)
        out.pair(10, 0.0); out.pair(20, 0.0); out.pair(30, 0.0)
        writeExtras(id: id, store: store, out: out)
        for v in pts {
            writeVertexRecord(x: v.x, y: v.y, z: v.z, bulge: 0, is3D: true, ownerHandle: handle,
                              layerName: layerName, version: version, out: out, nextHandle: nextHandle)
        }
        writeSeqend(ownerHandle: handle, layerName: layerName, version: version, out: out, nextHandle: nextHandle)
    }

    private static func tessellateEllipse(_ p: EllipsePayload) -> [Vec3] {
        var sweep = p.endParam - p.startParam
        if sweep <= 0 { sweep += 2 * .pi }
        let steps = max(16, min(128, Int(sweep / 0.05)))
        let majorLen = p.majorAxisEndpoint.length
        let rot = atan2(p.majorAxisEndpoint.y, p.majorAxisEndpoint.x)
        var pts: [Vec3] = []
        for k in 0...steps {
            let t = p.startParam + sweep * Double(k) / Double(steps)
            let ex = majorLen * cos(t), ey = majorLen * p.ratio * sin(t)
            let x = p.center.x + ex * cos(rot) - ey * sin(rot)
            let y = p.center.y + ex * sin(rot) + ey * cos(rot)
            pts.append(Vec3(x: x, y: y, z: p.center.z))
        }
        return pts
    }

    private static func writeTessellatedSplineAsPolyline(id: EntityID, h: EntityHeader, store: EntityStore,
                                                          ownerHandle: UInt64, handle: UInt64,
                                                          layerName: String, linetypeName: String?, version: DXFVersion,
                                                          out: DXFOutputStream, nextHandle: () -> UInt64,
                                                          warnings: inout [WriteWarning]) {
        let p = store.splines[Int(h.payload)]
        let control = Array(store.vertexArena[Int(p.controlStart)..<Int(p.controlStart + p.controlCount)])
        warnings.append(WriteWarning(kind: .degraded, message: "SPLINE tessellated to POLYLINE for \(version.rawValue)"))
        // Control-polygon approximation (no NURBS evaluator dependency here
        // — SplineEvaluator.swift exists for RENDER-time tessellation; not
        // linked into this writer to keep the R12 path simple/self-contained
        // for this session, at the cost of a coarser-than-ideal approximation
        // of curved splines. Documented limitation, not a crash risk.
        common("POLYLINE", "AcDbPolyline", h, handle, ownerHandle, layerName, linetypeName, version, out)
        out.pair(66, 1)
        out.pair(70, p.closed ? 1 : 0)
        out.pair(10, 0.0); out.pair(20, 0.0); out.pair(30, 0.0)
        writeExtras(id: id, store: store, out: out)
        for v in control {
            writeVertexRecord(x: v.x, y: v.y, z: v.z, bulge: 0, is3D: true, ownerHandle: handle,
                              layerName: layerName, version: version, out: out, nextHandle: nextHandle)
        }
        writeSeqend(ownerHandle: handle, layerName: layerName, version: version, out: out, nextHandle: nextHandle)
    }

    // MARK: - Residual-only echo (.unknown entity types)

    /// `.unknown` entities carry NO typed payload — everything about them is
    /// in `residualPairs`, captured verbatim at parse time specifically so
    /// this code path can echo it back byte-faithfully (module the handle,
    /// which pass 1 may have needed to reassign if it collided/was absent).
    ///
    /// Always writes the owning "0/<TYPE>" record header (handle, owner,
    /// layer, color) even when `residualPairs` is empty or absent — this is
    /// the ONLY place that ever writes that header for a residual-echo
    /// entity, so a caller that goes on to append XDATA (see `writeXData`)
    /// via this entity's `id` MUST call this first regardless of whether
    /// residual pairs exist, or the XDATA group codes end up with no
    /// preceding "0/<TYPE>" line — a desync bug found by adversarial review:
    /// this function used to `guard let residual = ... else { return }`,
    /// writing NOTHING when residual pairs were empty, while its caller
    /// (the `.unknown` case in `write`) unconditionally called `writeXData`
    /// right after regardless — orphaning any XDATA-only entity's group-1001+
    /// codes with no owning record ahead of them.
    private static func writeResidualOnly(recordType: String?, h: EntityHeader, store: EntityStore, id: EntityID,
                                          ownerHandle: UInt64, handle: UInt64,
                                          layerName: String, linetypeName: String?, version: DXFVersion,
                                          out: DXFOutputStream) {
        // The record-start "0/<TYPE>" line itself isn't part of
        // `residualPairs` (that only captures fields WITHIN a record) — this
        // codebase's `.unknown` entities never actually populate a record
        // type name anywhere retrievable, a known gap (see final report).
        // Falling back to a generic marker keeps the file syntactically
        // valid rather than silently emitting a headerless record.
        out.pair(0, recordType ?? "ACAD_PROXY_ENTITY")
        if version.hasHandles {
            out.handlePair(5, handle)
            if ownerHandle != 0 { out.handlePair(330, ownerHandle) }
        }
        out.pair(8, layerName)
        writeColor(h, version, out)
        if let residual = store.residualPairs[id.raw] {
            for p in residual.pairs {
                out.pair(Int(p.code), p.value)
            }
        }
    }

    // MARK: - Unicode escaping (R12/R14 pre-UTF8 degrade)

    /// R2007+ (AC1021+) writes DXF text as UTF-8 directly; earlier versions
    /// use `\U+XXXX` escapes for any non-ASCII codepoint (per the plan's
    /// degrade table). Applied to every TEXT/MTEXT/ATTRIB string value.
    private static func escapeUnicodeIfNeeded(_ s: String, _ version: DXFVersion) -> String {
        guard !version.supportsUTF8 else { return s }
        guard s.unicodeScalars.contains(where: { $0.value > 127 }) else { return s }
        var out = ""
        for scalar in s.unicodeScalars {
            if scalar.value > 127 {
                out += String(format: "\\U+%04X", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
