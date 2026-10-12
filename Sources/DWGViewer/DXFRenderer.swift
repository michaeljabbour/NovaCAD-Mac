import Foundation
import CADCore
import CoreGraphics

/// Parameters describing one frame to rasterize.
struct RenderParams: Equatable {
    /// World → view transform, in view points, y-down with top-left origin
    /// (matches the flipped NSView the result is blitted into).
    var worldToView = CGAffineTransform.identity
    var viewSize = CGSize.zero          // points
    var backingScale: CGFloat = 2
    var zoom: CGFloat = 1               // points per drawing unit
    var darkBackground = true
    var visibility = VisibilityState()
    var usePaperSpace = false
    var selection: Set<EntityRef> = []
    /// Rendering quality 1...5: 1 = fastest (coarse decimation, no AA),
    /// 5 = superb (near-lossless detail). See RenderQuality.
    var quality = 3
    var vectorOutput = false
    /// `RegenCoordinator.revision` at the time these params were built
    /// (Phase 1.7 live cutover; 0 for the old render-only path, which never
    /// mutates its `DXFDocument` after load). `DXFCanvasView.Coordinator`
    /// gates re-rendering on `params != lastRequested || documentID changed`
    /// — but an incremental edit (`RegenCoordinator.apply`'s `appendGroup`)
    /// mutates the SAME `DXFDocument` object IN PLACE, so neither half of
    /// that check would otherwise notice a just-drawn line needs a redraw
    /// until some unrelated param (zoom, selection, ...) also happened to
    /// change. Including the revision here makes any commit bust the
    /// `Equatable` comparison on its own.
    var documentRevision: UInt64 = 0

    /// A monotonic token bumped whenever something that affects the RENDER but
    /// might not otherwise change a compared field must force a fresh frame —
    /// chiefly a visibility toggle. `VisibilityState` IS compared here, so a
    /// toggle already busts `Equatable`; this is belt-and-suspenders so the
    /// canvas re-renders even if a future refactor made two visibility states
    /// compare equal by accident, and it gives the UI an explicit "please
    /// redraw now" lever. See `DXFCanvasView.Coordinator.requestIfNeeded`.
    var renderNonce: UInt64 = 0
}

/// Level-of-detail knobs for the 1–5 quality preference. Lower levels decimate
/// more aggressively and skip antialiasing for maximum pan/zoom responsiveness;
/// level 5 renders nearly every vertex for maximum crispness.
struct RenderQuality {
    let decimationTol: CGFloat   // screen-point spacing below which points drop
    let tickCell: CGFloat        // occupancy-grid cell for sub-pixel entities
    let antialias: Bool
    let minTextPt: CGFloat       // smallest cap height (points) worth drawing

    init(level: Int) {
        switch max(1, min(5, level)) {
        case 1:  self = .init(2.4, 4.5, false, 6.0)
        case 2:  self = .init(1.4, 3.0, true, 4.5)
        case 4:  self = .init(0.35, 1.0, true, 2.4)
        case 5:  self = .init(0.10, 0.45, true, 1.6)
        default: self = .init(0.75, 2.0, true, 3.5)   // 3 — balanced
        }
    }

    private init(_ tol: CGFloat, _ cell: CGFloat, _ aa: Bool, _ minText: CGFloat) {
        decimationTol = tol
        tickCell = cell
        antialias = aa
        minTextPt = minText
    }
}

final class RenderedFrame {
    let image: CGImage
    let worldToView: CGAffineTransform
    let viewSize: CGSize
    init(image: CGImage, worldToView: CGAffineTransform, viewSize: CGSize) {
        self.image = image
        self.worldToView = worldToView
        self.viewSize = viewSize
    }
}

/// Rasterizes the drawing on a background queue. Requests coalesce: while a
/// frame is being rendered, only the most recent pending request is kept, and
/// an in-flight render aborts between groups when a newer request arrives.
///
/// The actual CoreGraphics drawing lives in `CGRenderCore` (CGRenderCore.swift)
/// — this class owns only the bitmap allocation and the coalescing queue.
final class BitmapRenderer {

