import XCTest
@testable import DWGViewer

final class LayerDisplayNameTests: XCTestCase {
    func testBlockAndPatternAliasesPreserveDistinctIdentifiers() {
        XCTAssertEqual(LayerDisplayName.englishAlias(for: "Чертеж_32_2"), "Drawing 32 2")
        XCTAssertEqual(LayerDisplayName.englishAlias(for: "Чертеж_33_1"), "Drawing 33 1")
        XCTAssertEqual(LayerDisplayName.englishAlias(for: "Линия_1"), "Line 1")
        XCTAssertEqual(LayerDisplayName.englishAlias(for: "ШТУКАТУРКА__ГИПС_03_0001"), "Plaster - gypsum 03 0001")
        XCTAssertTrue(LayerDisplayName.matches("Чертеж_32_2", search: "drawing 32"))
        XCTAssertEqual(LayerDisplayName.display("Чертеж_32_2", inEnglish: false), "Чертеж_32_2")
    }

    func testEnglishAliasesKeepNumbersAndXrefNames() {
        XCTAssertEqual(LayerDisplayName.englishAlias(for: "ОФИС|05 - МЕБЕЛЬ"), "ОФИС|05 - Furniture")
        XCTAssertEqual(LayerDisplayName.englishAlias(for: "01 - СТЕНЫ СУЩЕСТВУЮЩИЕ 1"), "01 - Existing walls 1")
        XCTAssertEqual(LayerDisplayName.englishAlias(for: "11 - РАЗМЕРЫ_ВЫНОСКИ_ПРИМЕЧАНИЯ СВЕТ ПОТОЛОК"),
                       "11 - Dimensions & notes Ceiling lighting")
        XCTAssertEqual(LayerDisplayName.englishAlias(for: "02_МОНТАЖ 1 Стены_1_0"), "02 Construction 1 Walls 1 0")
    }

    func testUnknownAndEnglishNamesAreNotInvented() {
        XCTAssertNil(LayerDisplayName.englishAlias(for: "A-WALL"))
        XCTAssertNil(LayerDisplayName.englishAlias(for: "ПРОИЗВОЛЬНОЕ ИМЯ"))
        XCTAssertNil(LayerDisplayName.englishAlias(for: "ПОДСТЕНЫ"))
    }

    func testSearchMatchesBothLanguages() {
        XCTAssertTrue(LayerDisplayName.matches("05 - МЕБЕЛЬ", search: "furniture"))
        XCTAssertTrue(LayerDisplayName.matches("05 - МЕБЕЛЬ", search: "мебель"))
        XCTAssertFalse(LayerDisplayName.matches("05 - МЕБЕЛЬ", search: "plumbing"))
    }

    func testRepeatedIsolationRestoresPreexistingHiddenLayers() {
        var state = LayerIsolationState()
        var hidden: Set<Int> = [3]
        state.isolate([1], allLayerIDs: [1, 2, 3], hidden: &hidden)
        XCTAssertEqual(hidden, [2, 3])
        state.isolate([2], allLayerIDs: [1, 2, 3], hidden: &hidden)
        XCTAssertEqual(hidden, [1, 3])
        state.restore(hidden: &hidden)
        XCTAssertEqual(hidden, [3])
        XCTAssertNil(state.previousHidden)
    }

    func testEmptyIsolationDoesNotHideEverything() {
        var state = LayerIsolationState()
        var hidden: Set<Int> = [3]
        state.isolate([], allLayerIDs: [1, 2, 3], hidden: &hidden)
        XCTAssertEqual(hidden, [3])
        XCTAssertNil(state.previousHidden)
    }
}
