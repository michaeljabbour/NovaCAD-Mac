import XCTest
@testable import DWGViewer

/// Locks in the behavior-preserving refactor of `CommandParser.parse`: every
/// token that used to be handled by the old inline switch statement (see git
/// history of DraftingTools.swift) must still produce the exact same
/// `CommandAction` now that it's resolved through `CommandRegistry`. Also
/// exercises `CommandRegistry.resolve`/`complete` directly, and the
/// coordinate/length parsing paths that sit below the command-name switch.
final class CommandRegistryTests: XCTestCase {

    // MARK: - Every token from the old switch, via CommandParser.parse

    func testDrawToolTokens() {
        XCTAssertEqual(CommandParser.parse("L"), .tool(.line))
        XCTAssertEqual(CommandParser.parse("LINE"), .tool(.line))
        XCTAssertEqual(CommandParser.parse("PL"), .tool(.polyline))
        XCTAssertEqual(CommandParser.parse("PLINE"), .tool(.polyline))
        XCTAssertEqual(CommandParser.parse("POLYLINE"), .tool(.polyline))
        XCTAssertEqual(CommandParser.parse("C"), .tool(.circle))
        XCTAssertEqual(CommandParser.parse("CIRCLE"), .tool(.circle))
        XCTAssertEqual(CommandParser.parse("A"), .tool(.arc3pt))
        XCTAssertEqual(CommandParser.parse("ARC"), .tool(.arc3pt))
        XCTAssertEqual(CommandParser.parse("REC"), .tool(.rect))
        XCTAssertEqual(CommandParser.parse("RECT"), .tool(.rect))
        XCTAssertEqual(CommandParser.parse("RECTANGLE"), .tool(.rect))
        XCTAssertEqual(CommandParser.parse("POL"), .tool(.polygon))
        XCTAssertEqual(CommandParser.parse("POLYGON"), .tool(.polygon))
    }

    func testTextToolAliases() {
        // T / TEXT / MT / MTEXT / DT / DTEXT all map to the same text-note
        // tool — preserved exactly from the old switch.
        for token in ["T", "TEXT", "MT", "MTEXT", "DT", "DTEXT"] {
            XCTAssertEqual(CommandParser.parse(token), .tool(.text), "token: \(token)")
        }
    }

    func testEraseMoveUndo() {
        XCTAssertEqual(CommandParser.parse("E"), .tool(.erase))
        XCTAssertEqual(CommandParser.parse("ERASE"), .tool(.erase))
        XCTAssertEqual(CommandParser.parse("M"), .moveTool)
        XCTAssertEqual(CommandParser.parse("MOVE"), .moveTool)
        XCTAssertEqual(CommandParser.parse("U"), .undo)
        XCTAssertEqual(CommandParser.parse("UNDO"), .undo)
    }

    func testMeasurementTokens() {
        XCTAssertEqual(CommandParser.parse("DI"), .measureDistance)
        XCTAssertEqual(CommandParser.parse("DIST"), .measureDistance)
        XCTAssertEqual(CommandParser.parse("DISTANCE"), .measureDistance)
        XCTAssertEqual(CommandParser.parse("AREA"), .measureArea)
        XCTAssertEqual(CommandParser.parse("AA"), .measureArea)
        XCTAssertEqual(CommandParser.parse("RAD"), .measureRadius)
        XCTAssertEqual(CommandParser.parse("RADIUS"), .measureRadius)
        XCTAssertEqual(CommandParser.parse("DIAMETER"), .measureRadius)
        XCTAssertEqual(CommandParser.parse("DIA"), .measureRadius)
        XCTAssertEqual(CommandParser.parse("ANG"), .measureAngle)
        XCTAssertEqual(CommandParser.parse("ANGLE"), .measureAngle)
    }

