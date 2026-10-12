import SwiftUI
import CADCore

/// The AI Assistant's chat panel, in either of two presentations:
///
/// - **`.floating`** (the default): a movable, resizable glass panel hovering
///   over the drawing — see `FloatingAIAssistantPanel`, which wraps this view
///   in `FloatingPanelChrome` and owns the drag/resize gestures. Translucent
///   (`.ultraThinMaterial`) so the plan view stays readable underneath, since
///   a floating assistant is borrowing space from the drawing it's discussing.
/// - **`.docked`**: the original third trailing panel alongside
///   `PropertiesPanel`/`MarkupPropertiesPanel` (see `ContentView.body`'s
///   `HStack`), with the same fixed-width, left-divider-overlay styling as
///   those panels for visual consistency.
///
/// The user moves between them with the header's dock/float button, so this
/// view stays presentation-agnostic apart from the chrome each mode applies
/// and which of the two swap buttons the header offers.
///
/// Shows: a scrolling transcript (user turns, assistant replies, and a live
/// tool-call timeline row per tool the assistant invokes), a text input, and
/// — whenever the assistant has staged a bulk-edit plan via
/// `propose_attribute_edits` — a review card listing every proposed
/// "tag: old → new" change with Apply/Discard actions (per this feature's
/// product decision: the assistant NEVER applies anything itself).
struct AIAssistantPanel: View {
    /// Which presentation this instance is being shown in — drives the
    /// background/chrome and which swap button the header offers.
    enum Presentation { case docked, floating }

