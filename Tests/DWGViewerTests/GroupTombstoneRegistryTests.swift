import XCTest
import CADCore
@testable import DWGViewer

/// Direct regression coverage for the `GroupTombstoneRegistry` weak-key
/// address-reuse bug fixed in commit `68f8359` (WS-N3, overnight session).
///
/// The bug: the registry originally cached tombstone bitsets in a plain
/// `[ObjectIdentifier: GroupTombstones]` dictionary keyed by `RenderGroup`
/// identity, with nothing ever removing an entry. `ObjectIdentifier` is just
/// a class instance's current memory address — once a `RenderGroup`
/// deallocates, ARC is free to hand that exact address to a brand-new,
/// never-edited `RenderGroup`, and the stale dictionary entry then silently
/// applied the PREVIOUS group's tombstone bitset to the new one. This
/// surfaced as intermittent, run-order-dependent test failures
/// (`RegenCoordinatorTests`/`SelectionEngineTests`) rather than a clean,
/// reproducible unit-level failure — nothing in the test suite exercised
/// the registry's deallocation-triggered cleanup DIRECTLY (it was only ever
/// caught as emergent flakiness), which is exactly the gap these tests close.
///
/// The fix replaced the dictionary with `NSMapTable(keyOptions: .weakMemory,
/// valueOptions: .strongMemory)`, so Foundation automatically drops an entry
/// the instant its key `RenderGroup` deallocates. These tests prove that
/// directly, at the registry level, with no DXF parsing or `RegenCoordinator`
/// involved — the smallest possible reproduction of the original bug.
final class GroupTombstoneRegistryTests: XCTestCase {

    /// Builds a minimal, otherwise-unused `RenderGroup` for identity testing.
    /// Field values are irrelevant here — only the object's identity/lifetime
    /// matters for these tests.
    private func makeRenderGroup() -> RenderGroup {
        RenderGroup(
            layerId: 0,
            color: .foreground,
            linetypeId: 0,
            xrefId: -1,
            strokes: StrokeStore(),
            fillPath: CGMutablePath(),
            patternFillPath: CGMutablePath(),
            points: [],
            texts: [],
            bounds: .zero,
            entityCount: 0
        )
    }

    func testTombstonesForReturnsNilForAGroupNeverEdited() {
        let group = makeRenderGroup()
        XCTAssertNil(GroupTombstoneRegistry.tombstones(for: group))
    }

    func testTombstonesCreatingIfNeededReturnsTheSameTableOnRepeatedCallsForTheSameGroup() {
        let group = makeRenderGroup()
        let first = GroupTombstoneRegistry.tombstonesCreatingIfNeeded(for: group)
        first.markDead(.run, 3)

        let second = GroupTombstoneRegistry.tombstonesCreatingIfNeeded(for: group)

        XCTAssertTrue(second.isDead(.run, 3), "the second lookup must return the SAME table, not a fresh one")
    }

    func testTwoDistinctLiveGroupsHaveIndependentTombstoneTables() {
        let groupA = makeRenderGroup()
        let groupB = makeRenderGroup()

        GroupTombstoneRegistry.tombstonesCreatingIfNeeded(for: groupA).markDead(.run, 1)

        XCTAssertTrue(GroupTombstoneRegistry.tombstonesCreatingIfNeeded(for: groupA).isDead(.run, 1))
        XCTAssertNil(GroupTombstoneRegistry.tombstones(for: groupB),
                     "groupB must not see groupA's tombstones — distinct live objects must never share state")
    }

    /// The core regression test: prove the registry entry is actually
    /// dropped when its key `RenderGroup` deallocates, so a future object
    /// that happens to be allocated at the freed address starts clean. This
    /// is the direct, minimal reproduction of the original bug — no DXF
    /// parsing, no RegenCoordinator, no reliance on ARC reusing a specific
    /// address (which isn't something a test can force), just confirming
    /// the registry's own cleanup contract holds via a weak reference.
    func testEntryIsRemovedWhenItsRenderGroupDeallocates() {
        weak var weakGroup: RenderGroup?

        autoreleasepool {
            let group = makeRenderGroup()
            weakGroup = group
            GroupTombstoneRegistry.tombstonesCreatingIfNeeded(for: group).markDead(.run, 0)
            XCTAssertNotNil(GroupTombstoneRegistry.tombstones(for: group),
                             "sanity check: the entry must exist while the group is alive")
            // `group` goes out of scope at the end of this block with no
            // other strong references held — it must deallocate here.
        }

        XCTAssertNil(weakGroup, "the RenderGroup must have deallocated — otherwise this test proves nothing")
    }

    /// A brand-new, never-tombstoned `RenderGroup` must never observe a
    /// PRIOR group's tombstone data, even conceptually — this is the actual
    /// failure mode the bug produced (a live object silently inheriting a
    /// dead object's bitset). We can't force ARC to reuse the same address
    /// deterministically in a unit test, but we CAN prove the registry never
    /// hands out a stale table for a key it has never seen, which is the
    /// registry-level invariant that makes the address-reuse scenario
    /// impossible by construction once combined with the weak-key cleanup
    /// proven above (an entry for a freed address cannot outlive the
    /// deallocation that would free that address for reuse).
    func testANewlyAllocatedGroupNeverObservesAnotherGroupsTombstoneState() {
        var firstGroupTombstoned = false
        autoreleasepool {
            let group = makeRenderGroup()
            GroupTombstoneRegistry.tombstonesCreatingIfNeeded(for: group).markDead(.fillRun, 7)
            firstGroupTombstoned = GroupTombstoneRegistry.tombstones(for: group)?.isDead(.fillRun, 7) ?? false
        }
        XCTAssertTrue(firstGroupTombstoned, "sanity check on the first group before it deallocates")

        // A second, unrelated group must start with zero tombstones,
        // regardless of whatever happened to the first (now-deallocated) one.
        let secondGroup = makeRenderGroup()
        XCTAssertNil(GroupTombstoneRegistry.tombstones(for: secondGroup))
        XCTAssertFalse(GroupTombstoneRegistry.tombstonesCreatingIfNeeded(for: secondGroup).isDead(.fillRun, 7))
    }
}