    func testZoomSelectCloseTokens() {
        XCTAssertEqual(CommandParser.parse("Z"), .zoomFit)
        XCTAssertEqual(CommandParser.parse("ZE"), .zoomFit)
        XCTAssertEqual(CommandParser.parse("ZOOM"), .zoomFit)
        // ESC / CANCEL / SEL all three map to selectMode — preserved exactly.
        XCTAssertEqual(CommandParser.parse("ESC"), .selectMode)
        XCTAssertEqual(CommandParser.parse("CANCEL"), .selectMode)
        XCTAssertEqual(CommandParser.parse("SEL"), .selectMode)
        XCTAssertEqual(CommandParser.parse("CLOSE"), .closePolyline)
    }

    // MARK: - Phase 4.2: COPY/ROTATE/SCALE/MIRROR tokens

    func testModifyCommandTokens() {
        XCTAssertEqual(CommandParser.parse("CO"), .modify(.copy))
        XCTAssertEqual(CommandParser.parse("CP"), .modify(.copy))
        XCTAssertEqual(CommandParser.parse("COPY"), .modify(.copy))
        XCTAssertEqual(CommandParser.parse("RO"), .modify(.rotate))
        XCTAssertEqual(CommandParser.parse("ROTATE"), .modify(.rotate))
        XCTAssertEqual(CommandParser.parse("SC"), .modify(.scale))
        XCTAssertEqual(CommandParser.parse("SCALE"), .modify(.scale))
        XCTAssertEqual(CommandParser.parse("MI"), .modify(.mirror))
        XCTAssertEqual(CommandParser.parse("MIRROR"), .modify(.mirror))
    }

    func testModifyCommandsDoNotShadowExistingSingleLetterAliases() {
        // E=ERASE, A=ARC, C=CIRCLE, L=LINE, M=MOVE must remain exactly as
        // they were — the plan explicitly calls out these must not be
        // reused by the new two-letter CO/RO/SC/MI aliases.
        XCTAssertEqual(CommandParser.parse("E"), .tool(.erase))
        XCTAssertEqual(CommandParser.parse("A"), .tool(.arc3pt))
        XCTAssertEqual(CommandParser.parse("C"), .tool(.circle))
        XCTAssertEqual(CommandParser.parse("L"), .tool(.line))
        XCTAssertEqual(CommandParser.parse("M"), .moveTool)
    }

    func testSelectTokenAliasesSelectMode() {
        XCTAssertEqual(CommandParser.parse("SELECT"), .selectMode)
    }

    // MARK: - Phase 4.2: PromptContext-dependent scalar parsing

    func testBareNumberIsLengthByDefault() {
        XCTAssertEqual(CommandParser.parse("90"), .length(90))
    }

    func testBareNumberIsScalarWhenContextExpectsIt() {
        XCTAssertEqual(CommandParser.parse("90", context: PromptContext(expectsScalar: true)), .scalar(90))
    }

    func testRelativeAndAbsoluteInputUnaffectedByScalarContext() {
        // Only the BARE-NUMBER case should change meaning; @dx,dy and x,y
        // must parse identically regardless of context.
        let ctx = PromptContext(expectsScalar: true)
        XCTAssertEqual(CommandParser.parse("@5,5", context: ctx), .relative(dx: 5, dy: 5))
        XCTAssertEqual(CommandParser.parse("10,20", context: ctx), .point(CGPoint(x: 10, y: 20)))
    }

    func testCommandNamesUnaffectedByScalarContext() {
        // A recognized command name must resolve normally even with
        // expectsScalar set (context only affects the coordinate-fallback
        // path, never registry resolution).
        XCTAssertEqual(CommandParser.parse("ROTATE", context: PromptContext(expectsScalar: true)), .modify(.rotate))
    }

    func testCaseInsensitivityAndWhitespaceTrimming() {
        XCTAssertEqual(CommandParser.parse("l"), .tool(.line))
        XCTAssertEqual(CommandParser.parse("  line  "), .tool(.line))
        XCTAssertEqual(CommandParser.parse("Line"), .tool(.line))
    }

    // MARK: - Every CommandSpec in CommandRegistry.all resolves via parse()

