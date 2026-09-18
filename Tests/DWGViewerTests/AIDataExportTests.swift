import XCTest
@testable import DWGViewer

final class AIDataExportTests: XCTestCase {
    func testCSVFieldEscapesCommasQuotesAndNewlines() {
        XCTAssertEqual(AIDataExport.csvField("plain"), "plain")
        XCTAssertEqual(AIDataExport.csvField("a,b"), "\"a,b\"")
        XCTAssertEqual(AIDataExport.csvField("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(AIDataExport.csvField("a\nb"), "\"a\nb\"")
    }

    func testWriteCSVCreatesUserAccessibleFile() throws {
        let filename = "NovaCAD-Test-\(UUID().uuidString).csv"
        let url = try AIDataExport.writeCSV(columns: ["name", "distance"],
                                            rows: [["Station, A", "12.5"]], filename: filename)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(url.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"Station, A\",12.5"))
    }
}
