# NovaCAD — Implemented Features & Requirements

current_status = [X]

All features listed below have been verified as implemented in the codebase.
Known rendering/export limits are documented in README.md.

## Workspace Ergonomics
[X] **Tabbed ribbon** — full-width Home/Draw/Modify/Annotate/View groups, defined button targets and larger primary icons, responsive group menus, active-tool highlight, persistent tabs-only collapse (⌥⌘R) and selected tab
[X] **Quick access** — File, Save, Undo/Redo, drawing filename, Find, and AI Assistant in one compact title bar; advanced tools preserved
[X] **Quieter DWG opening** — individual files reuse persistent conversions; source edits invalidate cache, including same-size edits within a second; ODA starts hidden with Qt activation disabled

## File, Workspace & Sheets
[X] **File menus** — native macOS and in-window menus with Open Recent, Save/Save As, reload, recovery, markup and PDF export
[X] **Workspace memory** — per-drawing sheet/camera/visibility plus named view presets, matching layers by original name
[X] **Sheet-aware layers** — optional current-sheet filtering, geometry counts, and Zoom to Layer
[X] **Recovery** — detached background DXF checkpoints after edits; recovery browser; originals never auto-overwritten; atomic saves
[X] **Sheet fidelity** — linked raster images, top-down 2D clipped viewports, frozen viewport layers, visible missing/unsupported-content diagnostics
[X] **PDF export** — selected sheets as separate vector pages; physical paper sizes, explicit scale or fit, entity/layer lineweights; CTB/STB not applied

## Core Viewer Capabilities
[X] **DXF/DWG file loading** — supports .dxf, .dwg (via ODA File Converter or LibreDWG), .zip (eTransmit packages), and folders of drawings
[X] **AutoCAD-comparable rendering** — per-entity/per-layer colors (full ACI palette + true color), dark/light canvas, linetypes (dashed/center/hidden), hatches, solids, dimensions, text with alignment/rotation
[X] **Entity support** — LINE, CIRCLE, ARC, LWPOLYLINE (with bulge arcs), POLYLINE (2D/3D, polyface meshes, grids), SPLINE (NURBS), ELLIPSE, SOLID, TRACE, 3DFACE, POINT, HATCH, TEXT, MTEXT, ATTRIB, INSERT (with arrays), DIMENSION, LEADER, ACAD_TABLE
[X] **AutoCAD semantics** — block entities on layer 0 inherit insert's layer, BYLAYER/BYBLOCK colors/linetypes resolve correctly, frozen/off layers start hidden
[X] **Performance optimization** — async bitmap render pipeline (30–80 ms redraws on multi-million-entity files), byte-level streaming parser (no full-file string conversion), render-time LOD via point-run decimation bounded by screen area
[X] **Huge file support** — handles multi-million-entity drawings; tested on multi-hundred-MB plant layouts with millions of entities

## Search & Navigation
[X] **Deep search (⌘F)** — Spotlight-style search over text, labels, attributes, block names, and xref content; results update live; Enter/arrows step through matches with animated pan/zoom and 1.5s selection halo
[X] **Zoom controls** — trackpad pinch zoom, two-finger scroll pans, Option+scroll, mouse wheel, drag panning
[X] **Fit-to-view** — initial fit uses robust (percentile) extents; press Fit twice for true full extents

## Measurement Tools
[X] **Distance mode** — click two points → distance, ΔX/ΔY, angle
[X] **Area mode** — click boundary points, double-click/Enter to close → area + perimeter
[X] **Radius mode** — pick circle/arc → radius readout
[X] **Angle mode** — 3-point → angle measurement
[X] **Live preview** — rubber-band preview with live readout chip
[X] **Unit systems** — parsed from $INSUNITS; display formats: decimal, architectural, engineering, fractional, scientific (× imperial/metric/as-drawn × precision)

## Drawing Tools & Markup
[X] **Drawing tools** — Line, Polyline, Circle, 3-point Arc, Rectangle, Polygon, Text, Erase on a `NOVACAD-MARKUP` layer
[X] **OSNAP** — endpoint, midpoint, center, intersection, perpendicular, tangent (with visual markers)
[X] **Typed input** — absolute (100,50), relative (@25,0), length along cursor direction, polygon side count, close polyline
[X] **Markup color** — selectable from toolbar (red, green, blue, …), saved across launches, travels with exported/merged DXF
[X] **Command palette** — AutoCAD-style command line at bottom: `L`, `PL`, `C`, `A`, `REC`, `POL`, `T`, `E`, `DI`, `AREA`, `Z`, `U`

## Edit Markup
[X] **Select markup** — click to select (Shift extends, Esc deselects)
[X] **Move markup** — drag selected entities
[X] **Delete markup** — Delete key removes selected markup
[X] **Recolor markup** — change color via popup menu
[X] **Edit properties** — editable Markup panel shows type, layer, color
[X] **Undo** — ⌘Z removes last action (grouped for stamps)

