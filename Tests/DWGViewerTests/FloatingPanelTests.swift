import XCTest
@testable import DWGViewer
import CoreGraphics

/// Tests for `FloatingPanelFrame` — the position/size math behind the movable,
/// resizable floating AI Assistant panel.
///
/// This is deliberately a pure value type precisely so it can be tested
/// without a running UI: the failure mode here is a panel the user drags
/// somewhere it can't be dragged BACK from (fully off an edge, or with its
/// header — hence its drag handle and dock/close buttons — outside the visible
/// area), which is unrecoverable short of relaunching the app. Every clamp
/// below exists to make that impossible.
final class FloatingPanelTests: XCTestCase {

    private let container = CGSize(width: 1200, height: 800)

    // MARK: - Default placement

    func testDefaultFrameSitsInsideTheContainerNearTheTrailingEdge() {
        let f = FloatingPanelFrame.defaultFrame(in: container)
        XCTAssertGreaterThanOrEqual(f.origin.x, 0)
        XCTAssertGreaterThanOrEqual(f.origin.y, 0)
        XCTAssertLessThanOrEqual(f.origin.x + f.size.width, container.width,
                                 "the default placement must be fully on-screen")
        XCTAssertLessThanOrEqual(f.origin.y + f.size.height, container.height)
        XCTAssertGreaterThan(f.origin.x, container.width / 2,
                             "defaults near the trailing edge, where the panel used to be docked")
    }

    func testDefaultFrameStillUsableInAVerySmallContainer() {
        // A cramped window must not produce a panel larger than the window or
        // one with a negative origin.
        let tiny = CGSize(width: 320, height: 300)
        let f = FloatingPanelFrame.defaultFrame(in: tiny)
        XCTAssertGreaterThanOrEqual(f.origin.x, -(f.size.width - FloatingPanelFrame.minVisible))
        XCTAssertGreaterThanOrEqual(f.origin.y, 0)
        XCTAssertGreaterThanOrEqual(f.size.width, FloatingPanelFrame.minSize.width)
        XCTAssertGreaterThanOrEqual(f.size.height, FloatingPanelFrame.minSize.height)
    }

    // MARK: - Minimum size

    func testClampEnforcesMinimumSize() {
        let f = FloatingPanelFrame(origin: .zero, size: CGSize(width: 10, height: 10))
            .clamped(in: container)
        XCTAssertEqual(f.size.width, FloatingPanelFrame.minSize.width)
        XCTAssertEqual(f.size.height, FloatingPanelFrame.minSize.height)
    }

    func testClampNeverGrowsThePanelBeyondTheContainer() {
        let f = FloatingPanelFrame(origin: .zero, size: CGSize(width: 5000, height: 5000))
            .clamped(in: container)
        XCTAssertEqual(f.size.width, container.width)
        XCTAssertEqual(f.size.height, container.height)
    }

    func testMinimumSizeWinsOverAContainerSmallerThanIt() {
        // A window narrower than the panel's minimum must still leave the
        // panel usable rather than crushing it to nothing.
        let f = FloatingPanelFrame(origin: .zero, size: CGSize(width: 300, height: 300))
            .clamped(in: CGSize(width: 100, height: 100))
        XCTAssertEqual(f.size.width, FloatingPanelFrame.minSize.width)
        XCTAssertEqual(f.size.height, FloatingPanelFrame.minSize.height)
    }

    // MARK: - Drag clamping (the "can't lose the panel" guarantee)

    func testDraggingFarRightLeavesTheMinimumVisibleSliver() {
        let start = FloatingPanelFrame(origin: CGPoint(x: 800, y: 100),
                                       size: CGSize(width: 360, height: 500))
        let f = start.dragged(by: CGSize(width: 100_000, height: 0), in: container)
        XCTAssertEqual(f.origin.x, container.width - FloatingPanelFrame.minVisible, accuracy: 0.001,
                       "at least minVisible points must remain inside the right edge")
        XCTAssertLessThan(f.origin.x, container.width, "never fully off-screen")
    }

    func testDraggingFarLeftLeavesTheMinimumVisibleSliver() {
        let start = FloatingPanelFrame(origin: CGPoint(x: 100, y: 100),
                                       size: CGSize(width: 360, height: 500))
        let f = start.dragged(by: CGSize(width: -100_000, height: 0), in: container)
        XCTAssertEqual(f.origin.x, -(360 - FloatingPanelFrame.minVisible), accuracy: 0.001)
        XCTAssertGreaterThan(f.origin.x + f.size.width, 0, "a grabbable sliver stays on-screen")
    }

    func testTheTopEdgeCanNeverGoAboveTheContainer() {
        // Critical: the drag handle and every header control live at the TOP of
        // the panel. If the top edge could leave the container, the panel would
        // become permanently un-draggable.
        let start = FloatingPanelFrame(origin: CGPoint(x: 100, y: 200),
                                       size: CGSize(width: 360, height: 500))
        let f = start.dragged(by: CGSize(width: 0, height: -100_000), in: container)
        XCTAssertEqual(f.origin.y, 0, "the header must always remain reachable")
    }

