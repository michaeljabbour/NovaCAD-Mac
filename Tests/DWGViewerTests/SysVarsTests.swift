import XCTest
@testable import DWGViewer
import CADCore

/// `SysVars` is a `@MainActor` type, so this suite is `@MainActor` too — the
/// same convention `CommandLineStateTests` uses. That makes every `SysVars`
/// access (init, `set`, `point`, the static `registry`) run in the correct
/// isolation without per-call `await MainActor.run { }` wrappers. (WS-N1)
@MainActor
final class SysVarsTests: XCTestCase {

    /// Every UserDefaults key this suite might touch, cleared before/after
    /// each test so runs don't leak persisted state into each other or into
    /// a real user profile running the same test binary.
    private func clearPersistedDefaults() {
        let d = UserDefaults.standard
        for def in SysVars.registry {
            d.removeObject(forKey: "novacad.sysvar.\(def.name)")
        }
    }

    // Use the async setUp/tearDown overrides: because this class is @MainActor,
    // the async variants inherit main-actor isolation, so calling the
    // @MainActor `clearPersistedDefaults()` here is race-free. The synchronous
    // overrides are nonisolated (task-isolated) and would flag sending `self`
    // into a main-actor method as a data race under Swift 6. (WS-N1)
    override func setUp() async throws {
        try await super.setUp()
        clearPersistedDefaults()
    }

    override func tearDown() async throws {
        clearPersistedDefaults()
        try await super.tearDown()
    }

    func testRegistryHasExpectedCountAndNoDuplicateNames() {
        let names = SysVars.registry.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "duplicate sysvar name in registry")
        XCTAssertEqual(SysVars.registry.count, 33)
    }

    func testDefaultsMatchSpec() {
        let vars = SysVars()
        XCTAssertEqual(vars.int("INSUNITS"), 1)
        XCTAssertEqual(vars.int("MEASUREMENT"), 0)
        XCTAssertEqual(vars.double("LTSCALE"), 1.0)
        XCTAssertEqual(vars.double("CELTSCALE"), 1.0)
        XCTAssertEqual(vars.double("ANGBASE"), 0.0)
        XCTAssertEqual(vars.int("ANGDIR"), 0)
        XCTAssertEqual(vars.int("PDMODE"), 0)
        XCTAssertEqual(vars.double("PDSIZE"), 0.0)
        XCTAssertEqual(vars.int("MIRRTEXT"), 0)
        XCTAssertEqual(vars.int("TILEMODE"), 1)
        XCTAssertEqual(vars.string("HPNAME"), "ANSI31")
        XCTAssertEqual(vars.double("HPSCALE"), 1.0)
        XCTAssertEqual(vars.double("HPANG"), 0.0)
        XCTAssertEqual(vars.int("HPASSOC"), 1)
        XCTAssertEqual(vars.int("PICKFIRST"), 1)
        XCTAssertEqual(vars.int("PICKADD"), 1)
        XCTAssertEqual(vars.int("PICKAUTO"), 1)
        XCTAssertEqual(vars.int("PICKBOX"), 5)
        XCTAssertEqual(vars.int("EDGEMODE"), 0)
        XCTAssertEqual(vars.int("OSMODE"), 4133)
        XCTAssertEqual(vars.int("AUTOSNAP"), 63)
        XCTAssertEqual(vars.int("DYNMODE"), 3)
        XCTAssertEqual(vars.int("GRIDMODE"), 0)
        XCTAssertEqual(vars.point("GRIDUNIT"), CGPoint(x: 10, y: 10))
        XCTAssertEqual(vars.int("SNAPMODE"), 0)
        XCTAssertEqual(vars.point("SNAPUNIT"), CGPoint(x: 10, y: 10))
        XCTAssertEqual(vars.int("ORTHOMODE"), 0)
        XCTAssertEqual(vars.int("POLARMODE"), 0)
        XCTAssertEqual(vars.double("POLARANG"), 90.0)
        XCTAssertEqual(vars.int("LWDISPLAY"), 0)
        XCTAssertEqual(vars.double("FILLETRAD"), 0.0)
        XCTAssertEqual(vars.int("TRIMMODE"), 1)
        XCTAssertEqual(vars.double("OFFSETDIST"), 1.0)
    }

    func testSetReturnsOldValueAndUpdatesGet() {
        let vars = SysVars()
        let old = vars.set("MIRRTEXT", .int(1))
        XCTAssertEqual(old, .int(0))
        XCTAssertEqual(vars.int("MIRRTEXT"), 1)
    }

    func testSetUnknownNameReturnsNil() {
        let vars = SysVars()
        XCTAssertNil(vars.set("NOTAREALVAR", .int(1)))
    }

    func testValidationClampsIntRange() {
        let vars = SysVars()
        // MEASUREMENT is clamped 0...1 — setting 5 should clamp to 1.
        vars.set("MEASUREMENT", .int(5))
        XCTAssertEqual(vars.int("MEASUREMENT"), 1)
    }

    func testValidationRejectsWrongType() {
        let vars = SysVars()
        // HPNAME is a string var; passing a bool should be rejected (nil),
        // leaving the old value in place.
        let result = vars.set("HPNAME", .bool(true))
        XCTAssertNil(result)
        XCTAssertEqual(vars.string("HPNAME"), "ANSI31")
    }

    func testNonNegativeDoubleRejectsNegative() {
        let vars = SysVars()
        // LTSCALE must stay non-negative; -5 clamps to 0.
        vars.set("LTSCALE", .double(-5))
        XCTAssertEqual(vars.double("LTSCALE"), 0)
    }

    func testToggleBoolLikeIntVar() {
        let vars = SysVars()
        XCTAssertEqual(vars.int("GRIDMODE"), 0)
        vars.toggle("GRIDMODE")
        XCTAssertEqual(vars.int("GRIDMODE"), 1)
        vars.toggle("GRIDMODE")
        XCTAssertEqual(vars.int("GRIDMODE"), 0)
    }

    func testPersistenceRoundTripsAcrossInstances() {
        let vars1 = SysVars()
        vars1.set("PICKBOX", .int(12))
        let vars2 = SysVars()
        XCTAssertEqual(vars2.int("PICKBOX"), 12, "value set on one instance should persist for a fresh instance")
    }

    func testPointRoundTrip() {
        let vars1 = SysVars()
        vars1.set("GRIDUNIT", .point2(CGPoint(x: 5, y: 7)))
        let vars2 = SysVars()
        XCTAssertEqual(vars2.point("GRIDUNIT"), CGPoint(x: 5, y: 7))
    }
}