    @ObservedObject var aiSession: AIAssistantSession
    let regen: RegenCoordinator?
    let visibility: VisibilityState
    /// Reads the user's live canvas selection for `get_selected_objects` and
    /// the travel tools' `useSelectionAsOrigin`. Supplied by `ContentView`
    /// (which captures its `DocumentSession` weakly) and installed onto the
    /// session in `.onAppear`, so it survives the session being recreated on
    /// document reload.
    var selectionProvider: (() -> Set<EntityID>)? = nil
    let onApplyEdits: ([AIProposedEdit]) -> Bool
    /// Applies every staged geometry-creation action (aisle repair/route/
    /// shading, dock aprons) — sibling to `onApplyEdits` for the
    /// `AIProposedGeometry` catalog. See that type's own doc comment.
    let onApplyGeometry: ([AIProposedGeometry]) -> Bool
    let onClose: () -> Void
    var presentation: Presentation = .docked
    var embedded = false
    /// Switches presentation: "Float" when docked, "Dock" when floating.
    var onTogglePresentation: (() -> Void)? = nil

    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(isFloating ? 0.5 : 1)
            if !aiSession.stagedEdits.isEmpty {
                stagedEditsCard
                Divider().opacity(isFloating ? 0.5 : 1)
            }
            if !aiSession.stagedGeometry.isEmpty {
                stagedGeometryCard
                Divider().opacity(isFloating ? 0.5 : 1)
            }
            transcript
            if let error = aiSession.errorMessage {
                Divider().opacity(isFloating ? 0.5 : 1)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .textSelection(.enabled)
                    .padding(8)
            }
            Divider().opacity(isFloating ? 0.5 : 1)
            inputBar
        }
        // Floating mode is sized by its container (the draggable frame), so it
        // fills whatever the user resized it to; docked mode keeps the
        // fixed-width sidebar contract its siblings use.
        .frame(width: isFloating ? nil : 300)
        .background {
            // The floating case's own translucent material is applied by
            // `FloatingPanelChrome` on the WRAPPER (so it clips to the same
            // rounded shape as the border/shadow) — painting an opaque
            // background here would sit on top of it and defeat the glass.
            if !isFloating { Color(nsColor: .windowBackgroundColor) }
        }
        .overlay {
            if !isFloating {
                HStack {
                    Rectangle().frame(width: 1).foregroundColor(.black.opacity(0.2))
                    Spacer()
                }
            }
        }
        // OpenCode (agentic) backend only: eagerly starts the managed
        // `opencode serve` subprocess as soon as this panel appears, so its
        // ~30-45s startup cost is paid in the background rather than on the
        // user's first message — ported from the earlier project's assistant
        // store's `warmUpServer` `.onAppear` wiring (see that method's doc
        // comment). A no-op for every other provider.
        .onAppear {
            if let selectionProvider { aiSession.selectionProvider = selectionProvider }
            aiSession.warmUpServer()
        }
    }

    private var isFloating: Bool { presentation == .floating }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .font(.system(size: 12, weight: .semibold))
            Text("AI Assistant")
                .font(.headline)
            Spacer(minLength: 4)
            healthPill
            if aiSession.isThinking {
                Button {
                    aiSession.cancel()
                } label: { Image(systemName: "stop.circle") }
                    .buttonStyle(.plain)
                    .help("Stop")
            }
            // Reset stays available at ALL times (not just while stalled):
            // a wedged backend often manifests AFTER a turn has nominally
            // ended — the next message simply never gets a response — so
            // gating recovery behind "currently thinking" would hide it at
            // exactly the moment it's needed. It is visually promoted when
            // the session itself judges recovery likely.
            Button {
                aiSession.resetAssistant()
            } label: {
                Image(systemName: "arrow.clockwise.circle\(aiSession.recoverySuggested ? ".fill" : "")")
            }
            .buttonStyle(.plain)
            .foregroundColor(aiSession.recoverySuggested ? .orange : .secondary)
            .help("Reset Assistant — restarts the AI backend but KEEPS this conversation")
            Button {
                aiSession.clearConversation()
            } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .disabled(aiSession.history.isEmpty)
                .help("Clear Conversation")
            if let onTogglePresentation {
                Button(action: onTogglePresentation) {
                    // Floating -> "return to dock"; docked -> "return to
                    // floating". Distinct glyphs so the action is readable at
                    // a glance rather than a single ambiguous toggle icon.
                    Image(systemName: isFloating
                          ? "arrow.down.right.and.arrow.up.left.rectangle"
                          : "macwindow.on.rectangle")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(isFloating ? "Dock to Side" : "Float Window")
            }
            if !embedded { Button {
                onClose()
            } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Close AI Assistant") }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isFloating ? 6 : 10)
    }

    /// Live turn-state indicator. Replaces the bare indefinite `ProgressView`
    /// that previously looked IDENTICAL for a healthy 40-second tool call and
    /// a permanently wedged turn — the specific reason a stall was hard to
    /// recognize. Shows elapsed time while working, and turns into an amber
    /// "Stalled" badge (with the silence duration) once the session's health
    /// clock stops seeing events.
    @ViewBuilder
    private var healthPill: some View {
        switch aiSession.health {
        case .idle:
            EmptyView()
        case .working(let elapsed):
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Thinking \(Int(elapsed))s")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        case .stalled(let silent):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundColor(.orange)
                Text("Stalled \(Int(silent))s")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .monospacedDigit()
            }
            .help("No activity from the assistant for \(Int(silent))s. Press the reset button to restart the backend without losing this conversation.")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.red)
                .help("The last turn failed. Reset the assistant to recover without losing this conversation.")
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if aiSession.history.isEmpty {
                        Text("Ask about the drawing, e.g. \u{201c}What layers are on this drawing?\u{201d} "
                             + "or \u{201c}Rename the workstation labeled STN-4 to match its label text.\u{201d}")
                            .font(.callout)
                            .foregroundColor(.primary)
                            .padding(10)
                    }
                    ForEach(aiSession.history) { entry in
                        entryRow(entry).id(entry.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: aiSession.history.count) { _, _ in
                if let last = aiSession.history.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: AIChatEntry) -> some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 30)
                Text(entry.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.accentColor.opacity(0.18))
                    .cornerRadius(8)
            }
            .padding(.horizontal, 10)
        case .assistant:
            HStack {
                Text(entry.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(8)
                    // Floating over a drawing, an opaque bubble fill would
                    // punch a hole through the glass; a thin material keeps
                    // the panel airy while still separating the reply from
                    // the canvas showing through behind it.
                    .background {
                        if isFloating {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.thinMaterial)
                        } else {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                        }
                    }
                Spacer(minLength: 30)
            }
            .padding(.horizontal, 10)
        case .toolCall:
            if let call = entry.toolCall {
                toolCallRow(call)
                    .padding(.horizontal, 10)
            } else if !entry.text.isEmpty {
                // A `.toolCall`-role row with no payload is a plain status
                // note (a permission request, or the "Assistant reset" marker
                // `resetAssistant` inserts). These used to render as nothing
                // at all, which silently swallowed them — notably making a
                // reset look like it had done nothing.
                noticeRow(entry.text)
                    .padding(.horizontal, 10)
            }
        case .system:
            EmptyView()
        }
    }

    /// A centered, quiet transcript separator for session-level notices
    /// (reset markers, permission prompts) — visually distinct from both a
    /// chat bubble and a tool-call row, since it is neither.
    private func noticeRow(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 0)
            Text(text)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Capsule().fill(Color.secondary.opacity(0.10)))
            Spacer(minLength: 0)
        }
    }

    private func toolCallRow(_ call: AIToolCallEvent) -> some View {
        HStack(spacing: 6) {
            Group {
                switch call.status {
                case .pending, .running: ProgressView().controlSize(.mini)
                case .completed: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                case .awaitingPermission: Image(systemName: "hand.raised.fill").foregroundColor(.orange)
                }
            }
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(call.name)(\(call.argumentSummary))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                if let result = call.resultSummary, call.status != .running {
                    Text(result)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }

    /// Beyond this many staged edits, the card switches from "one row per
    /// object" to grouped-by-tag summaries — a bulk request ("add ROUTE=R-7
    /// to every object on layer Z") against a real plant layout can easily
    /// stage hundreds of edits (the reported real-world case: a 739-row Data
    /// Import), and a scrolling wall of individually identical rows would be
    /// unreadable and unreviewable, defeating the whole point of a review
    /// card. Small edits (the common single-object "rename this workstation"
    /// case) keep today's per-row detail unchanged.
    private static let stagedEditRowLimit = 12

    private var stagedEditsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Proposed changes").font(.subheadline).bold()
            if aiSession.stagedEdits.count > Self.stagedEditRowLimit {
                bulkEditSummaryRows
            } else {
                ForEach(aiSession.stagedEdits) { edit in
                    HStack {
                        Text(edit.attributeTag).font(.caption).foregroundColor(.secondary).frame(width: 70, alignment: .leading)
                        if edit.willCreate {
                            Text("(new attribute)").font(.caption).italic().foregroundColor(.secondary)
                        } else {
                            Text(edit.oldValue ?? "(none)").font(.caption).strikethrough().foregroundColor(.secondary)
                        }
                        Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary)
                        Text(edit.newValue).font(.caption).bold()
                    }
                }
            }
            HStack {
                Button("Discard") { aiSession.clearStagedEdits() }
                Spacer()
                Button("Apply \(aiSession.stagedEdits.count == 1 ? "Change" : "\(aiSession.stagedEdits.count) Changes")") {
                    if onApplyEdits(aiSession.stagedEdits) { aiSession.clearStagedEdits() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
    }

    /// One summary line per DISTINCT (tag, newValue) pair — the shape a bulk
    /// "set TAG=VALUE on every object on layer Z" request always produces —
    /// with counts of how many objects get a brand-new attribute vs. an
    /// updated existing one. Falls back to a plain per-edit count for a mixed
    /// batch that doesn't collapse into a handful of distinct pairs (e.g.
    /// several unrelated single-object renames that happened to both be
    /// large enough to cross `stagedEditRowLimit`), so the summary never
    /// silently hides a genuinely heterogeneous plan behind a misleadingly
    /// tidy count.
    @ViewBuilder
    private var bulkEditSummaryRows: some View {
        let groups = Dictionary(grouping: aiSession.stagedEdits) { "\($0.attributeTag)=\($0.newValue)" }
        if groups.count <= 6 {
            ForEach(groups.keys.sorted(), id: \.self) { key in
                let edits = groups[key] ?? []
                let created = edits.filter(\.willCreate).count
                let updated = edits.count - created
                HStack(alignment: .top) {
                    Image(systemName: "square.stack.3d.up.fill").foregroundColor(.accentColor).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(key).font(.caption).bold()
                        Text("\(edits.count) object(s)"
                             + (created > 0 && updated > 0 ? " — \(created) new, \(updated) updated" : ""))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        } else {
            Text("\(aiSession.stagedEdits.count) attribute changes across "
                 + "\(Set(aiSession.stagedEdits.map(\.attributeTag)).count) tag(s).")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    /// Review card for staged `AIProposedGeometry` actions (aisle repair/
    /// route/shading, dock aprons) — sibling to `stagedEditsCard`, same
    /// "Discard"/"Apply" shape but showing each action's one-line summary
    /// and target layer instead of a per-attribute old→new row, since a
    /// geometry action's payload (lines/polygons) isn't meaningfully
    /// previewable as compact text.
    private var stagedGeometryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Proposed drawing changes").font(.subheadline).bold()
            ForEach(aiSession.stagedGeometry) { action in
                HStack(alignment: .top) {
                    Image(systemName: iconName(for: action.kind))
                        .foregroundColor(.accentColor)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(action.summary).font(.caption)
                        Text("Layer: \(action.targetLayerName)")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            HStack {
                Button("Discard") { aiSession.clearStagedGeometry() }
                Spacer()
                Button("Apply \(aiSession.stagedGeometry.count == 1 ? "Change" : "Changes")") {
                    if onApplyGeometry(aiSession.stagedGeometry) { aiSession.clearStagedGeometry() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
    }

    private func iconName(for kind: AIProposedGeometry.Kind) -> String {
        switch kind {
        case .aisleRepair: return "point.topleft.down.curvedto.point.bottomright.up"
        case .route: return "arrow.triangle.turn.up.right.diamond"
        case .aisleShading: return "square.grid.3x3.fill"
        case .dockAprons: return "shippingbox.fill"
        }
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            TextField("Ask the AI Assistant\u{2026}", text: $aiSession.pendingInput, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { send() }
                .padding(.horizontal, isFloating ? 8 : 0)
                .padding(.vertical, isFloating ? 5 : 0)
                .background {
                    // A subtly inset capsule gives the floating panel's input
                    // a defined edge against the translucent body behind it;
                    // docked mode keeps the plain flush field its sibling
                    // panels use.
                    if isFloating {
                        Capsule(style: .continuous)
                            .fill(.quaternary.opacity(0.5))
                            .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 0.8))
                    }
                }
            Button {
                send()
            } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 16)) }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .disabled(!canSend)
        }
        .padding(8)
    }

    private var canSend: Bool {
        !aiSession.pendingInput.trimmingCharacters(in: .whitespaces).isEmpty && !aiSession.isThinking
    }

    private func send() {
        guard let regen else { return }
        aiSession.send(regen: regen, visibility: visibility)
    }
}

// MARK: - Floating presentation

/// `AIAssistantPanel` in its floating form: glass chrome, a grabber-bar drag
/// handle above the header, a bottom-trailing resize corner, and clamping that
/// keeps the panel reachable no matter where it's dragged.
///
/// Owns only PRESENTATION state (`frame`, plus which gesture is active); the
/// conversation itself stays on `AIAssistantSession`, so floating, docking, and
/// re-floating never disturb the transcript. The `frame` binding lives on
/// `ContentView` rather than here so a dock -> float round trip returns the
/// panel to where the user last put it instead of snapping back to the default
/// position.
struct FloatingAIAssistantPanel: View {
    @ObservedObject var aiSession: AIAssistantSession
    let regen: RegenCoordinator?
    let visibility: VisibilityState
    /// Reads the user's live canvas selection for `get_selected_objects` and
    /// the travel tools' `useSelectionAsOrigin`. Supplied by `ContentView`
    /// (which captures its `DocumentSession` weakly) and installed onto the
    /// session in `.onAppear`, so it survives the session being recreated on
    /// document reload.
    var selectionProvider: (() -> Set<EntityID>)? = nil
    let onApplyEdits: ([AIProposedEdit]) -> Bool
    let onApplyGeometry: ([AIProposedGeometry]) -> Bool
    let onClose: () -> Void
    let onDock: () -> Void
    /// Size of the area the panel floats over — drag/resize clamping is
    /// relative to this, and it re-clamps when the window resizes so a panel
    /// parked at the right edge can't be orphaned outside a shrunken window.
    let containerSize: CGSize
    @Binding var frame: FloatingPanelFrame

    /// Frame at the moment the current drag/resize began. Gestures apply their
    /// running `translation` to THIS rather than accumulating onto `frame`
    /// each tick, which would compound rounding and (worse) fight the clamp:
    /// once clamped at an edge, further accumulation would keep piling up
    /// invisible offset that the user then has to "unwind" before the panel
    /// moves back.
    @State private var dragAnchor: FloatingPanelFrame?
    @State private var resizeAnchor: FloatingPanelFrame?

    private var isInteracting: Bool { dragAnchor != nil || resizeAnchor != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle strip. The whole strip is the hit target (not just
            // the visible grabber) so it's forgiving to grab.
            PanelGrabber()
                .frame(maxWidth: .infinity)
                .padding(.top, 7)
                .padding(.bottom, 3)
                .contentShape(Rectangle())
                .gesture(dragGesture)

            AIAssistantPanel(
                aiSession: aiSession,
                regen: regen,
                visibility: visibility,
                selectionProvider: selectionProvider,
                onApplyEdits: onApplyEdits,
                onApplyGeometry: onApplyGeometry,
                onClose: onClose,
                presentation: .floating,
                onTogglePresentation: onDock
            )
        }
        .frame(width: frame.size.width, height: frame.size.height)
        .floatingPanelChrome(isInteracting: isInteracting)
        .overlay(alignment: .bottomTrailing) {
            PanelResizeCorner()
                .padding(3)
                .gesture(resizeGesture)
        }
        // Absolute placement inside the container. `.position` is centre-based,
        // so the origin-based `frame` is converted here; keeping `frame` in
        // ORIGIN terms (rather than centre) is what makes the clamping math in
        // `FloatingPanelFrame` readable and testable.
        .position(x: frame.origin.x + frame.size.width / 2,
                  y: frame.origin.y + frame.size.height / 2)
        .onChange(of: containerSize) { _, newSize in
            frame = frame.clamped(in: newSize)
        }
        // A floating panel must sit above the canvas overlays (zoom badge,
        // dimension-format badge) it may overlap.
        .zIndex(10)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.97, anchor: .topTrailing).combined(with: .opacity),
            removal: .opacity))
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let anchor = dragAnchor ?? frame
                if dragAnchor == nil { dragAnchor = anchor }
                frame = anchor.dragged(by: value.translation, in: containerSize)
            }
            .onEnded { _ in dragAnchor = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let anchor = resizeAnchor ?? frame
                if resizeAnchor == nil { resizeAnchor = anchor }
                frame = anchor.resized(by: value.translation, in: containerSize)
            }
            .onEnded { _ in resizeAnchor = nil }
    }
}
