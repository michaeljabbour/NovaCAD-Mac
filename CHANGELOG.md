# Changelog

This changelog tracks the `michaeljabbour/NovaCAD-Mac` fork. A version here
describes a fork build; it does not imply that an upstream installer or
Homebrew release contains these changes.

## 1.6.1 — Workspace navigation, ergonomics and assistant fixes

- Let the AI inspect exact existing geometry and stage line/polyline/arc/circle
  replacements or deletions, with a before/after preview, Apply and Undo.
  Reject stale proposals and retain the source layer, style and paper sheet.
- Add staged ungrouping of editable curves from one local block instance while
  preserving notes, fills and nested blocks in a private remainder block.
  Correct assistant instructions that described editing as attribute-only.

- Give the AI live canvas bounds, nearby labels and bounded visible-object queries
  that follow pan, zoom, sheet changes and hidden layers.
- Render Markdown in assistant replies and supply active space/sheet/unit context.
- Replace large AI geometry dumps with compact overviews and bounded, paged
  text/block queries. Support read-only searches of other named paper sheets.
- Bound tool results and recent conversation context; compact older Anthropic
  tool exchanges before sending oversized requests, preserving call/result pairs.
- Exclude empty/default-viewport-only layouts from sheet counts and Previous/Next
  navigation while retaining every layout in the drawing file.
- Remember each sheet's zoom and position independently from Model space.
- Frame search matches at 28% of the canvas, restore the prior camera on close,
  and retain the selected ribbon tab while typing.
- Anchor Units, Drawing Info, Issues and Quality to their buttons inside the
  window, above the status bar.
- Removed the floating AI panel mode and its unused implementation/tests;
  Properties and AI Assistant now use the shared docked sidebar only.
- Unify layout ownership for rendering and navigation, including renamed layouts
  with stale names, and reuse the initial navigation scan when opening a file.
- Make View → AI Assistant toggle the visible AI tab. Show an empty-paper message
  when no populated sheet is available, and scroll inspector cards in small windows.
- Combine Properties and AI Assistant in one sidebar with a remembered tab.
  Fitted drawings re-fit when the available canvas changes; manual zoom and
  pan remain unchanged. Centered views within 1% of fit are treated as fitted.
- Provide 28-point button targets for layer eye/lock/color, Clear Selection,
  sheet/search arrows, and workspace inspector/search/sidebar close controls.
  Keep layer rows stationary when selection controls appear.
- Expose a default accessibility selection action and selected state on layer
  rows. Keep Layers Sidebar in the View menu and command aliases in ribbon
  tooltips/accessibility help.
- Add regression coverage for layout filtering, search restoration, independent
  sheet cameras, inspector placement, and fitted/manual canvas resizing.
- Refresh the README, feature inventory and contributor instructions to match
  current editing, block-stamping, navigation and distribution behavior.

Drawing text, title-block totals and DWG files are not rewritten by these
workspace changes. Native DWG saving, CTB/STB plot styles, and OLE/WIPEOUT
rendering remain unsupported; see [README.md](README.md#known-limitations).