    // Concurrent (not serial) so a watchdog-relaunched worker can actually run
    // even if a previous render genuinely hung — a serial queue would serialize
    // the new worker behind the stuck one and never recover. `drainToken`
    // ensures only the newest worker delivers frames and owns `busy`.
    private let queue = DispatchQueue(label: "dxf.render", qos: .userInteractive,
                                      attributes: .concurrent)
    private let lock = NSLock()
    private var pending: (DXFDocument, RenderParams)?
    private var busy = false
    private var generation = 0
    /// Monotonic id of the drain worker currently believed to be running.
    /// Used by the watchdog to relaunch a NEW worker if the active one stalled
    /// (a hung/crashed CoreGraphics render on a huge drawing must never freeze
    /// the canvas forever — see `request`).
    private var drainToken = 0
    /// Wall-clock when the active drain last made progress (started a render).
    /// Stale + still-`busy` => the worker is stuck; relaunch.
    private var drainHeartbeat = Date.distantPast

    /// If a drain hasn't made progress in this long while more work is pending,
    /// assume it stalled and start a fresh worker.
    private static let stallTimeout: TimeInterval = 12

    /// Called on the main queue with each finished frame.
    var onFrame: ((RenderedFrame) -> Void)?

    func request(document: DXFDocument, params: RenderParams) {
        lock.lock()
        pending = (document, params)
        generation += 1
        let gen = generation

        // Decide whether to (re)start a worker. Start one if none is running,
        // OR if the running one appears stalled (self-healing): a stuck render
        // must not latch `busy` and freeze all future pan/zoom/toggle updates.
        let stalled = busy && Date().timeIntervalSince(drainHeartbeat) > Self.stallTimeout
        let shouldStart = !busy || stalled
        if shouldStart {
            busy = true
            drainToken += 1
            drainHeartbeat = Date()
        }
        let token = drainToken
        lock.unlock()

        if shouldStart {
            queue.async { [weak self] in self?.drain(startGen: gen, token: token) }
        }
    }

    private func drain(startGen: Int, token: Int) {
        // Guarantee `busy` is released when THIS worker is the current one and
        // exits for any reason — so the queue can never latch permanently.
        defer {
            lock.lock()
            if drainToken == token { busy = false }
            lock.unlock()
        }

        while true {
            lock.lock()
            // A newer worker superseded us (watchdog relaunch) — stand down and
            // let it own `busy`.
            guard drainToken == token else { lock.unlock(); return }
            guard let job = pending else {
                busy = false
                lock.unlock()
                return
            }
            pending = nil
            let gen = generation
            drainHeartbeat = Date()   // progress marker for the watchdog
            lock.unlock()

            let isStale: () -> Bool = { [weak self] in
                guard let self else { return true }
                self.lock.lock()
                // Stale if a newer request arrived OR a newer worker took over.
                let stale = self.generation != gen || self.drainToken != token
                self.lock.unlock()
                return stale
            }

            if let frame = Self.render(document: job.0, params: job.1, isStale: isStale) {
                // Only deliver if we're still the current worker AND no newer
                // request arrived while rendering — prevents a superseded/slow
                // worker from blitting a stale frame over a fresher one.
                lock.lock()
                let deliver = drainToken == token && generation == gen
                lock.unlock()
                if deliver {
                    let cb = onFrame
                    DispatchQueue.main.async { cb?(frame) }
                }
            }
        }
    }

    // MARK: - Rasterization

    static func render(document: DXFDocument, params p: RenderParams,
                       isStale: () -> Bool = { false }) -> RenderedFrame? {
        let wPx = max(2, Int(p.viewSize.width * p.backingScale))
        let hPx = max(2, Int(p.viewSize.height * p.backingScale))
        guard let ctx = CGContext(data: nil, width: wPx, height: hPx,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }

        guard CGRenderCore.draw(into: ctx, document: document, params: p, isStale: isStale)
        else { return nil }

        guard let image = ctx.makeImage() else { return nil }
        return RenderedFrame(image: image, worldToView: p.worldToView, viewSize: p.viewSize)
    }
}
