# NovaCAD

A high-performance native macOS viewer for DWG/DXF drawings, built as an
AutoCAD-comparable tool for plant layouts. Formerly "DWG Viewer for Mac".

## Features
- **Deep search (⌘F)**: Spotlight-style search over every text string, label,
  attribute, and block name in the drawing — including resolved xref content.
  Results update as you type; press ⏎ (or the arrows) to step through the N
  matches — the canvas animates a pan/zoom to center each hit, selects it, and
  flashes a halo for 1.5 s.
- **Measurement tools**: Distance mode (click two points → distance, ΔX/ΔY,
  angle) and Area mode (click boundary points, double-click or ⏎ to close →
  area + perimeter), with live rubber-band preview and readouts in the
  drawing's units ($INSUNITS).
- **Drawing tools & markup**: Line, Polyline, Circle, 3-point Arc, Rectangle,
  regular Polygon, and Text notes drawn on a `NOVACAD-MARKUP` layer over the
  drawing, with **OSNAP** (endpoint / midpoint / center / intersection /
  perpendicular / tangent markers) and precise typed input. Pick a **markup
  color** (red, green, blue, …) from the toolbar — draw current and proposed
  flows in different colors; the color is saved across launches and travels
  with the exported/merged DXF.
- **Edit markup**: in Select mode, click markup to select it (Shift extends),
  use the Move tool (`M`) to relocate it (pick a base point, pick a
  destination — both OSNAP-snappable, with a live ghost preview), Delete to
  remove, and change its color/layer in an editable Markup panel. ⌘Z/U undoes
  the last edit (of any kind — drawing, move, erase, stamp); ⇧⌘Z redoes.
- **Window/Crossing/Lasso/Fence selection**: drag left-to-right for a Window
  select (blue, solid outline — selects only objects FULLY enclosed);
  right-to-left for Crossing (green, dashed — selects anything the box
  touches); direction is resolved live as you drag. Hold ⌥ while dragging for
  a freehand Lasso (same Window/Crossing rule, by overall drag direction).
  Shift adds to the existing selection.
- **Copy / Rotate / Scale / Mirror** (`CO`/`RO`/`SC`/`MI`, or the toolbar/
  right-click menu): select objects first (or invoke the command with nothing
  selected to get an interactive "Select objects:" prompt — type `W`/`C` for
  an explicit window/crossing rect, `F` for a fence, `ALL`, `P` for the
  previous selection, `L` for the last-created objects, `R`/`A` to toggle
  remove/add mode, `U` to undo the last pick), then pick a base point and the
  command-specific second point (or type an angle/factor directly) — all
  OSNAP-snappable, with a live ghost preview. Copy loops for multiple
  placements until ⏎/Esc. Undo/redo covers all four like any other edit.
- **Stamp blocks**: pick an existing block symbol (Tools ▸ Stamp Block) and
  click to place copies of it as markup — a live ghost previews placement and
  OSNAP applies.
- Erase tool + undo. Save via the tools menu:
  - **Export Markup as DXF…** — a standalone DXF you can attach as an xref
    over the master drawing in AutoCAD (ideal for proposing changes).
  - **Save Copy with Markup…** — a byte-faithful copy of the original DXF
    with the markup entities merged in (original content untouched).
- **Command palette**: AutoCAD-style command line at the bottom — `L`, `PL`,
  `C`, `A`, `REC`, `POL`, `T`, `E`, `DI`, `AREA`, `Z`, `U`, plus coordinate
  input while a tool is active: `100,50` (absolute), `@25,0` (relative), `75`
  (length along the cursor direction), `C` to close a polyline, and a bare
  number to set the polygon side count.
- **Reload** (Xref panel): re-open the drawing and its xrefs from disk to pick
  up edits, preserving your view, markup, and layer state.
- AutoCAD-comparable rendering: per-entity/per-layer colors (full ACI palette +
  true color), dark or light canvas, linetypes (dashed/center/hidden), hatches,
  solids, dimensions, and text (TEXT/MTEXT/ATTRIB with alignment and rotation)
