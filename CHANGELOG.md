# Changelog

This changelog tracks the `michaeljabbour/NovaCAD-Mac` fork. A version here
describes a fork build; it does not imply that an upstream installer or
Homebrew release contains these changes.

## 1.6.1 — Workspace navigation and ergonomics

- Exclude empty/default-viewport-only layouts from sheet counts and Previous/Next
  navigation while retaining every layout in the drawing file.
- Remember each sheet's zoom and position independently from Model space.
- Frame search matches at 28% of the canvas, restore the prior camera on close,
  and retain the selected ribbon tab while typing.
- Anchor Units, Drawing Info, Issues and Quality to their buttons inside the
  window, above the status bar.
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
