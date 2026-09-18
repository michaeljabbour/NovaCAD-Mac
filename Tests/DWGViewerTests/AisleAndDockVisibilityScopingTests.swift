import XCTest
@testable import DWGViewer
import CADCore
import CoreGraphics

/// Confirms every aisle/dock extraction entry point honors the CURRENT
/// visibility state (hidden/frozen layers) rather than reading the whole
/// document regardless of what the user has toggled off. This is a hard
/// requirement for all six AI Assistant tools built on `AisleNetwork`/
/// `DockAprons`: "analyze the aisle network" must analyze what's actually
/// on screen right now — a renovation-phase aisle layer or a dock layer the
/// user has deliberately hidden must not silently leak into the analysis,
/// the repaired network, or a generated apron.
final class AisleAndDockVisibilityScopingTests: XCTestCase {

    private func makeParsed() -> EditableParsedDocument {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        parsed.linetypes.append(DXFLinetype(name: "CONTINUOUS", dashes: []))
        parsed.linetypeIdByName["CONTINUOUS"] = 0
        return parsed
    }

    private func addLayer(_ name: String, to parsed: EditableParsedDocument) -> Int32 {
        let id = Int32(parsed.layers.count)
        parsed.layers.append(DXFLayer(id: Int(id), name: name))
        parsed.layerIdByName[name] = id
        return id
    }

    // MARK: - Aisle segment extraction

    func testHiddenAisleLayerIsExcludedFromSegmentExtraction() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        let visibleId = addLayer("AISLE", to: parsed)
        let hiddenId = addLayer("AISLE-OLD", to: parsed)
        doc.transact("Draw") { tx in
            _ = tx.add(EntityPrototype(type: .line, layerId: visibleId, owner: .model,
                                      payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 100, y: 0)))))
            _ = tx.add(EntityPrototype(type: .line, layerId: hiddenId, owner: .model,
                                      payload: .line(LinePayload(a: Vec3(x: 200, y: 0), b: Vec3(x: 300, y: 0)))))
        }
        let built = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }

        var visibility = VisibilityState()
        visibility.hiddenLayerIds = [Int(hiddenId)]

        let withScoping = AisleNetwork.segments(onLayerNamed: "AISLE-OLD", document: built,
                                                space: .model, visibility: visibility)
        XCTAssertTrue(withScoping.isEmpty, "a hidden aisle layer must contribute NO segments")

        let withoutScoping = AisleNetwork.segments(onLayerNamed: "AISLE-OLD", document: built, space: .model)
        XCTAssertFalse(withoutScoping.isEmpty,
                       "omitting visibility must still analyze the full document (explicit opt-out)")
    }

    func testVisibleAisleLayerStillExtractsNormallyWithVisibilityScoping() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        let layerId = addLayer("AISLE", to: parsed)
        doc.transact("Draw") { tx in
            _ = tx.add(EntityPrototype(type: .line, layerId: layerId, owner: .model,
                                      payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 100, y: 0)))))
        }
        let built = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        let visibility = VisibilityState()   // nothing hidden
        let segs = AisleNetwork.segments(onLayerNamed: "AISLE", document: built,
                                         space: .model, visibility: visibility)
        XCTAssertEqual(segs.count, 1, "a visible layer must extract normally when scoped")
    }

    // MARK: - Candidate aisle layer suggestions

    func testCandidateAisleLayersExcludesHiddenLayers() throws {
        let parsed = makeParsed()
        _ = addLayer("AISLE", to: parsed)
        let hiddenId = addLayer("AISLE-DEMO", to: parsed)
        let built = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }

        var visibility = VisibilityState()
        visibility.hiddenLayerIds = [Int(hiddenId)]

        let names = AisleNetwork.candidateAisleLayers(document: built, visibility: visibility)
        XCTAssertTrue(names.contains("AISLE"))
        XCTAssertFalse(names.contains("AISLE-DEMO"),
                       "a hidden layer must not be suggested as a candidate aisle layer")
    }

    // MARK: - Width annotations

    func testHiddenLayerWidthAnnotationsAreExcluded() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        let hiddenId = addLayer("AISLE-OLD", to: parsed)
        doc.transact("Label") { tx in
            let sid = parsed.store.strings.intern("13'-4\" AISLE")
            _ = tx.add(EntityPrototype(type: .text, layerId: hiddenId, owner: .model,
                                      payload: .text(TextPayload(position: Vec3(x: 0, y: 0), height: 6,
                                                                 stringId: sid))))
        }
        let built = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        var visibility = VisibilityState()
        visibility.hiddenLayerIds = [Int(hiddenId)]

        let anns = AisleNetwork.widthAnnotations(onLayerNamed: "AISLE-OLD", document: built,
                                                 space: .model, visibility: visibility)
        XCTAssertTrue(anns.isEmpty, "a width label on a hidden layer must not be read")
    }

    // MARK: - Dock detection (already accepted visibility; locking in the contract)

    func testHiddenDockLayerIsExcludedFromDoorDetection() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        let visibleId = addLayer("Trucks", to: parsed)
        let hiddenId = addLayer("Trucks-Old", to: parsed)
        doc.transact("Label") { tx in
            let s1 = parsed.store.strings.intern("DOCK 1")
            _ = tx.add(EntityPrototype(type: .text, layerId: visibleId, owner: .model,
                                      payload: .text(TextPayload(position: Vec3(x: 0, y: 0), height: 6,
                                                                 stringId: s1))))
            let s2 = parsed.store.strings.intern("DOCK 99")
            _ = tx.add(EntityPrototype(type: .text, layerId: hiddenId, owner: .model,
                                      payload: .text(TextPayload(position: Vec3(x: 500, y: 0), height: 6,
                                                                 stringId: s2))))
        }
        let built = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        var visibility = VisibilityState()
        visibility.hiddenLayerIds = [Int(hiddenId)]

        let doors = DockAprons.detectDockDoors(document: built, space: .model, visibility: visibility)
        XCTAssertTrue(doors.contains { $0.number == 1 })
        XCTAssertFalse(doors.contains { $0.number == 99 },
                       "a dock label on a hidden layer must not be detected")
    }
}
