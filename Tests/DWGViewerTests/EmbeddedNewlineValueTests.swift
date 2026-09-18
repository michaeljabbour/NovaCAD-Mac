import XCTest
@testable import DWGViewer
import CADCore

/// Regression test for a real bug on DWG→DXF-converted plant layouts: a
/// string value (here an MTEXT group-1 blob) that contains a LITERAL embedded
/// newline spans TWO physical lines in the DXF. NovaCAD's parser historically
/// keyed code/value pairing off global line-number parity, so the value's
/// second physical line was mistaken for the next group CODE — desyncing
/// every code/value pair for the ENTIRE REST OF THE FILE. On a real layout
/// that meant the whole ENTITIES section (hundreds of INSERT workstations +
/// thousands of ATTRIB data values, ~900k lines after the offending blob) was
/// silently dropped: nothing drawn, nothing extractable.
///
/// GNU LibreDWG (`dwg2dxf`) produces exactly this shape on complex drawings;
/// ODA File Converter does not, which is why the symptom looked
/// converter-dependent. The parser now resynchronizes (a line where a code is
/// expected that isn't a valid DXF group code is treated as the tail of the
/// previous multi-physical-line value), so content AFTER the embedded-newline
/// value is no longer lost regardless of converter.
///
/// The fixture `embedded_newline_value.dxf` has, in ENTITIES order: an MTEXT
/// whose group-1 value spans two physical lines, then a LINE, a TEXT, and a
/// CIRCLE — all three of which the old parity logic dropped.
final class EmbeddedNewlineValueTests: XCTestCase {

    private func parsed() throws -> EditableParsedDocument {
        try EntityStoreParser.parse(url: TestFixtures.url("embedded_newline_value.dxf"))
    }

    func testEntitiesAfterAnEmbeddedNewlineValueAreNotDropped() throws {
        let store = try parsed().store
        var byType: [DXFEntityType: Int] = [:]
        for i in store.headers.indices where !store.headers[i].flags.contains(.deleted) {
            byType[store.headers[i].type, default: 0] += 1
        }
        // All four ENTITIES-section records must survive — the LINE, TEXT,
        // and CIRCLE all follow the embedded-newline MTEXT value.
        XCTAssertEqual(byType[.mtext], 1, "the MTEXT itself must parse")
        XCTAssertEqual(byType[.line], 1, "the LINE after the embedded-newline value must not be dropped")
        XCTAssertEqual(byType[.text], 1, "the TEXT after the embedded-newline value must not be dropped")
        XCTAssertEqual(byType[.circle], 1, "the CIRCLE after the embedded-newline value must not be dropped")
    }

    func testTextContentAfterEmbeddedNewlineIsReadable() throws {
        let store = try parsed().store
        var found = false
        for i in store.headers.indices where store.headers[i].type == .text {
            let h = store.headers[i]
            guard h.payload >= 0 else { continue }
            if store.strings.string(for: store.texts[Int(h.payload)].stringId) == "VISIBLE AFTER THE EMBEDDED NEWLINE" {
                found = true
            }
        }
        XCTAssertTrue(found, "the TEXT value following the desync-causing blob must be intact")
    }
}
