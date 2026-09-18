# NovaCAD — Agent Instructions

NovaCAD is a high-performance native macOS viewer for DWG/DXF drawings, built
as an AutoCAD-comparable tool for technical and plant drawings (formerly
"DWG Viewer for Mac"). Its `CADCore` byte-level DXF parser and geometry are
shared with other CAD tools.

## Authoritative docs

- `README.md` — feature overview.
- `IMPLEMENTED_FEATURES.md` — implemented capability inventory.

## Build & test

```sh
swift build            # compile
swift test             # run the test suite (XCTest)
```

Keep the suite green before committing. Be especially careful with
`Sources/DWGViewer/Regenerator.swift` — it is performance- and
correctness-sensitive on very large drawings, and some paths have light
test coverage.

## Attributes and drawing-content visibility

> Covered by `ConvertedAttributesTests.swift` and
> `EmbeddedNewlineValueTests.swift`. Read this before touching attribute
> handling, block-attribute rendering, or the byte-level DXF group-code
> reader.

1. **An attribute's data and its on-canvas visibility are two separate
   concerns.** Data reads (`EntityStore.children(of:)`,
   `BlockEditor.attributes(of:in:)`, keyed on `OwnerRef.parentEntity`) and
   `Regenerator`'s render walk (`EntitySource` visits only `.space(...)` and
   `.blockRange(...)`) are independent paths that must both be taught about
   any new attribute-linking mechanism, or "fix one, break the other"
   regressions follow.

2. **An invisible ATTRIB (DXF group-70 bit 1) must be retained in the
   store** (marked `EntityFlags.invisible`) and skipped only in
   `Regenerator.emitPrimitive`'s invisible guard. Never drop it at parse
   time — its value is still data-bearing for extraction/reporting.

3. **An ATTRIB's real TAG is DXF group code 2 — read it explicitly** into
   `TextPayload.tagStringId`. Deriving a tag from the value text mislabels
   extraction columns and makes tag-keyed edits silently no-op.

4. **Concatenate a multi-line ATTRIB value's group-3 continuation chunks
   with its final group-1 chunk**, mirroring the MTEXT case in
   `EntityStoreParser.swift`; reading only group 1 truncates the value.

5. **The byte-level DXF reader's code/value pairing must be
   self-resynchronizing, never based on line-number parity.** A value with
   an embedded newline spans two physical lines; a parity scheme misreads
   the second as the next group code and shifts every later pair. Keep the
   explicit `expectingCode` toggle.

**Debugging tip:** for "attributes missing on some objects" reports on
converted DXF files, diff parsed entity counts against `Regenerator.build(...)`
render groups to localize the fault to the parser or to the render walk.

## Travel distance / aisle routing

> Covered by `TravelNetworkTests`, `TravelToolSkillTests`, and
> `TravelNetworkRepairPerfTests`.

1. **Never route on the raw segments of an aisle layer.** A real aisle layer
   often carries boundary edge lines alongside its centerline; edge routing
   has no crossings at intersections, can't switch sides, and lets A*
   wander onto the wrong edge. Go through `TravelNetwork.prepare`, which
   collapses pairs via `AisleNetwork.detectCorridors`. `CenterlineMode.raw`
   is diagnosis-only.

2. **When no boundary pairs are found, fall back to the raw geometry** —
   otherwise clean centerline drawings become unroutable.

3. **`AisleNetwork.repair` must bridge gaps in batches and verify progress
   each pass** (keep the per-pass component-count guard and
   `maxRepairPasses`).

4. **Anchor a trip at the nearest point on an object's footprint**, not its
   insert reference point or centroid.

5. **Always report both one-way and round-trip distances and emit the
   diagnostics block** (`straight_line_ft`/`detour_ratio`).

## AI assistant transcript + turn health

> Covered by `AIAssistantHealthTests`.

1. Reconcile streamed text against this turn's tracked bubble index, never
   `history.last`, and accept at most one completion per turn
   (`didAcceptCompletion`).
2. Guard a superseded turn's `defer` with a turn id.
3. `AIToolExecutor` must hold `RegenCoordinator` weakly, read the selection
   through a provider closure (never a snapshot), and `resetAssistant` must
   keep the conversation that `clearConversation` wipes.

## Installing to /Applications + distributing a .pkg

1. **Installing** (`./Scripts/build_app.sh`) is the normal
   "build + test + install" step. Before running it, add one plain-language
   bullet to `WhatsNew.recentHighlights` in
   `Sources/DWGViewer/App/WelcomeView.swift` ("you can now do X"), not
   implementation detail, trimming older entries.

2. **Bump `AppVersion.fallback`** (`Sources/DWGViewer/App/AppVersion.swift`)
   when a batch of changes warrants re-showing the Welcome/What's New
   screen. That constant is the single source of truth for the version
   shown in About/Welcome, `CFBundleShortVersionString`, and the shared
   `.pkg` filename — both build scripts read it from that file.

3. **Packaging** (`./Scripts/build_pkg.sh`) produces
   `NovaCAD-<AppVersion>.pkg` in the repo root (gitignored). The app and
   package are ad-hoc signed (no paid Apple Developer ID), so recipients
   see one Gatekeeper "unidentified developer" prompt on first install and
   one on first launch (Open Anyway via Privacy & Security, or right-click →
   Open). The build is Apple Silicon (arm64) only.