    func testDraggingDownLeavesTheHeaderOnScreen() {
        let start = FloatingPanelFrame(origin: CGPoint(x: 100, y: 100),
                                       size: CGSize(width: 360, height: 500))
        let f = start.dragged(by: CGSize(width: 0, height: 100_000), in: container)
        XCTAssertEqual(f.origin.y, container.height - FloatingPanelFrame.minVisible, accuracy: 0.001)
        XCTAssertLessThan(f.origin.y, container.height)
    }

    func testDragPreservesSize() {
        let start = FloatingPanelFrame(origin: CGPoint(x: 100, y: 100),
                                       size: CGSize(width: 420, height: 480))
        let f = start.dragged(by: CGSize(width: 60, height: -30), in: container)
        XCTAssertEqual(f.size, start.size, "moving a panel must never resize it")
        XCTAssertEqual(f.origin.x, 160, accuracy: 0.001)
        XCTAssertEqual(f.origin.y, 70, accuracy: 0.001)
    }

    // MARK: - Resize

    func testResizeGrowsFromTheBottomTrailingCornerLeavingOriginFixed() {
        let start = FloatingPanelFrame(origin: CGPoint(x: 100, y: 80),
                                       size: CGSize(width: 360, height: 400))
        let f = start.resized(by: CGSize(width: 80, height: 50), in: container)
        XCTAssertEqual(f.origin, start.origin, "the bottom-trailing handle must not move the panel")
        XCTAssertEqual(f.size.width, 440, accuracy: 0.001)
        XCTAssertEqual(f.size.height, 450, accuracy: 0.001)
    }

    func testResizingSmallerStopsAtTheMinimum() {
        let start = FloatingPanelFrame(origin: CGPoint(x: 100, y: 80),
                                       size: CGSize(width: 360, height: 400))
        let f = start.resized(by: CGSize(width: -100_000, height: -100_000), in: container)
        XCTAssertEqual(f.size.width, FloatingPanelFrame.minSize.width)
        XCTAssertEqual(f.size.height, FloatingPanelFrame.minSize.height)
        XCTAssertEqual(f.origin, start.origin)
    }

    func testResizingLargerStopsAtTheContainer() {
        let start = FloatingPanelFrame(origin: .zero, size: CGSize(width: 360, height: 400))
        let f = start.resized(by: CGSize(width: 100_000, height: 100_000), in: container)
        XCTAssertEqual(f.size.width, container.width)
        XCTAssertEqual(f.size.height, container.height)
    }

    // MARK: - Idempotency + window-resize recovery

    func testClampIsIdempotent() {
        // Re-clamping must be a no-op, or a panel parked at an edge would
        // creep every time the view re-clamps (e.g. on each window resize).
        let once = FloatingPanelFrame(origin: CGPoint(x: 5000, y: 5000),
                                      size: CGSize(width: 360, height: 400))
            .clamped(in: container)
        let twice = once.clamped(in: container)
        XCTAssertEqual(once, twice)
    }

    func testShrinkingTheWindowPullsAnEdgeParkedPanelBackIntoView() {
        // The window-resize recovery path: a panel parked at the right edge of
        // a wide window must not be orphaned outside a suddenly-narrow one.
        let parked = FloatingPanelFrame(origin: CGPoint(x: 840, y: 40),
                                        size: CGSize(width: 360, height: 500))
            .clamped(in: container)
        let narrow = CGSize(width: 500, height: 400)
        let recovered = parked.clamped(in: narrow)
        XCTAssertLessThanOrEqual(recovered.origin.x, narrow.width - FloatingPanelFrame.minVisible)
        XCTAssertLessThanOrEqual(recovered.origin.y, narrow.height - FloatingPanelFrame.minVisible)
        XCTAssertLessThanOrEqual(recovered.size.height, narrow.height)
    }

    func testZeroSizedContainerIsTreatedAsUnknownAndLeavesTheFrameAlone() {
        // SwiftUI reports a zero size for a frame before first layout;
        // clamping against it would slam the panel to the origin and destroy
        // the user's chosen position on every appearance.
        let start = FloatingPanelFrame(origin: CGPoint(x: 300, y: 200),
                                       size: CGSize(width: 360, height: 400))
        XCTAssertEqual(start.clamped(in: .zero), start)
        XCTAssertEqual(start.clamped(in: CGSize(width: 0, height: 800)), start)
    }

    // MARK: - Sequential gestures (anchor-based accumulation)

    func testRepeatedDragsAccumulateWithoutDriftAtAnEdge() {
        // Mirrors how the gesture applies each tick's translation to the
        // anchor: once pinned at an edge, further drags in the same direction
        // must not build up hidden offset that the user then has to "unwind."
        var f = FloatingPanelFrame(origin: CGPoint(x: 100, y: 100),
                                   size: CGSize(width: 360, height: 400))
        for _ in 0..<5 { f = f.dragged(by: CGSize(width: 500, height: 0), in: container) }
        let pinned = f
        f = f.dragged(by: CGSize(width: -40, height: 0), in: container)
        XCTAssertEqual(f.origin.x, pinned.origin.x - 40, accuracy: 0.001,
                       "dragging back off an edge must respond immediately")
    }
}
