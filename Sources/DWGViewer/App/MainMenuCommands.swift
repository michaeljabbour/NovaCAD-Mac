import SwiftUI
import AppKit

/// Phase 5.1: the bridge that lets native macOS menu items (and, in a later
/// step, `RibbonView`) invoke the SAME tool-start funnel the command bar
/// already uses (`ContentView.performRegistryAction`), without duplicating
/// any dispatch logic. `ContentView` is the only thing that can actually
/// call `performRegistryAction` (it's a private method on that view), so it
/// publishes a plain closure wrapping it via `.focusedSceneValue` on this
/// key; `MainMenuCommands` reads it back out via `@FocusedValue`.
///
/// A closure (not `@FocusedObject` over `DocumentSession`) is used here
/// specifically because `performRegistryAction` and every `start*`/`set*`
/// function it calls are private members of `ContentView`, not
/// `DocumentSession` — most modal-tool state (`draft`, `moveState`,
/// `modifyState`, etc.) lives as `ContentView`'s own `@State`, not on the
/// session (see DocumentSession.swift's header comment on why `regen`/
/// document-scoped state lives there but per-gesture UI state doesn't).
struct CommandDispatch {
    /// Routes one `CommandAction` through `ContentView.performRegistryAction`.
    var perform: (CommandAction) -> Void
    /// `session.redo()` — separate from `perform` because Redo has no
    /// `CommandAction`/`CommandRegistry` entry of its own (there has never
    /// been a typed "REDO" command-bar token, only ⌘⇧Z/the toolbar's own
    /// Redo button calling `session.redo()` directly) — see `RibbonView`'s
    /// View group for the one caller that needs this.
    var performRedo: () -> Void
    /// Mirrors the toolbar/context-menu's own bespoke disabled-state
    /// booleans (see ContentView's toolbar `Menu` block) so menu items can
    /// gray themselves out the same way the equivalent toolbar button does,
    /// without reaching into `ContentView`'s private state directly.
    var hasDocument: Bool
    var isLoading: Bool
    var hasSelection: Bool
    var canUndo: Bool
    var canRedo: Bool
    /// Cross-drawing Copy/Paste (new feature): true when `NSPasteboard
    /// .general` currently holds a `PasteboardSnapshot` this app wrote —
    /// gates the Edit ▸ Paste / Paste at Original Coordinates menu items,
    /// same "disabled when there's nothing to act on" convention as
    /// `canUndo`/`canRedo` above. Computed fresh each time `MainMenuCommands`
    /// asks (menu validation runs right before the menu opens), not cached,
    /// so switching away to copy something in ANOTHER app/window and back
    /// is reflected immediately.
    var canPaste: () -> Bool
    /// "Paste at Original Coordinates" — separate from `perform(.clipboardPaste)`
    /// (which enters click-to-place mode) since it commits immediately
    /// with no further user interaction; see `ContentView
    /// .pasteAtOriginalCoordinates`'s own doc comment.
    var pasteAtOriginalCoordinates: () -> Void
}

private struct CommandDispatchKey: FocusedValueKey {
    typealias Value = CommandDispatch
}

extension FocusedValues {
    var novaCADCommandDispatch: CommandDispatch? {
        get { self[CommandDispatchKey.self] }
        set { self[CommandDispatchKey.self] = newValue }
    }
}

/// Native macOS menu bar commands, grouped by `MenuPath` and sourced from
/// `CommandRegistry.all` — added to the app's `Scene` via `.commands {
/// MainMenuCommands() }`. Every item routes through the focused
/// `CommandDispatch.perform` closure into `ContentView.performRegistryAction`,
/// the exact same funnel the command bar and (once added) `RibbonView` use —
/// there is no second, parallel dispatch implementation here.
///
/// When no document window has focus (or the focused window hasn't
/// published a dispatch yet — e.g. during the brief window before
/// `ContentView.body` first renders), `dispatch` is `nil` and every item
/// below is simply disabled, matching how the existing toolbar Menu already
/// disables itself via `.disabled(document == nil || isLoading)`.
struct MainMenuCommands: Commands {
    @FocusedValue(\.novaCADCommandDispatch) private var dispatch: CommandDispatch?

