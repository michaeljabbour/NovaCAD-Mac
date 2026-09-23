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
    var showUnits: () -> Void = {}
    var toggleLayers: () -> Void = {}
    var showInfo: () -> Void = {}
    var showSearch: () -> Void = {}
    var toggleAssistant: () -> Void = {}
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
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
    @AppStorage("ribbonCollapsed") private var ribbonCollapsed = false
    @FocusedValue(\.novaCADCommandDispatch) private var dispatch: CommandDispatch?

    @FocusedValue(\.novaCADFileDispatch) private var fileDispatch: FileDispatch?

    private var ready: Bool { (dispatch?.hasDocument ?? false) && !(dispatch?.isLoading ?? true) }

    var body: some Commands {
        CommandMenu("Draw") {
            menuItems(for: .draw)
            Divider()
            menuItems(for: .insert)
        }
        CommandMenu("Modify") { menuItems(for: .modify) }
        CommandMenu("Format") {
            Button("Layers Sidebar") { dispatch?.toggleLayers() }
            menuItems(for: .format)
            Button("Units & Format…") { dispatch?.showUnits() }.disabled(!ready)
        }
        CommandMenu("Dimension") { menuItems(for: .dimension) }
        CommandGroup(replacing: .newItem) { FileMenuItems(dispatch: fileDispatch) }
        CommandGroup(replacing: .saveItem) { }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                if isTextFieldFirstResponder { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                else { dispatch?.perform(.undo) }
            }.keyboardShortcut("z", modifiers: .command)
                .disabled(!isTextFieldFirstResponder && !(dispatch?.canUndo ?? false))
            Button("Redo") {
                if isTextFieldFirstResponder { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                else { dispatch?.performRedo() }
            }.keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!isTextFieldFirstResponder && !(dispatch?.canRedo ?? false))
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button(ribbonCollapsed ? "Show Ribbon" : "Hide Ribbon") { ribbonCollapsed.toggle() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Layers Sidebar") { dispatch?.toggleLayers() }
            Button("AI Assistant") { dispatch?.toggleAssistant() }.disabled(!ready)
            Divider()
            Button("Fit Drawing") { dispatch?.perform(.zoomFit) }
                .keyboardShortcut("0", modifiers: .command).disabled(!ready)
            Button("Zoom In") { dispatch?.zoomIn() }.keyboardShortcut("+", modifiers: .command).disabled(!ready)
            Button("Zoom Out") { dispatch?.zoomOut() }.keyboardShortcut("-", modifiers: .command).disabled(!ready)
            Button("Find in Drawing…") { dispatch?.showSearch() }.keyboardShortcut("f", modifiers: .command).disabled(!ready)
            Button("Drawing Info…") { dispatch?.showInfo() }.disabled(!ready)
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                .keyboardShortcut("x", modifiers: .command).disabled(!isTextFieldFirstResponder)
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
            Divider()
            Button("Select All Text") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                .keyboardShortcut("a", modifiers: .command).disabled(!isTextFieldFirstResponder)
            Button("Select Mode") { dispatch?.perform(.selectMode) }.disabled(!ready)
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

    /// CAD aliases remain in command completion and tooltips; menu titles
    /// contain labels only so native keyboard shortcuts align correctly.
    private func menuTitle(_ spec: CommandSpec) -> String { spec.desc }

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
