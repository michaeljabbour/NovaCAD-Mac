import SwiftUI

/// Reusable "glass" chrome for a floating, draggable, resizable in-window
/// panel — the shell the AI Assistant uses when undocked, and the intended
/// home for any future floating tool window.
///
/// Why in-window SwiftUI rather than a real `NSPanel`: every other floating
/// element in NovaCAD (the dimension-format badge, the zoom readout, the
/// loading card) is an in-window overlay drawn over the canvas, and this app
/// is otherwise pure SwiftUI scenes with no AppKit windowing anywhere. An
/// `NSPanel` would introduce a second window-management model (ordering,
/// per-tab lifetime, full-screen behavior, restoring position across tab
/// switches) for no user-visible gain, since the panel's whole job is to sit
/// over the drawing it's talking about.
///
/// Visual language: `.ultraThinMaterial` (so the drawing stays legible THROUGH
/// the panel — the point of a floating tool over a plan view), a hairline
/// white-gradient border to catch the light on its top edge, generous corner
/// radius, and a soft wide shadow so it reads as hovering above the canvas
/// rather than cut into it. Deliberately more translucent than the docked
/// sidebar chrome (`.windowBackgroundColor` + a 1px divider), because a docked
/// panel owns its strip of layout while a floating one is borrowing space from
/// the drawing underneath.
struct FloatingPanelChrome: ViewModifier {
    /// Slightly stronger tint while dragging/resizing, so the panel visually
    /// "lifts" off the canvas during direct manipulation.
    var isInteracting: Bool = false

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                // Hairline highlight: brighter along the top edge, fading out
                // downward — the standard macOS "glass panel catching light
                // from above" cue, and what keeps the panel's silhouette
                // readable against both a near-white and near-black drawing.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.08)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(isInteracting ? 0.42 : 0.28),
                    radius: isInteracting ? 26 : 18, x: 0, y: isInteracting ? 12 : 8)
            .animation(.easeOut(duration: 0.14), value: isInteracting)
    }
}

extension View {
    /// Applies NovaCAD's floating-glass panel chrome — see
    /// `FloatingPanelChrome`.
    func floatingPanelChrome(isInteracting: Bool = false) -> some View {
        modifier(FloatingPanelChrome(isInteracting: isInteracting))
    }
}

/// A drag handle that reads as one: a short, centered, rounded "grabber" bar
/// (the same grab-handle pattern macOS/iOS sheets use), brightening on hover so it's
/// discoverable without a tooltip.
struct PanelGrabber: View {
    @State private var hovering = false

    var body: some View {
        Capsule()
            .fill(.secondary.opacity(hovering ? 0.65 : 0.35))
            .frame(width: 34, height: 4)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Bottom-trailing resize corner: three stepped diagonal ticks, matching the
/// classic macOS resize-corner idiom, with a generous invisible hit area so
/// it's grabbable without pixel-hunting.
struct PanelResizeCorner: View {
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Invisible, generously-sized hit target.
            Color.clear.frame(width: 22, height: 22).contentShape(Rectangle())
            Path { p in
                for i in 0..<3 {
                    let inset = CGFloat(i) * 4.5
                    p.move(to: CGPoint(x: 14 - inset, y: 16))
                    p.addLine(to: CGPoint(x: 16, y: 14 - inset))
                }
            }
            .stroke(.secondary.opacity(hovering ? 0.85 : 0.45), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 18, height: 18)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Position + size state for one floating panel, including the clamping rule
/// that keeps it grabbable.
///
/// Kept as a plain value type (not a view-local pile of `@State`s) so the
/// clamping/resizing math is unit-testable without a running UI — the part
/// most likely to break subtly (a panel that can be dragged somewhere it
/// can't be dragged back from is unrecoverable for the user short of
/// relaunching).
struct FloatingPanelFrame: Equatable {
    /// Top-left corner, in the coordinate space of the container the panel
    /// floats over.
    var origin: CGPoint
    var size: CGSize

    static let minSize = CGSize(width: 280, height: 260)
    /// How much of the panel must remain inside the container. Clamping the
    /// ORIGIN alone isn't enough: a panel dragged to the far right with only
    /// its origin constrained would still have its body (and every control on
    /// it) off-screen. Keeping this much of the panel visible guarantees the
    /// header — hence the drag handle and the dock/close buttons — is always
    /// reachable.
    static let minVisible: CGFloat = 120

    /// Clamps `origin` so the panel stays grabbable inside `container`, and
    /// `size` so it never collapses below `minSize` nor exceeds the container.
    /// Idempotent: clamping an already-clamped frame changes nothing.
    func clamped(in container: CGSize) -> FloatingPanelFrame {
        guard container.width > 0, container.height > 0 else { return self }
        var result = self
        result.size.width = min(max(size.width, Self.minSize.width), max(container.width, Self.minSize.width))
        result.size.height = min(max(size.height, Self.minSize.height), max(container.height, Self.minSize.height))

        // Horizontally: never push more than (width - minVisible) past the
        // left edge, nor start beyond (container - minVisible) on the right.
        let minX = -(result.size.width - min(Self.minVisible, result.size.width))
        let maxX = container.width - min(Self.minVisible, result.size.width)
        result.origin.x = min(max(origin.x, minX), max(minX, maxX))
        // Vertically the TOP edge must stay on-screen (a panel dragged above
        // the top edge would hide its own header/drag handle, making it
        // impossible to drag back), while the bottom may overhang.
        let maxY = container.height - min(Self.minVisible, result.size.height)
        result.origin.y = min(max(origin.y, 0), max(0, maxY))
        return result
    }

    /// Default placement for a newly-floated panel: parked near the trailing
    /// edge (where the panel used to be docked, so the transition reads as
    /// "the same panel came loose" rather than a new window appearing) and
    /// inset from the container's edges.
    static func defaultFrame(in container: CGSize) -> FloatingPanelFrame {
        let size = CGSize(width: 360, height: max(Self.minSize.height, min(560, container.height - 120)))
        let origin = CGPoint(x: max(16, container.width - size.width - 24), y: 24)
        return FloatingPanelFrame(origin: origin, size: size).clamped(in: container)
    }

    /// Applies a drag translation, then re-clamps.
    func dragged(by translation: CGSize, in container: CGSize) -> FloatingPanelFrame {
        FloatingPanelFrame(origin: CGPoint(x: origin.x + translation.width,
                                           y: origin.y + translation.height),
                           size: size)
            .clamped(in: container)
    }

    /// Applies a resize-corner drag (bottom-trailing: grows right/down,
    /// origin fixed), then re-clamps.
    func resized(by translation: CGSize, in container: CGSize) -> FloatingPanelFrame {
        FloatingPanelFrame(origin: origin,
                           size: CGSize(width: size.width + translation.width,
                                        height: size.height + translation.height))
            .clamped(in: container)
    }
}