    @FocusedValue(\.novaCADFileDispatch) private var fileDispatch: FileDispatch?

    private var ready: Bool { (dispatch?.hasDocument ?? false) && !(dispatch?.isLoading ?? true) }

    var body: some Commands {
        CommandMenu("Draw") {
            menuItems(for: .draw)
        }
        CommandMenu("Modify") {
            menuItems(for: .modify)
        }
        CommandMenu("Insert") {
            menuItems(for: .insert)
        }
        CommandMenu("Format") {
            menuItems(for: .format)
        }
        CommandMenu("Dimension") {
            menuItems(for: .dimension)
        }
        // NOTE: no top-level "Tools" CommandMenu — `MenuPath.tools` exists in
        // the enum for future use (matching the plan's named menu list) but
        // no CommandSpec currently sets it (grep-confirmed: every command
        // that would conceptually be "Tools" — SEL, ZOOM, DISTANCE/AREA/
        // RADIUS/ANGLE — was categorized under .edit/.view/.dimension
        // instead, since those are more specific/accurate AutoCAD-menu
        // analogues). An always-empty CommandMenu would be a confusing dead
        // menu item, so it's omitted until some future command actually
        // claims `.tools`.
        // Edit/View below AUGMENT the system-provided Edit/View menus
        // (SwiftUI merges `CommandGroup(after:)` content into the existing
        // native menu of that name) rather than building brand-new top-level
        // menus — matches native macOS app conventions (every app has
        // exactly one File/Edit/View menu).
        //
        // `.file` now has real content (Phase 3.2: SAVE/SAVEAS) — this
        // CommandGroup was previously omitted entirely (an always-empty
        // `.file` group would have rendered an orphan `Divider()` with
        // nothing under it, the same "dead menu scaffolding" bug already
        // fixed above for `.tools`; see git history). No explicit
        // `.keyboardShortcut` on these items — the toolbar's own Save/Save
        // As buttons already own the real ⌘S/⇧⌘S bindings (same
        // no-duplicate-shortcut pattern as the Edit menu's Undo item below).
        CommandGroup(replacing: .newItem) { FileMenuItems(dispatch: fileDispatch) }
        CommandGroup(replacing: .saveItem) { }
        CommandGroup(replacing: .undoRedo) {
            // `replacing:`, not `after:` — this app has no `NSUndoManager`
            // wired into the responder chain (it has its own bespoke
            // `EditableDocument.undoStack`/`redoStack`), so SwiftUI's
            // automatically-injected system Undo/Redo placeholder items at
            // the `.undoRedo` anchor would sit permanently disabled; using
            // `after:` left those dead placeholders in the Edit menu right
            // next to this real, working Undo item, i.e. two "Undo"-looking
            // entries, one of them dead weight (found by adversarial
            // review). `replacing:` removes them; the two lines below
            // becomes the ONLY Undo/Redo content in the Edit menu.
            menuItems(for: .edit)
            // Redo has no `CommandSpec`/`CommandAction` of its own (see
            // `CommandDispatch.performRedo`'s doc comment — there has never
            // been a typed "REDO" command-bar token) — wired directly here
            // exactly like `RibbonView`'s own Redo button.
            Button("Redo  (⇧⌘Z)") {
                dispatch?.performRedo()
            }
            .disabled(!(dispatch?.canRedo ?? false))
        }
        CommandGroup(after: .toolbar) {
            Divider()
            menuItems(for: .view)
        }
        // Cross-drawing Copy/Paste (new feature). `replacing: .pasteboard`
        // removes SwiftUI's own always-disabled system Copy/Paste/Cut/
        // SelectAll placeholders at this anchor (present, per this
        // feature's own research phase, simply because nothing had ever
        // claimed them before) and puts the app's real Copy/Paste here
        // instead — same "replace, don't just augment, a dead placeholder
        // group" precedent as the `.undoRedo` replacement above.
        //
        // Text-field focus conflict (flagged during this feature's design):
        // when a native `TextField` (command bar, search box, AI Assistant
        // input, attribute editor) is first responder, ⌘C/⌘V should copy/
        // paste TEXT in that field, not the canvas selection. `isTextFieldFirstResponder`
        // checks the ACTUAL AppKit first responder and, when true, forwards
        // to `NSApp.sendAction(_:to:from:)`'s standard `copy(_:)`/`paste(_:)`
        // selectors — letting the focused field's own native text-editing
        // handle the shortcut exactly as if no custom menu item existed —
        // rather than running the canvas Copy/Paste logic underneath a
        // focused text field.
        CommandGroup(replacing: .pasteboard) {
            Button("Copy") {
                if isTextFieldFirstResponder {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                } else {
                    dispatch?.perform(.clipboardCopy)
                }
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(!isTextFieldFirstResponder && !(ready && (dispatch?.hasSelection ?? false)))

            Button("Paste") {
                if isTextFieldFirstResponder {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                } else {
                    dispatch?.perform(.clipboardPaste)
                }
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(!isTextFieldFirstResponder && !(ready && (dispatch?.canPaste() ?? false)))

            Button("Paste at Original Coordinates") {
                dispatch?.pasteAtOriginalCoordinates()
            }
            .disabled(isTextFieldFirstResponder || !(ready && (dispatch?.canPaste() ?? false)))
        }
    }

    /// True when the key window's current first responder is a text-editing
    /// view (`NSText`-conforming — covers `NSTextField`/`NSTextView`, which
    /// is what every SwiftUI `TextField`/`TextEditor` bridges to under the
    /// hood) — see the `CommandGroup(replacing: .pasteboard)` comment above
    /// for why this gates whether ⌘C/⌘V act on canvas selection vs. the
    /// focused field's own text.
    private var isTextFieldFirstResponder: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    @ViewBuilder
    private func menuItems(for path: MenuPath) -> some View {
        ForEach(CommandRegistry.all.filter { $0.menuPath == path }) { spec in
            Button(menuTitle(spec)) {
                dispatch?.perform(spec.action)
            }
            .disabled(!isEnabled(spec))
        }
    }

    /// "Name  (Alias)" when a short alias exists, matching the existing
    /// toolbar Menu's own "Label  (KEY)" convention (e.g. "Move  (M)") —
    /// reusing that exact display convention rather than inventing a new one.
    private func menuTitle(_ spec: CommandSpec) -> String {
        guard let shortAlias = spec.aliases.first(where: { $0.count <= 3 }) else {
            return spec.desc
        }
        return "\(spec.desc)  (\(shortAlias))"
    }

    /// Mirrors the toolbar Menu's bespoke per-button disabled-state rules
    /// (see ContentView.swift's toolbar `Menu` block) for the handful of
    /// commands that need a live document/selection, rather than reusing a
    /// single blanket rule for every command. Only MOVE (`.moveTool`) is
    /// gated on a non-empty selection in the toolbar Menu today — COPY/
    /// ROTATE/SCALE/MIRROR (`.modify`) are NOT, because `startModify`
    /// gracefully falls into its own "Select objects:" acquisition prompt
    /// (`ModifyToolState.begin`'s `.selecting` phase) when there's no
    /// preselection, unlike `startMove`, which requires PICKFIRST selection
    /// and shows "Select something to move first" otherwise. An earlier
    /// version of this function incorrectly gated `.modify` the same way as
    /// `.moveTool` — caught by re-diffing against the toolbar Menu's actual
    /// `.disabled(...)` calls, which found `.moveTool` is the ONLY command
    /// with that modifier.
    private func isEnabled(_ spec: CommandSpec) -> Bool {
        guard ready else { return false }
        switch spec.action {
        case .moveTool:
            return dispatch?.hasSelection ?? false
        case .undo:
            return dispatch?.canUndo ?? false
        default:
            return true
        }
    }
}