    func testEveryRegisteredNameAndAliasResolvesThroughParser() {
        for spec in CommandRegistry.all {
            XCTAssertEqual(CommandParser.parse(spec.name), spec.action,
                           "canonical name \(spec.name)")
            for alias in spec.aliases {
                XCTAssertEqual(CommandParser.parse(alias), spec.action,
                               "alias \(alias) of \(spec.name)")
            }
        }
    }

    // MARK: - Coordinate / length input (exact existing behaviors)

    func testAbsolutePoint() {
        XCTAssertEqual(CommandParser.parse("100,50"), .point(CGPoint(x: 100, y: 50)))
    }

    func testRelativePoint() {
        if case .relative(let dx, let dy) = CommandParser.parse("@10,5") {
            XCTAssertEqual(dx, 10)
            XCTAssertEqual(dy, 5)
        } else {
            XCTFail("expected .relative, got \(CommandParser.parse("@10,5"))")
        }
    }

    func testBareLength() {
        XCTAssertEqual(CommandParser.parse("25"), .length(25))
    }

    func testUnknownToken() {
        if case .unknown = CommandParser.parse("XYZZY") {
            // expected
        } else {
            XCTFail("expected .unknown, got \(CommandParser.parse("XYZZY"))")
        }
    }

    func testEmptyInputIsUnknown() {
        XCTAssertEqual(CommandParser.parse(""), .unknown(""))
        XCTAssertEqual(CommandParser.parse("   "), .unknown(""))
    }

    // MARK: - CommandRegistry.resolve

    func testResolveExactNameTakesPriorityOverAlias() {
        // "RADIUS" is a canonical name; make sure it doesn't accidentally
        // fall through to some other spec's alias table.
        XCTAssertEqual(CommandRegistry.resolve("RADIUS")?.name, "RADIUS")
        XCTAssertEqual(CommandRegistry.resolve("RAD")?.name, "RADIUS")
        XCTAssertNil(CommandRegistry.resolve("NOPE"))
    }

    // MARK: - CommandRegistry.complete

    func testCompleteEmptyPrefixReturnsFirstLimitEntries() {
        let result = CommandRegistry.complete(prefix: "", limit: 3)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(Array(result.map(\.name)), Array(CommandRegistry.all.prefix(3).map(\.name)))
    }

    func testCompletePrefersNameOrAliasPrefixOverSynonym() {
        // "L" prefix-matches LINE's alias "L" directly (not via synonym).
        let result = CommandRegistry.complete(prefix: "L", limit: 8)
        XCTAssertTrue(result.contains { $0.name == "LINE" })
    }

    func testCompleteRespectsLimit() {
        let result = CommandRegistry.complete(prefix: "", limit: 2)
        XCTAssertEqual(result.count, 2)
    }

