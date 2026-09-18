<div align="center">

<img src="docs/images/icon.png" width="112" alt="NovaCAD app icon">

# NovaCAD

**Native macOS DWG/DXF viewer, markup, and data tooling for technical drawings and plant layouts.**

Fast, dependency-free, and written from scratch in Swift.

[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue.svg)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138.svg)](#requirements)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-green.svg)](LICENSE)
[![Dependencies: none](https://img.shields.io/badge/dependencies-none-brightgreen.svg)](#requirements)
[![Tests: 1,200+](https://img.shields.io/badge/tests-1%2C200%2B%20passing-success.svg)](#building--testing)

<img src="Assets/Marketing/novacad-precision-workspace.png" width="100%" alt="NovaCAD running on macOS">

</div>

NovaCAD opens DWG/DXF drawings natively on a Mac and renders them smoothly at
any zoom — including multi-hundred-megabyte plant layouts with millions of
entities. On top of the viewer it adds the tools you actually use during a
review: measurement, markup and drawing tools, block/attribute editing, CSV
data extraction, xref handling, aisle/travel-distance analysis, and an
optional AI Assistant that can call those tools on your drawing.

No Electron. No third-party dependencies. One Swift package, `CADCore` +
the app, with the full test suite in the open.

## Screenshots

| Navigate & measure | Zoom detail |
| --- | --- |
| ![Dark canvas with lines, arcs, splines, hatches, text and block inserts](docs/images/canvas-dark.png) | ![Zoomed view of geometry, hatches and dimensions](docs/images/zoom-detail.png) |
| **Block attributes** | **Light theme** |
| ![Block insert with rendered attributes](docs/images/blocks-attributes.png) | ![Light canvas theme](docs/images/canvas-light.png) |

These are real renders produced by the app's own headless snapshot mode from
the synthetic fixtures in `Tests/Fixtures/` — see
[Headless snapshots](#headless-snapshots) to reproduce them.

<img src="Assets/Marketing/novacad-technical-triptych.png" width="100%" alt="Navigate, measure, and mark up — NovaCAD workflow">

## What it is

- A **fast viewer** for DXF (and DWG via a free converter), including xrefs,
  eTransmit ZIP packages, and folders of drawings.
- A **markup and review tool**: draw over the drawing, measure distances and
  areas, search every text string, edit blocks and attributes, and export your
  changes as DXF or CSV.
- A **data tool**: extract attributes and block data to CSV, compute
  aisle-routed travel distances, and (optionally) let an AI Assistant run
  those analyses for you.

## What it isn't

NovaCAD is not a full AutoCAD replacement and does not try to be: it writes
DXF (not DWG), has no plot/print pipeline, no LISP, no 3D modeling, and no
cloud service. See [Known limitations](#known-limitations).

## Requirements

| | |
| --- | --- |
| OS | macOS 15 (Sequoia) or later, Apple Silicon recommended (the packaged `.app`/`.pkg` is arm64) |
| Toolchain | Xcode 16+ / Swift 6.0 (only to build from source) |
| Dependencies | **None** — the package has no third-party dependencies |
| DWG support | Free [ODA File Converter](https://www.opendesign.com/guestfiles/oda_file_converter) (preferred) or GNU LibreDWG (`brew install libredwg`) |

DXF works out of the box. DWG is a proprietary format, so NovaCAD converts it
to DXF once via an external converter and caches the result.

## Quick start

```sh
git clone https://github.com/ryandirezze/NovaCAD-Mac.git
cd NovaCAD-Mac
swift run -c release NovaCAD      # tip: release builds parse large drawings ~10x faster
```

Then open a drawing with **File ▸ Open** (⌘O) or drag a `.dxf`, `.dwg`,
`.zip` (eTransmit), or folder onto the window. Finder double-click works too
once the app is built/installed.

### DWG files

Install the free ODA File Converter, then run it once from Finder
(right-click → Open) or clear its quarantine flag so it can run headless:

```sh
xattr -dr com.apple.quarantine /Applications/ODAFileConverter.app
```

GNU LibreDWG is supported as a fallback (`brew install libredwg`); it handles
fewer DWG versions and is less faithful than the ODA converter.

## Install as a Mac app

```sh
./Scripts/build_app.sh              # builds a release .app and installs to /Applications
./Scripts/build_pkg.sh              # builds NovaCAD-<version>.pkg for sharing
```

Prebuilt installers are attached to
[Releases](https://github.com/ryandirezze/NovaCAD-Mac/releases/latest). The
app and package are ad-hoc signed (no paid Apple Developer ID), so on first
install and first launch macOS shows an "unidentified developer" prompt —
resolve it via **System Settings → Privacy & Security → Open Anyway**, or
right-click → Open. The packaged build is Apple Silicon only.

## Features

### View & navigate

- Renders LINE, CIRCLE, ARC, LWPOLYLINE (with bulges), POLYLINE (2D/3D,
  polyface meshes), SPLINE (true NURBS), ELLIPSE, SOLID, TRACE, 3DFACE, POINT,
  HATCH, TEXT, MTEXT, ATTRIB, INSERT (incl. arrays), DIMENSION, LEADER,
  ACAD_TABLE, with the full ACI palette + true color, linetypes, hatches,
  lineweights, and dark or light canvas themes.
- **Search (⌘F)**: Spotlight-style search over every text string, label,
  attribute, and block name — including resolved xref content — with
  pan/zoom animation to each hit.
- Quality control (1–5) balances detail vs. redraw speed on dense drawings;
  robust "fit" so stray far-away content can't shrink the real drawing to a
  dot.
- Multi-document tabs and trackpad gestures (pan, pinch-zoom, Option+scroll).

### Layers, xrefs & properties

- **Layers panel** — show/hide (freeze/thaw), lock/unlock, color swatches,
  entity counts, search, isolate on double-click.
- **External References pane** — show/hide each xref, flag unresolved ones,
  attach new xrefs, re-point missing xref paths, and open an xref in a new
  tab (auto-reloads when saved).
- **Properties panel** — type, layer, color, linetype, lineweight, geometry
  details, plus editing of layer/color/linetype/lineweight; fill/hatch and
  dimension-format controls where applicable.
- Selection supports click-to-accumulate (AutoCAD PICKADD), Shift to remove,
  Window/Crossing (drag direction), Option-drag Lasso, and Fence, with grip
  editing on selected objects.

### Draw, edit & markup

- Drawing tools: Line, Polyline, Circle, 3-point Arc, Rectangle, Polygon,
  Ellipse, Spline, Point, 3D Face, Text, plus linear/aligned dimensions,
  region-from-boundary, and hatch fill — with **OSNAP** (endpoint, midpoint,
  center, intersection, perpendicular, tangent) and typed coordinate input
  (`100,50`, `@25,0`, length-along-cursor).
- Modify toolset: Move, Copy, Rotate, Scale, Mirror, **Trim, Extend, Fillet,
  Chamfer, Offset, Stretch, Array, Explode, Join**, Erase/Delete — all
  undoable (⌘Z / ⇧⌘Z), and cross-document copy/paste.
- Markup layer: classic draw tools place markup on a `NOVACAD-MARKUP` layer
  in a pickable color so proposed changes read clearly against the original
  drawing.
- **Command palette** at the bottom: type `L`, `PL`, `C`, `A`, `REC`, `POL`,
  `T`, `E`, `DI`, `AREA`, `TR`, `EX`, `F`, `O`, `AR`, `X`, `J`, `Z`, `U`, …,
  with interactive "Select objects:" prompts (`W`/`C`/`F`, `ALL`, `P`, `L`).
- Block tools: insert blocks (true INSERT entities), stamp an existing block
  by picking it, and edit block attributes in a dedicated editor
  (ATTDEF/ATTEDIT).

### Save & export

- **Save (⌘S) / Save As (⇧⌘S)** write the full live document — every
  in-session edit, including modified or deleted original entities — back to
  DXF via the structural writer. Documents opened from DWG save as DXF.
- **Export Markup as DXF…** produces a standalone markup file you can attach
  as an xref over the master drawing.
- **Save Copy with Markup…** writes a byte-faithful copy of the original DXF
  with the markup merged in.
- **Data Extraction** exports attributes/block data to CSV and imports edits
  back from CSV, with a column picker.

> Note: the two *markup* exporters cover the primitive markup set. Block
> stamps and hatch markup are fully preserved by Save/Save As, but may be
> omitted from Export Markup / Save Copy, and stamped blocks are not restored
> by Reload.

### AI Assistant (optional)

A floating chat panel that can answer questions about the open drawing and,
on supported backends, call 18 built-in drawing tools (read entities,
extract attributes, propose attribute edits, analyze/repair aisle networks,
route travel distances, shade aisle/dock areas, export CSVs, and more).
Edits and geometry are **staged for your review** — nothing is applied to the
drawing until you click Apply.

| Provider | API | Tool-calling |
| --- | --- | --- |
| Anthropic | Messages API | ✅ |
| OpenAI-compatible | Chat Completions | Chat only |
| OpenCode CLI | one-shot `opencode run` | Chat only |
| OpenCode server (agentic) | local `opencode serve` | ✅ |

The OpenCode server backend additionally needs the `opencode` CLI and
`npm install @opencode-ai/plugin` in its workspace (the app tells you if it's
missing and runs text-only otherwise). **Privacy:** when you enable the AI
Assistant, drawing content (entity summaries, attributes, computed values) is
sent to the provider you configure.

### Headless snapshots

Render a PNG without opening the UI — useful for scripting and batch
previews:

```sh
.build/release/NovaCAD --snapshot out.png [--size WxH] [--space paper] [--light] \
    [--focus x,y,w,h] [--select x,y] [--quality 1-5] <drawing.dxf|.dwg|.zip|folder>
```

`--focus` zooms to a world-coordinate rectangle; `--select` hit-tests a world
point and renders it highlighted; `--debug-bounds` prints culling statistics.
PNG output is rendered at 2× the requested `--size` for crisp README/social
images. Additional flags (`--exec`, `--compare`, `--roundtrip`, …) exist for
automation and the project's own verification harnesses.

## Xrefs & eTransmit

- Open an eTransmit ZIP directly: it's extracted, the main drawing is
  detected, and nested xrefs resolve from the package.
- Open a folder of drawings or a single file; xrefs resolve from sibling
  files, with `XREFNAME|layer` entries in the Layers panel.
- Missing xrefs are flagged; you can re-point them or bind xrefs in AutoCAD
  before export.

## Performance

NovaCAD is built for large industrial drawings: a byte-level streaming DXF
parser (no full-file string conversion) feeds an asynchronous, coalescing
CoreGraphics render pipeline with render-time level-of-detail, so geometry is
decimated to screen resolution and sub-pixel entities collapse to
deduplicated ticks. Pan/zoom stays responsive on multi-million-entity
drawings.

Rather than quoting benchmark numbers, measure on your own hardware — the
headless snapshot CLI prints parse and render timings:

```sh
.build/release/NovaCAD --snapshot /tmp/out.png your-drawing.dxf
```

## Architecture

<img src="docs/images/architecture.svg" width="100%" alt="NovaCAD architecture diagram">

Two targets, one package: **CADCore** (streaming DXF parser, geometry/NURBS,
block and layer resolution, DWG→DXF bridge) is a self-contained library;
**DWGViewer** is the macOS app (renderer, canvas, panels, editing, command
palette, AI Assistant). The headless snapshot mode uses the same pipeline the
UI does.

## Building & testing

```sh
swift build                 # compile
swift test                  # 1,200+ XCTest cases
swift run -c release NovaCAD
./Scripts/build_app.sh      # release .app → /Applications
./Scripts/build_pkg.sh      # distributable .pkg
```

Test fixtures are small synthetic DXF files under `Tests/Fixtures/`; tests
that exercise very large real-world drawings look for them via
`NOVACAD_SAMPLE_LAYOUT` and skip when it isn't set.

## Project structure

```
Sources/
├── CADCore/               # parser + geometry library (no UI, no AppKit)
│   ├── DXFParser.swift         # byte-level streaming DXF reader
│   ├── DXFModel.swift          # document model: layers, linetypes, xrefs
│   ├── Geometry/               # curves, splines, offsets, intersections
│   └── DWGConverter.swift      # DWG → DXF via ODA / LibreDWG
├── DWGViewer/             # the macOS app
│   ├── DWGViewerApp.swift      # entry point (+ headless snapshot hook)
│   ├── ContentView.swift       # toolbar, panels, canvas hosting
│   ├── DXFCanvasView.swift     # AppKit canvas: input + frame blitting
│   ├── DXFRenderer.swift       # async bitmap rasterizer
│   ├── Editing/                # trim, fillet, offset, array, stretch, …
│   ├── Commands/               # command registry + headless harness
│   └── AI/                     # optional AI Assistant backends + tools
Tests/DWGViewerTests/      # 1,200+ tests, 18 synthetic DXF fixtures
Scripts/                   # build_app.sh, build_pkg.sh, icon generator
```

## Known limitations

- Writes **DXF only** — native DWG writing requires the licensed ODA SDK.
- No plot/print pipeline; no LISP; no 3D modeling or orbit views (2D canvas
  with a high-performance CoreGraphics pipeline).
- `Export Markup as DXF` / `Save Copy with Markup` cover the primitive markup
  set (see the note under Save & export).
- The AI Assistant is optional and requires your own provider/credentials;
  tool-calling needs the Anthropic or OpenCode server backend.
- The packaged app is ad-hoc signed (Gatekeeper prompt on first run) and
  Apple Silicon only.
- DXF is a large format: uncommon entities render as their nearest
  supported representation or are skipped with diagnostics.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Bug
reports are most useful with a minimal repro and (if possible) a small
synthetic DXF; please never attach real or proprietary drawings.

## License & trademarks

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

NovaCAD is an independent project and is not affiliated with, endorsed by, or
sponsored by Autodesk, Inc. AutoCAD and DWG are trademarks of Autodesk, Inc.
ODA File Converter is a product of the Open Design Alliance. Apple and macOS
are trademarks of Apple Inc. All other trademarks are the property of their
respective owners.
