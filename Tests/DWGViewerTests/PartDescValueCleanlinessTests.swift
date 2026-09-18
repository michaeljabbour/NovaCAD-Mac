import XCTest
@testable import DWGViewer
import CADCore

/// Verifies that PART_DESC attribute VALUES parsed from the real converted
/// plant-layout DXF are CLEAN plain text — i.e. free of raw MTEXT formatting
/// codes (`\W1.5000;`, `\A1;`, `{...}` groups, etc). These attributes are
/// stored as MTEXT-embedded ATTRIBs (a `101 Embedded Object` sub-record whose
/// own group-1 carries the formatted string), so the parser must land on the
/// plain group-1 value and/or strip the codes — never surface them to the
/// Properties panel / Data Extraction.
///
/// Skips silently when the fixture isn't present so CI/other machines stay
/// green.
final class PartDescValueCleanlinessTests: XCTestCase {

    private var fixtureURL: URL? {
        guard let path = ProcessInfo.processInfo.environment["NOVACAD_SAMPLE_LAYOUT"] else { return nil }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    func testPartDescValuesCarryNoMTextFormattingCodes() throws {
        guard let url = fixtureURL else { throw XCTSkip("real converted DXF fixture not present") }
        let parsed = try EntityStoreParser.parse(url: url)
        let store = parsed.store

        var values: [String] = []
        for i in store.headers.indices {
            let h = store.headers[i]
            guard h.type == .attrib, !h.flags.contains(.deleted), h.payload >= 0 else { continue }
            let t = store.texts[Int(h.payload)]
            guard t.tagStringId >= 0,
                  store.strings.string(for: t.tagStringId) == "PART_DESC" else { continue }
            values.append(store.strings.string(for: t.stringId))
        }
        XCTAssertFalse(values.isEmpty, "fixture must contain PART_DESC attributes")

        // Any residual MTEXT control code is a bug. `\W` (width factor) is
        // the one actually observed in this file; the others are checked so a
        // future regression in `MTextParser` is caught here too.
        let offenders = values.filter { v in
            v.contains("\\W") || v.contains("\\A") || v.contains("\\H")
                || v.contains("\\f") || v.contains("\\F") || v.contains("\\pxq")
        }
        if !offenders.isEmpty {
            print("=== PART_DESC values still carrying MTEXT codes (\(offenders.count)) ===")
            for v in offenders.prefix(20) { print("   ", v.debugDescription) }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "\(offenders.count) of \(values.count) PART_DESC values contain raw MTEXT formatting codes; first: \(offenders.first?.debugDescription ?? "-")")

        // Also confirm no value is doubled (the "clean value concatenated
        // with the formatted value" failure mode the group-3 continuation
        // loop could produce for an MTEXT-embedded ATTRIB).
        let doubled = values.filter { v in
            guard v.count >= 4, v.count % 2 == 0 else { return false }
            let mid = v.index(v.startIndex, offsetBy: v.count / 2)
            return String(v[v.startIndex..<mid]) == String(v[mid..<v.endIndex])
        }
        XCTAssertTrue(doubled.isEmpty,
                      "\(doubled.count) PART_DESC value(s) look duplicated; first: \(doubled.first?.debugDescription ?? "-")")

        print("=== PART_DESC value cleanliness ===")
        print("values checked: \(values.count), distinct: \(Set(values).count)")
        for v in Array(Set(values)).sorted().prefix(10) { print("   ", v.debugDescription) }
    }
}
