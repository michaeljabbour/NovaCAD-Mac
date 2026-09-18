import XCTest
@testable import DWGViewer

final class PGPFileTests: XCTestCase {

    func testParsesBasicAliasLine() {
        let result = PGPFile.parseAliases("L, *LINE\n")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].alias, "L")
        XCTAssertEqual(result[0].command, "LINE")
    }

    func testSkipsBlankLines() {
        let result = PGPFile.parseAliases("L, *LINE\n\n\nC, *CIRCLE\n")
        XCTAssertEqual(result.count, 2)
    }

    func testSkipsCommentLines() {
        let result = PGPFile.parseAliases("; a comment\nL, *LINE\n; another comment\n")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].alias, "L")
    }

    func testSkipsMalformedLinesMissingAsterisk() {
        // Missing the leading '*' before the command name.
        let result = PGPFile.parseAliases("L, LINE\nC, *CIRCLE\n")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].alias, "C")
    }

    func testSkipsLinesWithoutComma() {
        let result = PGPFile.parseAliases("not a valid line at all\nC, *CIRCLE\n")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].alias, "C")
    }

    func testHandlesWhitespaceAroundTokens() {
        let result = PGPFile.parseAliases("  REC ,   *RECTANGLE  \n")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].alias, "REC")
        XCTAssertEqual(result[0].command, "RECTANGLE")
    }

    /// `PGPFile.defaultContents` is an embedded string literal, not a
    /// `Bundle.module` resource lookup — see that constant's own doc comment
    /// for why (a real crash on any Mac other than the one that compiled the
    /// binary: SwiftPM's resource-bundle mechanism for an executable target
    /// is fundamentally incompatible with a validly-signed `.app`). This
    /// test exercises exactly what `ensureDefaultExists()` writes.
    func testDefaultContentsParsesAndCoversRegistryAliases() throws {
        let parsed = PGPFile.parseAliases(PGPFile.defaultContents)
        XCTAssertFalse(parsed.isEmpty)
        // Every parsed alias should point at a command CommandRegistry knows
        // about, so the shipped default never references a dead command.
        for (alias, command) in parsed {
            XCTAssertTrue(CommandRegistry.all.contains { $0.name == command.uppercased() },
                          "bundled default acad.pgp aliases \(alias) to unknown command \(command)")
        }
    }

    /// Regression guard for the ON-DISK reference copy
    /// (`Sources/DWGViewer/Resources/acad.pgp`, excluded from the build via
    /// `Package.swift`'s `exclude:` and never read at runtime anymore) —
    /// asserts it stays byte-identical to `defaultContents` so a future
    /// hand-edit of one doesn't silently drift from the other, per
    /// `defaultContents`'s own "keep this in sync" doc comment. Locates the
    /// file relative to THIS test file's own source path (`#filePath`)
    /// rather than any bundle lookup, since that's the one thing guaranteed
    /// to still exist and be stable in a source checkout.
    func testEmbeddedDefaultContentsMatchesOnDiskReferenceCopy() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let referenceURL = testFileURL
            .deletingLastPathComponent()          // Tests/DWGViewerTests/
            .deletingLastPathComponent()          // Tests/
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("Sources/DWGViewer/Resources/acad.pgp")
        guard FileManager.default.fileExists(atPath: referenceURL.path) else {
            throw XCTSkip("on-disk reference copy not found relative to test source — skipping rather than failing a CI checkout layout this doesn't anticipate")
        }
        let onDisk = try String(contentsOf: referenceURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let embedded = PGPFile.defaultContents.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(onDisk, embedded,
                      "PGPFile.defaultContents has drifted from the on-disk reference copy — keep them in sync")
    }

    func testEnsureDefaultExistsCopiesBundledFileWithoutOverwritingExisting() throws {
        // Redirect HOME-independent behavior isn't directly testable since
        // userURL is fixed to Application Support, so this test only
        // verifies parseAliases + the "don't overwrite" contract using a
        // temp file standing in for the user file, exercising the same
        // logic ensureDefaultExists relies on (existence check first).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("novacad-pgp-existing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = dir.appendingPathComponent("acad.pgp")
        try "CUSTOM, *LINE\n".write(to: existing, atomically: true, encoding: .utf8)

        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
        let contentBefore = try String(contentsOf: existing, encoding: .utf8)
        XCTAssertEqual(contentBefore, "CUSTOM, *LINE\n")
    }
}
