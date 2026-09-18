import XCTest
@testable import DWGViewer
import CADCore

/// Regression coverage for the reported bug: "PART_DESC shows the same value
/// on many different objects."
///
/// Root cause was NOT parsing — attribute VALUES and their INSERT links parse
/// correctly. It was a SELECTION-IDENTITY collapse in `Regenerator`'s walk:
/// only TOP-LEVEL inserts (`ctx.insertId == -1`) got their own
/// `InsertInstance`, so every attribute-bearing INSERT nested inside a
/// container block inherited the CONTAINER's `insertId`. Because every
/// attribute-reading call site (`BlockEditor.attributes(of:)`, the Properties
/// panel, the attribute editor, Data Extraction) is keyed on the resolved
/// source `EntityID`, N distinct nested workstations all resolved to ONE id
/// and therefore all displayed one identical set of values.
///
/// On a large production drawing this affected every attributed INSERT in the
/// drawing — thousands of them across several reusable workstation symbol
/// blocks, nested inside container blocks. This test reproduces that exact
/// shape in miniature: a container block holding several instances of one
/// symbol block, each instance carrying its own distinct attribute value.
final class NestedAttributedInsertIdentityTests: XCTestCase {

    private func makeParsed() -> EditableParsedDocument {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        parsed.linetypes.append(DXFLinetype(name: "CONTINUOUS", dashes: []))
        parsed.linetypeIdByName["CONTINUOUS"] = 0
        return parsed
    }

