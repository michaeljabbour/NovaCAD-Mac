import XCTest
@testable import DWGViewer

/// Tests for `ExternalOpenRequestQueue` — the fix for "opening a drawing
/// from another app shows a blank window" (`NovaCADAppDelegate
/// .application(_:open:)` had no consumer at all before this). Pure
/// main-actor logic, no view hierarchy needed to exercise the buffering
/// behavior itself.
@MainActor
final class ExternalOpenRequestQueueTests: XCTestCase {

    override func setUp() async throws {
        // The queue is a process-wide singleton; reset it so state from a
        // previous test (including its `hasDrainedOnce` latch) can't leak in.
        await MainActor.run {
            ExternalOpenRequestQueue.shared.resetForTesting()
        }
    }

    func testEnqueueBeforeAnyDrainIsBuffered() {
        let queue = ExternalOpenRequestQueue.shared
        let url = URL(fileURLWithPath: "/tmp/one.dxf")
        queue.enqueue(url)
        XCTAssertEqual(queue.drainPending(), [url])
    }

    func testDrainPendingReturnsURLsInFIFOOrder() {
        let queue = ExternalOpenRequestQueue.shared
        let a = URL(fileURLWithPath: "/tmp/a.dxf")
        let b = URL(fileURLWithPath: "/tmp/b.dxf")
        queue.enqueue(a)
        queue.enqueue(b)
        XCTAssertEqual(queue.drainPending(), [a, b])
    }

    func testDrainPendingEmptiesTheQueue() {
        let queue = ExternalOpenRequestQueue.shared
        queue.enqueue(URL(fileURLWithPath: "/tmp/one.dxf"))
        _ = queue.drainPending()
        XCTAssertEqual(queue.drainPending(), [], "a second drain must return nothing new")
    }

    func testEnqueueAfterFirstDrainIsNotRebuffered() {
        // Models the cold-launch-then-warm-launch sequence: the very first
        // drain (DocumentTabsView.onAppear) proves a real subscriber exists,
        // so anything enqueued AFTER that point relies purely on the live
        // notification, not the buffer — buffering it too would leak forever
        // since nothing will ever drain it again.
        let queue = ExternalOpenRequestQueue.shared
        _ = queue.drainPending() // no-op first drain, marks hasDrainedOnce
        queue.enqueue(URL(fileURLWithPath: "/tmp/later.dxf"))
        XCTAssertEqual(queue.drainPending(), [], "post-first-drain enqueues must not be buffered")
    }

    func testEnqueuePostsNotificationWithTheURL() {
        let url = URL(fileURLWithPath: "/tmp/notify.dxf")
        let expectation = expectation(description: "notification received")
        let observer = NotificationCenter.default.addObserver(forName: .novaCADOpenExternalURL, object: nil, queue: nil) { note in
            XCTAssertEqual(note.userInfo?[DocumentNotificationKey.url] as? URL, url)
            expectation.fulfill()
        }
        ExternalOpenRequestQueue.shared.enqueue(url)
        wait(for: [expectation], timeout: 1)
        NotificationCenter.default.removeObserver(observer)
    }
}
