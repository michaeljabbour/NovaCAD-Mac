import XCTest
@testable import DWGViewer
import CADCore

/// Pins the xref → dependent-layer attribution used by the Layers panel to
/// group layers under their owning xref (and to hide an xref's layers when the
/// xref itself is toggled off). Dependent layers are named `XREFNAME|layer`,
/// with the xref block name's `$` nesting separators converted to `|`.
final class XrefLayerGroupingTests: XCTestCase {

    private func xref(_ name: String, id: Int = 0) -> XrefInfo {
        XrefInfo(id: id, blockName: name, path: name,
                 sourcePath: "/tmp/\(name).dwg", loadedPath: "/tmp/\(name).dxf",
                 isResolved: true,
                 entityCount: 1, insertCount: 1)
    }

    func testTopLevelXrefLayerPrefix() {
        let x = xref("BUILDING")
        XCTAssertEqual(x.layerPrefix, "BUILDING|")
        XCTAssertTrue(x.owns(layerNamed: "BUILDING|Walls"))
        XCTAssertFalse(x.owns(layerNamed: "OTHER|Walls"))
        XCTAssertFalse(x.owns(layerNamed: "Walls"))
    }

    func testNestedXrefUsesPipeSeparatedPrefix() {
        // Nested xref block names use '$'; their dependent LAYER names use '|'.
        let x = xref("PARENT$CHILD")
        XCTAssertEqual(x.layerPrefix, "PARENT|CHILD|")
        XCTAssertTrue(x.owns(layerNamed: "PARENT|CHILD|Steel"))
        // The parent's own prefix must NOT match a child's layer beyond the
        // shared "PARENT|" head — that's why grouping matches longest-first.
        XCTAssertFalse(x.owns(layerNamed: "PARENT|Steel"))
    }

    func testParentAndChildDisambiguateByLongestPrefix() {
        let parent = xref("PARENT", id: 1)
        let child = xref("PARENT$CHILD", id: 2)
        let layerName = "PARENT|CHILD|Beam"
        // Both technically match "PARENT|..." at the head, but the child's
        // longer prefix is the correct owner.
        XCTAssertTrue(parent.owns(layerNamed: layerName))   // shares "PARENT|"
        XCTAssertTrue(child.owns(layerNamed: layerName))
        XCTAssertGreaterThan(child.layerPrefix.count, parent.layerPrefix.count)
    }

    // MARK: - Subtree collection (toggling a parent hides its nested xrefs)

    func testSubtreeIncludesSelfAndDescendantsByName() {
        // Mirrors a production drawing: a top-level xref plus two nested
        // children named "SITE-A...$CHILD".
        let xrefs = [
            xref("SITE-A - PLT-001 - CARRIER TRANSFER", id: 2),
            xref("SITE-A - PLT-001 - CARRIER TRANSFER$LVL-F-01-CONV-FRONT CLIP SKID", id: 3),
            xref("SITE-A - PLT-001 - CARRIER TRANSFER$LVL-F-01-GD-BLDG-LEVEL-Q-P-0001", id: 4),
            xref("SOME OTHER STATION", id: 5),
        ]
        let subtree = xrefs.subtreeXrefIds(of: xrefs[0])
        XCTAssertEqual(subtree, [2, 3, 4], "hiding SITE-A must hide it and its nested xrefs")
    }

    func testSubtreeOfASiblingDoesNotLeakAcrossStations() {
        let xrefs = [
            xref("SITE-A - PLT-001 - CARRIER TRANSFER", id: 2),
            xref("SITE-A - PLT-001 - CARRIER TRANSFER$CHILD", id: 3),
            xref("OTHER STATION", id: 5),
            // A copy of the same source embedded under a DIFFERENT parent is a
            // DIFFERENT block name — it belongs to that parent's subtree only.
            xref("OTHER STATION$SITE-A - PLT-001 - CARRIER TRANSFER", id: 6),
        ]
        XCTAssertEqual(xrefs.subtreeXrefIds(of: xrefs[0]), [2, 3],
                       "the SITE-A copy under OTHER STATION must NOT be hidden by toggling top-level SITE-A")
        XCTAssertEqual(xrefs.subtreeXrefIds(of: xrefs[2]), [5, 6],
                       "OTHER STATION's subtree includes its own embedded SITE-A copy")
    }

    func testSubtreeOfLeafIsJustItself() {
        let xrefs = [xref("A", id: 0), xref("A$B", id: 1)]
        XCTAssertEqual(xrefs.subtreeXrefIds(of: xrefs[1]), [1])
    }

    // MARK: - Source-drawing identity (toggle a drawing ONCE, hidden everywhere)

    func testSourceDrawingNameIsTerminalSegment() {
        XCTAssertEqual(xref("SITE-A").sourceDrawingName, "SITE-A")
        XCTAssertEqual(xref("OTHER$SITE-A").sourceDrawingName, "SITE-A")
        XCTAssertEqual(xref("A$B$C").sourceDrawingName, "C")
    }

    func testXrefIdsSharingSourceHitsEveryParentReference() {
        // Same source drawing "SITE-A" referenced under three different parents,
        // plus a nested child under one of them.
        let xrefs = [
            xref("SITE-A", id: 1),                 // top-level
            xref("STATION-A$SITE-A", id: 2),       // under station A
            xref("STATION-B$SITE-A", id: 3),       // under station B
            xref("SITE-A$SUBASSEMBLY", id: 4),     // a child nested inside SITE-A
            xref("UNRELATED", id: 9),
        ]
        // Toggling ANY SITE-A reference hides every SITE-A reference (1,2,3) plus the
        // nested subtree under each (4 is under SITE-A id 1).
        let affected = xrefs.xrefIdsSharingSource(with: xrefs[1]) // STATION-A$SITE-A
        XCTAssertEqual(affected, [1, 2, 3, 4],
                       "toggling one occurrence of a source drawing hides it everywhere + its nested xrefs")
        XCTAssertFalse(affected.contains(9))
    }

    func testGroupedBySourceDrawingCollapsesDuplicates() {
        let xrefs = [
            xref("SITE-A", id: 1),
            xref("STATION-A$SITE-A", id: 2),
            xref("STATION-B$SITE-A", id: 3),
            xref("BUILDING", id: 4),
        ]
        let rows = xrefs.groupedBySourceDrawing()
        // Two unique source drawings: SITE-A and BUILDING.
        XCTAssertEqual(rows.count, 2)
        let names = Set(rows.map(\.blockName))
        XCTAssertEqual(names, ["SITE-A", "BUILDING"])
        // The SITE-A row accumulates all three references' entity/insert counts.
        let siteA = rows.first { $0.blockName == "SITE-A" }!
        XCTAssertEqual(siteA.insertCount, 3)
        XCTAssertEqual(siteA.entityCount, 3)
    }
}