## Markup Export & Merging
[X] **Export Markup as DXF** — standalone DXF for use as xref over master drawing in AutoCAD
[X] **Save Copy with Markup** — byte-faithful copy of original DXF with markup entities merged in (NOVACAD-MARKUP layer injected into LAYER table + entities)
[X] Both preserve original drawing content untouched

## Block Operations
[X] **Stamp blocks** — pick existing block symbol, click to place copies as markup with ghost preview and OSNAP
[X] **Top-250 blocks** — up to 250 block symbols captured (limited to ≤200 primitives each, ≤40K total)
[X] **Explode on stamp** — symbol explodes to markup lines (not INSERT references)

## Layer Management
[X] **English drawing labels** — local aliases for common Russian layer, block, line-type and hatch names in controls and search; original names remain in tooltips without changing identifiers
[X] **Bulk visibility and reversible isolation** — Show/Hide/Isolate for selected layers or search results; Restore preserves the previous hidden-layer set
[X] **Named paper-sheet selection** — render one layout at a time; preserve all layout blocks and paper ownership when saving
[X] **Layer panel** — show/hide (freeze/thaw) any layer, color swatches, entity counts, search filter
[X] **Lock/unlock layers** — locked layers stay visible but can't be selected or snapped
[X] **Bulk controls** — All On / All Off buttons
[X] **Isolate layer** — double-click to isolate
[X] **Xref layer naming** — AutoCAD-style `XREFNAME|layer` in layer panel

## Xref & Package Support
[X] **eTransmit packages** — open .zip directly, extracts and resolves all xrefs (nested/circular)
[X] **Folder/file opens** — xrefs resolve against sibling files automatically
[X] **Xref panel** — show/hide each external reference independently
[X] **Xref detection** — missing/unresolved xrefs flagged (e.g., external `P:\...` DWG paths with no geometry)
[X] **DWG converter stack** — ODA File Converter (preferred) or GNU LibreDWG fallback (DXF members always work)
[X] **eTransmit report parsing** — auto-detects main drawing via package's .txt report

## Selection & Properties
[X] **Click selection** — click objects to select (block insert selects whole block reference, like AutoCAD)
[X] **Multi-selection** — clicks accumulate (AutoCAD PICKADD), Shift+click removes, Esc/clicking empty space deselects
[X] **Properties panel** — type, layer, color, linetype, geometry (length, area, radius, text contents, block name/scale/rotation, …); minimizable to edge tab
[X] **Multi-selection merge** — "Various/Multiple" shown for differing properties

## Document Operations
[X] **Reload** — re-open drawing and xrefs from disk, preserving view, markup, and layer state
[X] **Quality preference** — 1–5 scale (Fastest → Superb) saved across launches; Reset returns to 3
[X] **Unsaved-markup warning** — confirm on open if markup exists

## Headless Snapshots
[X] **CLI rendering** — `--snapshot out.png` renders PNG without UI
[X] **Options** — `--size`, `--light`, `--space paper`, `--focus x,y,w,h`, `--select x,y`, `--quality`, `--debug-bounds`
[X] **Batch preview** — works on .dxf, .dwg, .zip, folders

## Application Packaging
[X] **macOS app bundle** — `Scripts/build_app.sh` compiles, code-signs, generates icon, creates Info.plist
[X] **Document type registration** — .dxf/.dwg files open with NovaCAD in Finder/Launchpad
[X] **Re-run after code changes** — script refreshes installed app

## Deferred/Not Implemented (Documented Rationale)
[-] **Metal/3D rendering** — current CoreGraphics pipeline meets perf goals; Metal remains optional for 3D/orbit
[-] **DWG writing** — only DXF export; requires licensed ODA SDK for native DWG
[-] **Original entity editing** — editing is additive markup only; source geometry never modified
[-] **Block INSERT writing** — Stamp tool explodes blocks to lines, not INSERT entities
[-] **Plot settings** — not exposed (Lock/Freeze are)

## Workspace ergonomics
[X] **Anchored inspectors** — Issues, Quality, Units and Drawing Info open beside their triggers inside the window, above the status bar; precision includes a numeric field
[X] **Sheet navigation** — Model/Paper, named sheet, Previous/Next and sheet count beneath the ribbon; empty layouts excluded without changing the file; separate saved cameras for each sheet and Model
[X] **Fixed properties strip** — current layer and markup color appear once, independent of the active ribbon tab
[X] **Search navigation** — automatic first-match framing at 28% of the canvas, outline highlight and a results menu above the canvas; closing search restores the prior camera
[X] **Native editing menus** — real Mac Undo/Redo/Copy/Paste/Find/Zoom shortcuts, no duplicate clipboard entries
[X] **Text extents** — MTEXT reference-width wrapping with shared rendering, fitting and selection metrics
[X] **Paper-only model handling** — unused block definitions no longer masquerade as Model-space tables
[X] **Unit notices** — distinguish coordinate units from mixed-unit annotation labels

[X] **Tabbed inspector sidebar** — Properties and AI Assistant share one panel and remember the selected tab
[X] **Accessible layer selection** — selected state and default press action, plus separate eye, lock and color controls with 24-point targets