    /// Builds: symbol block "STN" (one line of geometry) -> container block
    /// "CONTAINER" holding `count` INSERTs of "STN", each with its own
    /// PART_DESC ATTRIB -> one top-level INSERT of "CONTAINER" in model
    /// space. Mirrors a production drawing's reusable station block nested
    /// inside a container block.
    private func buildNestedFixture(count: Int) -> (EditableParsedDocument, [String]) {
        let parsed = makeParsed()
        let doc = parsed.document
        let store = parsed.store

        // ---- symbol block "STN" ----
        let stnIndex = BlockEditor.nextBlockIndex(in: parsed)
        var stnGeomId: EntityID!
        doc.transact("STN content") { tx in
            stnGeomId = tx.add(EntityPrototype(
                type: .line, layerId: 0, owner: .block(stnIndex),
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 5, y: 0)))))
        }
        let stn = EditableBlockDef()
        stn.name = "STN"
        stn.blockIndex = stnIndex
        stn.entityStart = stnGeomId.raw
        stn.entityCount = 1
        parsed.blocks["STN"] = stn

        // ---- container block holding `count` attributed STN instances ----
        let contIndex = BlockEditor.nextBlockIndex(in: parsed)
        var expectedValues: [String] = []
        var firstContentId: EntityID!
        var contentCount: Int32 = 0
        doc.transact("CONTAINER content") { tx in
            let nameId = store.strings.intern("STN")
            for i in 0..<count {
                let insId = tx.add(EntityPrototype(
                    type: .insert, layerId: 0, owner: .block(contIndex),
                    payload: .insert(InsertPayload(blockNameId: nameId,
                                                   position: Vec3(x: Double(i) * 20, y: 0)))))
                if firstContentId == nil { firstContentId = insId }
                contentCount += 1

                let value = "PART-\(i)"
                expectedValues.append(value)
                var tp = TextPayload(position: Vec3(x: Double(i) * 20, y: 1), height: 1,
                                     stringId: store.strings.intern(value))
                tp.tagStringId = store.strings.intern("PART_DESC")
                _ = tx.add(EntityPrototype(
                    type: .attrib, layerId: 0, owner: .parentEntity(insId),
                    payload: .text(tp)))
                contentCount += 1
            }
        }
        let cont = EditableBlockDef()
        cont.name = "CONTAINER"
        cont.blockIndex = contIndex
        cont.entityStart = firstContentId.raw
        cont.entityCount = contentCount
        parsed.blocks["CONTAINER"] = cont

        // ---- one top-level INSERT of the container ----
        doc.transact("place container") { tx in
            _ = tx.add(EntityPrototype(
                type: .insert, layerId: 0, owner: .model,
                payload: .insert(InsertPayload(blockNameId: store.strings.intern("CONTAINER"),
                                               position: Vec3(x: 0, y: 0)))))
        }
        return (parsed, expectedValues)
    }

    func testEachNestedAttributedInsertGetsItsOwnSelectableIdentity() throws {
        let count = 6
        let (parsed, expectedValues) = buildNestedFixture(count: count)
        let built = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }

        // Every nested attributed INSERT must appear as its OWN
        // `InsertInstance` with its OWN distinct source entityId — that is
        // precisely what makes the Properties panel / Data Extraction show
        // per-object values instead of one shared value.
        let stnInstances = built.inserts.filter { $0.name == "STN" }
        XCTAssertEqual(stnInstances.count, count,
                       "each nested attributed INSERT must get its own InsertInstance")

        let distinctSourceIds = Set(stnInstances.map(\.entityId))
        XCTAssertEqual(distinctSourceIds.count, count,
                       "all \(count) nested workstations must resolve to DISTINCT source entity ids (the bug made them share one)")

        // And each of those distinct ids must read back its OWN value.
        var readValues: [String] = []
        for ins in stnInstances {
            let attrs = BlockEditor.attributes(of: EntityID(raw: ins.entityId), in: parsed.store)
            let pkg = attrs.first { $0.tag == "PART_DESC" }
            readValues.append(pkg?.value ?? "<none>")
        }
        XCTAssertEqual(Set(readValues), Set(expectedValues),
                       "each workstation must report its own distinct PART_DESC value")
        XCTAssertEqual(Set(readValues).count, count,
                       "no value may be duplicated across workstations")
    }

    /// Guards the OTHER half of the behavior contract: nested inserts WITHOUT
    /// attributes deliberately keep inheriting their ancestor's identity, so
    /// clicking a plain nested block still selects the whole top-level block
    /// (ordinary non-attributed nesting must not gain new granularity).
    func testNestedInsertsWithoutAttributesStillInheritAncestorIdentity() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        let store = parsed.store

        let leafIndex = BlockEditor.nextBlockIndex(in: parsed)
        var leafGeom: EntityID!
        doc.transact("leaf") { tx in
            leafGeom = tx.add(EntityPrototype(
                type: .line, layerId: 0, owner: .block(leafIndex),
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 3, y: 0)))))
        }
        let leaf = EditableBlockDef()
        leaf.name = "LEAF"
        leaf.blockIndex = leafIndex
        leaf.entityStart = leafGeom.raw
        leaf.entityCount = 1
        parsed.blocks["LEAF"] = leaf

        let contIndex = BlockEditor.nextBlockIndex(in: parsed)
        var firstId: EntityID!
        doc.transact("container") { tx in
            let nameId = store.strings.intern("LEAF")
            for i in 0..<4 {
                let id = tx.add(EntityPrototype(
                    type: .insert, layerId: 0, owner: .block(contIndex),
                    payload: .insert(InsertPayload(blockNameId: nameId,
                                                   position: Vec3(x: Double(i) * 10, y: 0)))))
                if firstId == nil { firstId = id }
            }
        }
        let cont = EditableBlockDef()
        cont.name = "PLAINCONTAINER"
        cont.blockIndex = contIndex
        cont.entityStart = firstId.raw
        cont.entityCount = 4
        parsed.blocks["PLAINCONTAINER"] = cont

        doc.transact("place") { tx in
            _ = tx.add(EntityPrototype(
                type: .insert, layerId: 0, owner: .model,
                payload: .insert(InsertPayload(blockNameId: store.strings.intern("PLAINCONTAINER"),
                                               position: Vec3(x: 0, y: 0)))))
        }

        let built = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        // Only the TOP-LEVEL container instance should exist; the 4 plain
        // nested LEAF inserts must NOT each get their own instance.
        XCTAssertTrue(built.inserts.filter { $0.name == "LEAF" }.isEmpty,
                      "plain (non-attributed) nested inserts must keep inheriting the ancestor's identity")
        XCTAssertEqual(built.inserts.filter { $0.name == "PLAINCONTAINER" }.count, 1)
    }
}
