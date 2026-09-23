# NovaCAD 1.6.1 review handoff

## Review scope and base

- Branch: `review/novacad-1.6.1`
- Base: `a296bf4` (the final 1.6.0 commit)
- Scope: the full 1.6.1 workspace batch, follow-up ergonomics fixes, tests, and documentation refresh, packaged as one review commit.
- The fork's published `main` already contains the initial 1.6.1 changes.
  This branch is a complete review snapshot, not a history rewrite. Confirm
  the intended PR target before merging; merging the snapshot into fork `main`
  would overlap changes that are already there.

```sh
git diff --stat a296bf4...HEAD
git diff --check a296bf4...HEAD
swift build
swift test
```

## Expected behavior

1. Empty layouts, including a default paper viewport with no other content,
   are omitted from navigation/counts but retained in the document. A real model
   viewport still counts as content. Adding content invalidates navigation caching.
2. Search frames a match at 28% of the canvas, keeps the chosen ribbon tab, and
   restores the pre-search sheet, selection, zoom and position on close.
3. Each sheet and Model space retains an independent camera. Properties and AI
   share one panel with a remembered tab. Fitted views re-fit on canvas resize;
   manual cameras keep their scale and world center. Centered cameras within
   1% of fit tolerate small restored-layout differences.
4. Units/Info/Issues/Quality resolve their trigger anchors inside the correct
   SwiftUI hosting tree. Status-bar anchors preserve child-button anchors.
   Cards remain inside the window and above the status controls.
5. Compact controls use a custom style with 28-point targets and unchanged
   glyph sizes. Selecting a layer does not shift its row. Layer rows support
   default accessibility selection and expose selected state. Command aliases
   are available in ribbon tooltips and accessibility help.

## Validation recorded for this batch

- Full XCTest suite: 1,260 tests executed, seven skipped, zero failures.
  The skips require an external real-world fixture supplied through
  `NOVACAD_SAMPLE_LAYOUT`; they do not establish coverage of that fixture.
- Release build and installation succeeded. Live checks covered sheet navigation,
  search framing/restoration, four inspector positions, default accessibility
  layer selection, sidebar-tab persistence, fitted/manual panel resizing, and
  clicks outside the layer/close glyphs and Clear Selection text.
- Command aliases were verified in accessibility help. Hover tooltip presentation
  was not separately exercised by the automation tool.
- A private DWG was used locally, with checksums checked before/after. No private
  drawings, screenshots, paths or drawing-content reports belong in this branch.
- README, feature inventory, contributor guide, changelog and historical design
  status notes were reconciled with current source. Upstream distribution is
  explicitly distinguished from the fork build.

## Suggested Amplifier prompt

> Review the full NovaCAD 1.6.1 batch in `review/novacad-1.6.1` against
> `a296bf4`. Read AGENTS.md and this handoff, then inspect the code, tests and
> documentation. Run the pre-PR checks above. Focus on camera restoration
> during search/panel/space changes, conservative empty-layout detection,
> revision-based cache invalidation, SwiftUI anchor propagation, small-window
> inspector clipping, control hit/accessibility bounds, and preservation of
> drawing data. Verify that the documentation describes the implementation
> rather than old proposals. Report actionable findings first, with severity,
> file/line and reproduction or test evidence; distinguish confirmed bugs from
> unverified concerns. Then list missing checks and PR readiness. Do not open,
> merge, or publish a PR as part of this review. The fork's main already contains
> part of this snapshot, so identify the correct PR base and any overlapping
> history before recommending an integration path.