    func testCompleteDedupesAcrossNameAndSynonymPasses() {
        // No command name should ever appear twice in the results even if it
        // matches on both alias and synonym passes.
        let result = CommandRegistry.complete(prefix: "", limit: 100)
        let names = result.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "duplicate command in complete() results")
    }

    // MARK: - PGP alias overrides (built-in vs user override vs canonical name)

    func testUserAliasOverridesBuiltInAliasButNotCanonicalName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("novacad-pgp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pgpURL = dir.appendingPathComponent("acad.pgp")

        // Repoint "C" from CIRCLE to CLOSE.
        try "C, *CLOSE\n".write(to: pgpURL, atomically: true, encoding: .utf8)
        CommandRegistry.reloadUserAliases(from: pgpURL)
        defer {
            // Reset global override state so this test doesn't leak into
            // others (CommandRegistry.userAliasOverrides is process-global).
            CommandRegistry.reloadUserAliases(from: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).pgp"))
        }

        XCTAssertEqual(CommandParser.parse("C"), .closePolyline, "pgp override should repoint the alias")
        // But the canonical name "CIRCLE" still always means Draw Circle.
        XCTAssertEqual(CommandParser.parse("CIRCLE"), .tool(.circle))
    }

    func testUnknownTargetInPGPIsIgnored() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("novacad-pgp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pgpURL = dir.appendingPathComponent("acad.pgp")
        try "Q, *NOTACOMMAND\n".write(to: pgpURL, atomically: true, encoding: .utf8)
        CommandRegistry.reloadUserAliases(from: pgpURL)
        defer {
            CommandRegistry.reloadUserAliases(from: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).pgp"))
        }
        XCTAssertNil(CommandRegistry.resolve("Q"))
    }

    // MARK: - Phase 6.3/6.4 new commands

    func testPhase63DraftToolTokens() {
        XCTAssertEqual(CommandParser.parse("ELLIPSE"), .tool(.ellipse))
        XCTAssertEqual(CommandParser.parse("EL"), .tool(.ellipse))
        XCTAssertEqual(CommandParser.parse("POINT"), .tool(.pointEnt))
        XCTAssertEqual(CommandParser.parse("PO"), .tool(.pointEnt))
        XCTAssertEqual(CommandParser.parse("SPLINE"), .tool(.splineFit))
        XCTAssertEqual(CommandParser.parse("SPL"), .tool(.splineFit))
        XCTAssertEqual(CommandParser.parse("SPLINECV"), .tool(.splineCV))
        XCTAssertEqual(CommandParser.parse("3DFACE"), .tool(.face3d))
        XCTAssertEqual(CommandParser.parse("3DF"), .tool(.face3d))
        XCTAssertEqual(CommandParser.parse("REGION"), .tool(.region))
        XCTAssertEqual(CommandParser.parse("REG"), .tool(.region))
    }

    func testArrayCommand() {
        XCTAssertEqual(CommandParser.parse("ARRAY"), .array)
        XCTAssertEqual(CommandParser.parse("AR"), .array)
    }

    func testClayerCommand() {
        XCTAssertEqual(CommandParser.parse("CLAYER"), .clayer)
    }

    /// None of the new single/double-letter aliases (EL, PO, SPL, 3DF, REG,
    /// AR) may collide with an EXISTING alias/canonical name already in the
    /// registry, nor with a SelectionPrompt sub-token (W/C/F/ALL/P/L/R/A/U)
    /// — a collision with the latter would only matter while a
    /// SelectionPrompt is actively pending (see `ContentView.executeCommand`'s
    /// dedicated pre-registry guard), but confirming no NEW alias exactly
    /// equals one of those single letters is still worth locking in, since
    /// this registry is the single source of truth `CommandParser`/the "/"
    /// autocomplete both read from.
    func testNewAliasesDoNotCollideWithExistingCommandsOrSelectionPromptTokens() {
        let newAliases = ["EL", "PO", "SPL", "SPLINECV", "3DF", "REG", "AR", "CLAYER"]
        let selectionPromptTokens: Set<String> = ["W", "C", "F", "ALL", "P", "L", "R", "A", "U"]
        var seen: [String: String] = [:]   // alias/name -> owning command name
        for spec in CommandRegistry.all {
            for token in [spec.name] + spec.aliases {
                if let existingOwner = seen[token], existingOwner != spec.name {
                    XCTFail("token \"\(token)\" is claimed by both \(existingOwner) and \(spec.name)")
                }
                seen[token] = spec.name
            }
        }
        for alias in newAliases {
            XCTAssertFalse(selectionPromptTokens.contains(alias),
                           "\"\(alias)\" collides with a SelectionPrompt sub-token")
        }
    }

    func testArrayAndClayerAppearInAutocomplete() {
        let arrayResults = CommandRegistry.complete(prefix: "AR", limit: 5)
        XCTAssertTrue(arrayResults.contains { $0.name == "ARRAY" })
        let clayerResults = CommandRegistry.complete(prefix: "CLAYER", limit: 5)
        XCTAssertTrue(clayerResults.contains { $0.name == "CLAYER" })
    }
}
