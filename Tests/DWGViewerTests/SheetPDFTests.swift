import XCTest
import CADCore
import CoreGraphics
@testable import DWGViewer

final class SheetPDFTests: XCTestCase {
    func testPDFHasSeparatePagesAtRequestedPaperSizeAndKeepsActiveSheet() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("multiple_layouts.dxf"))
        parsed.activePaperLayoutID = 0x23
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sheets-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        let warnings = try SheetPDFExporter.write(parsed, to: file,
            options: PDFExportOptions(sheets: [0x1B, 0x23], paper: .a4, scale: .fit))
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(parsed.activePaperLayoutID, 0x23)
        let pdf = try XCTUnwrap(CGPDFDocument(file as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 2)
        let page = try XCTUnwrap(pdf.page(at: 1))
        XCTAssertEqual(page.getBoxRect(.mediaBox).width, 297 * 72 / 25.4, accuracy: 0.01)
        XCTAssertEqual(page.getBoxRect(.mediaBox).height, 210 * 72 / 25.4, accuracy: 0.01)
        let context = try XCTUnwrap(CGContext(data: nil, width: 842, height: 596, bitsPerComponent: 8, bytesPerRow: 842 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 842, height: 596))
        context.drawPDFPage(page)
        let pixels = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: 842 * 596 * 4)
        XCTAssertTrue((0..<(842 * 596)).contains { pixels[$0 * 4] < 128 }, "Vector page must contain visible linework")
    }
    func testActualScaleAndRotationUsePhysicalUnits() {
        var setup = SheetPageSetup(layout: nil)
        setup.widthMM = 297; setup.heightMM = 210; setup.unitsMM = 1; setup.rotation = 1
        let t = SheetPDFExporter.transform(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), setup: setup, mode: .actual)
        let a = CGPoint.zero.applying(t), b = CGPoint(x: 25.4, y: 0).applying(t)
        XCTAssertEqual(hypot(a.x - b.x, a.y - b.y), 72, accuracy: 1e-8)
        XCTAssertEqual(a.x, 210 * 72 / 25.4, accuracy: 1e-8)
        XCTAssertEqual(setup.pageSize.width, 210 * 72 / 25.4, accuracy: 1e-8)
        XCTAssertEqual(CGRenderCore.plotStrokeWidth(50), 0.5 * 72 / 25.4, accuracy: 1e-8)
    }
    func testStoredPaperSetupParsesOnlyPlotSubclass() {
        let layout = LayoutObject(handle: 1, ownerHandle: 0, name: "Sheet", blockRecordHandle: 2,
            plotSettingsHandle: nil, tabOrder: 1, rawPairs: [
                RawGroupPair(code: 100, value: .string("AcDbPlotSettings")),
                RawGroupPair(code: 44, value: .double(431.8)), RawGroupPair(code: 45, value: .double(279.4)),
                RawGroupPair(code: 72, value: .int(0)), RawGroupPair(code: 142, value: .double(1)), RawGroupPair(code: 143, value: .double(50)),
                RawGroupPair(code: 100, value: .string("AcDbLayout")), RawGroupPair(code: 45, value: .double(999))])
        let setup = SheetPageSetup(layout: layout)
        XCTAssertEqual(setup.heightMM, 279.4)
        XCTAssertEqual(setup.unitsMM, 25.4)
        XCTAssertEqual(setup.scale, 0.02)
    }
    func testLayerLineweightSurvivesRoundtrip() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("multiple_layouts.dxf"))
        parsed.layers[0].lineweight = 70
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("weight-\(UUID()).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DrawingFileWriter.write(parsed, to: url)
        let restored = try EntityStoreParser.parse(url: url)
        XCTAssertEqual(restored.layers[0].lineweight, 70)
    }

    func testFailedExportPreservesExistingDestination() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("multiple_layouts.dxf"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("existing-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("original document".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(try SheetPDFExporter.write(parsed, to: url, options: PDFExportOptions(sheets: [999999])))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
