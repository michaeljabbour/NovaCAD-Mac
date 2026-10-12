import XCTest
import CADCore
@testable import DWGViewer

final class TextLayoutRegressionTests: XCTestCase {
    private func drawing(text: String, width: Double = 30, rotation: Double = 0) throws -> EditableParsedDocument {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("text-layout-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        let pairs: [(Int, String)] = [(0,"SECTION"),(2,"HEADER"),(9,"$INSUNITS"),(70,"4"),(0,"ENDSEC"),
            (0,"SECTION"),(2,"ENTITIES"),(0,"MTEXT"),(5,"10"),(8,"0"),(10,"100"),(20,"200"),
            (40,"2.5"),(41,String(width)),(50,String(rotation)),(71,"1"),(1,text),(0,"ENDSEC"),(0,"EOF")]
        try pairs.map { "\($0.0)\n\($0.1)\n" }.joined().write(to: url, atomically: true, encoding: .utf8)
        return try EntityStoreParser.parse(url: url)
    }

    func testWrappingRespectsReferenceWidthAndKeepsSourceData() throws {
        let source = "Double-leaf interior office door. Hardware finish: Black."
        let parsed = try drawing(text: source)
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        let text = try XCTUnwrap(doc.modelGroups.flatMap(\.texts).first)
        XCTAssertTrue(text.text.contains("\n"))
        XCTAssertEqual(text.text.split(whereSeparator: \.isWhitespace), source.split(whereSeparator: \.isWhitespace))
        for line in text.text.components(separatedBy: "\n") {
            XCTAssertLessThanOrEqual(TextLayout.width(line, height: text.height), 30.01)
        }
        XCTAssertEqual(parsed.store.strings.string(for: parsed.store.mtexts[0].stringId), source)
    }

    func testFitBoundsIncludeWholeRotatedText() throws {
        let parsed = try drawing(text: "Long description that used to run beyond the right edge", width: 0, rotation: 30)
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        let text = try XCTUnwrap(doc.modelGroups.flatMap(\.texts).first)
        XCTAssertGreaterThan(doc.modelBounds.width, 20)
        XCTAssertTrue(doc.modelBounds.insetBy(dx: -0.01, dy: -0.01).contains(text.worldBounds))
    }

    func testSearchCentersAndOutlinesTheTextRatherThanItsAnchor() throws {
        let parsed = try drawing(text: "Prayer Room")
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        let index = SearchIndex(document: doc, store: parsed.store)
        let hit = try XCTUnwrap(index.search("Prayer").first)
        let box = try XCTUnwrap(hit.bounds)
        XCTAssertEqual(hit.position.x, box.midX, accuracy: 0.001)
        XCTAssertEqual(hit.position.y, box.midY, accuracy: 0.001)
        XCTAssertGreaterThan(box.width, 5)
    }

    func testMetricGeometryWithImperialNotesExplainsUnitsWithoutChangingThem() throws {
        let parsed = try drawing(text: "Area: 240 ft²")
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        XCTAssertNotNil(DrawingDiagnostics.unitNotice(in: doc))
        XCTAssertEqual(doc.insUnits, 4)
        let flattenedSquareFeet = try drawing(text: "Square, ft2")
        XCTAssertNotNil(DrawingDiagnostics.unitNotice(in: Regenerator.build(from: flattenedSquareFeet, parseSeconds: 0) { _ in }))
        let metric = try drawing(text: "Dimensions in mm")
        XCTAssertNil(DrawingDiagnostics.unitNotice(in: Regenerator.build(from: metric, parseSeconds: 0) { _ in }))
    }

    func testWrappingPreservesParagraphsAndUnbrokenUnicodeWords() {
        let text = "Room A\n\nVerylongwordwithéand中文"
        let wrapped = TextLayout.wrap(text, height: 2.5, width: 8)
        XCTAssertTrue(wrapped.contains("\n\n"))
        XCTAssertEqual(wrapped.filter { !$0.isWhitespace }, text.filter { !$0.isWhitespace })
        XCTAssertEqual(TextLayout.wrap(text, height: 2.5, width: 0), text)
    }
}

final class PaperOnlyModelTests: XCTestCase {
    private func parse(withPaper: Bool) throws -> EditableParsedDocument {
        let pairs: [(Int, String)] = [(0,"SECTION"),(2,"BLOCKS"),(0,"BLOCK"),(2,"Unused schedule"),(10,"0"),(20,"0"),
            (0,"LINE"),(8,"0"),(10,"0"),(20,"0"),(11,"100"),(21,"100"),(0,"ENDBLK"),(0,"ENDSEC"),
            (0,"SECTION"),(2,"ENTITIES")]
            + (withPaper ? [(0,"LINE"),(67,"1"),(8,"0"),(10,"0"),(20,"0"),(11,"50"),(21,"50")] : [])
            + [(0,"ENDSEC"),(0,"EOF")]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paper-only-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try pairs.map { "\($0.0)\n\($0.1)\n" }.joined().write(to: url, atomically: true, encoding: .utf8)
        return try EntityStoreParser.parse(url: url)
    }

    func testPaperOnlyDrawingDoesNotInventModelFromUnusedBlocks() throws {
        let parsed = try parse(withPaper: true)
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        XCTAssertTrue(doc.modelGroups.isEmpty)
        let coordinator = RegenCoordinator(parsed: parsed, document: doc)
        XCTAssertFalse(coordinator.isOrphanRootBlock(try XCTUnwrap(parsed.blocks["Unused schedule"]).blockIndex))
        XCTAssertFalse(doc.paperGroups.isEmpty)
        XCTAssertNotNil(parsed.blocks["Unused schedule"], "Definition remains available for editing and saving")
    }

    func testLegacyOrphanBlockRecoveryStillWorksWithoutPaperContent() throws {
        let parsed = try parse(withPaper: false)
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        XCTAssertFalse(doc.modelGroups.isEmpty)
        let coordinator = RegenCoordinator(parsed: parsed, document: doc)
        XCTAssertTrue(coordinator.isOrphanRootBlock(try XCTUnwrap(parsed.blocks["Unused schedule"]).blockIndex))
    }
}