- **Layer panel**: show/hide (freeze/thaw) any layer, **lock/unlock** (locked
  layers stay visible but can't be selected or snapped), color swatches, entity
  counts, search, All On / All Off, double-click a layer to isolate it
- **Xref panel**: lists external references and lets you show/hide each one
  (works for xrefs whose geometry is embedded in the DXF; unresolved xrefs are
  flagged)
- **Selection & properties**: click objects to select them (clicking part of a
  block insert selects the whole block reference, like AutoCAD). A Properties
  panel on the right shows type, layer, color, linetype, and geometry details
  (length, area, radius, text contents, block name/scale/rotation, …); it can
  be minimized to an edge tab. Clicks accumulate the selection (AutoCAD
  PICKADD); Shift+click removes; Esc or clicking empty space deselects all.
  Multi-selection shows "Various/Multiple" for properties that differ.
- AutoCAD semantics: block entities on layer 0 inherit the insert's layer;
  BYLAYER/BYBLOCK colors and linetypes resolve correctly; frozen/off layers
  start hidden
- Entity support: LINE, CIRCLE, ARC, LWPOLYLINE (with bulge arcs), POLYLINE
  (2D/3D, polyface meshes, mesh grids), SPLINE (true NURBS evaluation),
  ELLIPSE, SOLID, TRACE, 3DFACE, POINT, HATCH, TEXT, MTEXT, ATTRIB, INSERT
  (including arrays), DIMENSION, LEADER, ACAD_TABLE
- Built for huge files: byte-level streaming parser (no full-file string
  conversion) and an asynchronous bitmap render pipeline — pan/zoom stays
  responsive on multi-million-entity drawings
- Trackpad: two-finger scroll pans, pinch zooms, Option+scroll zooms;
  mouse wheel zooms; drag pans

## Run
```
swift run -c release NovaCAD
```
(Use a release build for large drawings — it parses roughly 10x faster.)

## Install as a Mac app
Build `NovaCAD.app` and install it into `/Applications` so it launches from
Launchpad/Spotlight/Finder like any other app (re-run after code changes):
```
./Scripts/build_app.sh
```
The script compiles a release binary, wraps it in a code-signed `.app` bundle
with a generated icon and an `Info.plist` (registers `.dxf`/`.dwg` document
types), and installs it. Pass a different destination as the first argument to
install elsewhere.

## Roadmap / engineering notes
Deliberate deviations from full AutoCAD parity, and why:
- **Rendering** uses an async CoreGraphics LOD pipeline rather than Metal:
  pan/zoom is a hardware-composited blit while frames re-render in 30–80 ms
  even on multi-million-entity drawings, which already meets the responsiveness goal.
  A Metal canvas remains an option if 3D/orbit views are ever needed.
- **Editing saves as DXF, not DWG**: drawing tools, OSNAP, and the command
  palette are built (see Features), but writing native DWG requires the
  licensed ODA SDK (LibreDWG's writer is experimental) — so markup exports
  and merged copies are DXF, which AutoCAD opens and can save as DWG.
- Erase and Delete only ever remove markup — the original drawing's own
  entities can't be deleted from the UI. Move/Copy/Rotate/Scale/Mirror can
  all act on either markup or a selected original-drawing entity within the
  current session (e.g. nudging a wall while sketching a proposed layout
  change), but that only affects what you see while the app is open: no
  exporter writes the original drawing back out with entities moved/copied/
  transformed, so the result is NOT reflected in "Export Markup as DXF" or
  "Save Copy with Markup" (those still export/merge only the markup layer) or
  in the source file on disk — Reload discards any such in-session edit.
  TRIM/EXTEND/FILLET/CHAMFER/OFFSET/ARRAY/EXPLODE are not yet implemented.
- The Stamp tool explodes a block's symbol into markup lines rather than
  writing a DWG/DXF INSERT that references the block definition.
- Plot settings are not surfaced (Lock and Freeze/Thaw are).

## Headless snapshots
Render a PNG without opening the UI (useful for scripting/batch previews):
```
.build/release/NovaCAD --snapshot out.png [--size 1800x1100] [--light] [--space paper] \
    [--focus x,y,w,h] [--select x,y] [--quality 1-5] [--debug-bounds] <drawing.dxf|.dwg|.zip|folder>
```
`--focus` zooms to a world-coordinate rectangle; `--select` hit-tests a world
point, prints the object's properties, and renders it highlighted;
`--debug-bounds` prints extent and culling statistics.

## Performance notes
- A multi-hundred-MB plant layout with millions of entities loads in ~3
  seconds and renders any view in well under 0.1 s.
- Full-extent views are made possible by render-time level-of-detail: geometry
  is decimated to screen resolution and sub-pixel entities collapse to
  deduplicated ticks (bounded by screen area, not entity count).
- Initial fit uses robust (percentile) extents so stray content parked at
  faraway coordinates can't shrink the real drawing to a dot; press Fit twice
  for true full extents.

## Xrefs & eTransmit packages
The viewer resolves xrefs the way AutoCAD does — from files next to the
drawing:

- **Open an eTransmit ZIP** (from AutoCAD's `-etransmit` command) directly:
  it's extracted, the main drawing is detected, and every xref (nested ones
  included) is resolved from the package and rendered in place.
- **Open a folder** of drawings, or any single .dwg/.dxf — xrefs resolve
  against sibling files automatically.
- Xref layers appear AutoCAD-style as `XREFNAME|layer` in the layer panel,
  and each xref can be shown/hidden from the Xrefs panel.
- DWG packages need a converter: the free ODA File Converter (preferred —
  best fidelity, converts a whole package in one batch run) or GNU LibreDWG
  (`brew install libredwg`) as a fallback. Without either, DXF members still
  resolve and DWG xrefs are flagged unresolved.
  Note: macOS quarantines the freshly downloaded ODA app; run it once from
  Finder (right-click → Open) or `xattr -dr com.apple.quarantine
  /Applications/ODAFileConverter.app` so it can run headless.
- Xrefs whose files are missing from the package (e.g. paths on an unmounted
  network drive) are listed as "Not embedded"; binding xrefs in AutoCAD
  (XREF → Bind) before export also works.

## Rendering quality preference
The toolbar's **Quality** control sets a 1–5 scale, saved across launches
(Reset returns to 3):

| Level | Tradeoff |
|-------|----------|
| 1 Fastest | Coarse detail, no antialiasing — smoothest panning on huge drawings |
| 2 | Reduced detail, antialiased |
| 3 Balanced | Recommended default |
| 4 | Fine detail — slightly slower redraws on dense views |
| 5 Superb | Near-lossless, crispest linework — dense full-extent redraws may lag |

## DWG files
DWG is a proprietary format. Install the free
[ODA File Converter](https://www.opendesign.com/guestfiles/oda_file_converter)
and the app will convert DWG → DXF automatically when you open a .dwg.

Note: LibreCAD's macOS build does not bundle a command-line DWG→DXF converter
(no `dwg2dxf` in the app bundle), so it can't be used for this. The ODA File
Converter is the reliable free option and handles all DWG versions through 2018+.

## Project structure
```
Sources/DWGViewer/
├── DWGViewerApp.swift    # entry point (+ headless snapshot hook)
├── ContentView.swift     # UI: toolbar, layer/xref sidebar, canvas hosting
├── DXFCanvasView.swift   # AppKit canvas: input handling + frame blitting
├── DXFModel.swift        # document model: layers, linetypes, xrefs, groups
├── DXFParser.swift       # byte-level streaming DXF parser
├── GeometryBuilder.swift # block expansion, color/layer resolution, path building
├── DXFRenderer.swift     # async bitmap rasterizer (coalescing, cancellable)
├── SplineEvaluator.swift # NURBS (de Boor) tessellation for SPLINE entities
├── MTextParser.swift     # MTEXT/TEXT formatting-code stripper
├── ACIPalette.swift      # AutoCAD Color Index → RGB table
├── DWGConverter.swift    # DWG → DXF via ODA File Converter
└── SnapshotMode.swift    # headless PNG rendering (--snapshot)
```
