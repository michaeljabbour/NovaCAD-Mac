# NovaCAD 1.6.1 correction and retest handoff

## Review target and integration

- Branch: `fix/novacad-1.6.1-review`.
- Integration base: `origin/main` (`3bfa55a` when this branch was prepared).
- This branch is a descendant of the published main branch and contains only the
  remaining delta: ergonomics follow-ups, assistant fixes, documentation, and
  corrections from the first Amplifier review. No PR has been opened.
- `review/novacad-1.6.1` (`1bf2419`) and `review/novacad-1.6.1-complete`
  (`b5a48dc`) remain historical full-batch reading snapshots. Do not merge them.
  For the complete 1.6.1 story, compare this branch with `a296bf4`.

```sh
swift build
swift test
git diff --check origin/main...HEAD
git merge-base --is-ancestor origin/main HEAD
git merge-tree --write-tree origin/main HEAD
```

## Corrections to verify

1. **Floating assistant removed.** The shared docked sidebar is the only UI.
   Floating panel implementation, presentation plumbing and 17 unreachable-mode
   tests were removed. CHANGELOG explicitly records the removal.
2. **One paper ownership rule.** `PaperLayoutOwnership.ownerSheetID` supplies both
   navigation and rendering. Recognized group-410 names take precedence; stale
   names fall back to the explicit group-330 owner. Unknown explicit owners do
   not move entities into the default sheet. Reactor references are ignored.
   Frozen/off layers and invisible entities still count as sheet content.
3. **No duplicate opening scan.** Package loading computes navigable sheets once,
   selects the first and seeds the coordinator cache. Document edits invalidate it.
4. **Menu toggle.** View → AI Assistant selects/opens the AI tab when necessary,
   and closes the panel if that tab is already visible.
5. **Empty paper feedback.** A drawing with no populated paper layouts shows an
   explanatory message and a Show Model Space action. Stored layouts are retained.
6. **Small-window inspectors.** Oversized cards scroll in both directions within
   the available frame above the status bar. Content is reachable rather than clipped.
7. **Regression gaps.** Tests cover a populated legacy workspace record loaded and
   re-saved through WorkspaceStore, the actual SwiftUI parent/child anchor preference
   chain, the canvas-resize decision priorities, native inspector scrolling, and
   the sheet ownership/cache cases above.

8. **Live AI viewport context.** Every turn and drawing overview includes current
   canvas bounds and nearby text. `query_entities(visibleOnly: true)` reads live
   camera/visibility state and returns bounded pages of labels, blocks and geometry.
   Inactive-sheet viewport queries fail explicitly. This is approximate geometry
   intersection, not screenshot vision or an unrestricted geometry-editing tool.

The follow-up AI review identified partial arcs using full-circle bounds. The
correction shares sweep-aware bounds between visible geometry queries, drawing
summaries and block footprints, with regression assertions for offscreen arcs,
onscreen arcs, containing blocks and full circles. The complete author suite
still passes 1,265 tests, 7 skipped, 0 failures after this correction.

## Existing 1.6.1 behavior to preserve

- Empty/default-viewport-only layouts stay in the file but leave sheet navigation.
- Search frames matches at 28%, preserves the ribbon tab, and restores the original
  sheet, selection and camera when closed.
- Model and each paper sheet keep independent cameras. Fitted cameras follow panel
  resizing; manual views retain world center/scale. Properties and AI share one tabbed panel.
- Compact controls have 28-point hit targets; layers support accessibility selection;
  ribbon tooltips/accessibility help include command aliases.
- Chat renders Markdown. Drawing tools know the active space/sheet and coordinate
  units; bounded paged queries can inspect another named sheet without navigating.
- Tool replies have a 16 KiB ceiling. Anthropic requests have a 128 KiB ceiling and
  discard older complete tool exchanges as needed, preserving call/result pairing.
  Recent transcript context is bounded separately; visible history/staged proposals
  remain intact. OpenCode manages its own server-side conversation context.

## Evidence and limits

- Author verification: `swift build` passed; `swift test` with the opt-in private
  drawing smoke passed **1,265 tests, 7 skipped, 0 failures**.
  The original snapshot had 1,260 tests; the later assistant snapshot had 1,269.
  This correction removes 17 floating-mode tests and adds nine review regression tests and four viewport-context tests.
- Default runs skip seven external-fixture checks plus the opt-in AI drawing smoke.
  Enable the latter with `NOVACAD_AI_SAMPLE`; `NOVACAD_AI_EXPECT_KITCHENS=1` also
  asserts that kitchen labels were found. Private fixtures are not in the repository.
- Previous author runtime checks covered sheet/search/camera behavior, anchored
  inspectors, accessibility click targets and a synthetic live-provider Markdown
  reply. Private drawing checksums were unchanged. These are author-reported
  runtime results, not claims that the prior Amplifier review independently
  verified the installed UI or those private files.
- Command aliases were observed in accessibility help. Hover tooltip appearance
  still needs a human check; the available automation has no hover action.
- The private drawing's actual kitchen-to-kitchen distance was not established;
  endpoints and paper scale must be confirmed before quoting a physical distance.
- No private drawing, screenshot, personal path or content report belongs in commits.

## Amplifier retest request

Review this branch against `origin/main`, with the six original findings and the
added regression coverage above as the checklist. Independently run the build and
full suite, verify the merge is conflict-free, and review the newer assistant
changes too. Distinguish source/test evidence from live UI claims. Report actionable
findings with severity, file/line references and reproduction evidence, then give a
retest verdict. Do not modify source or drawings, create a PR, merge, publish a
release, or change the installed app. Local review-report files are allowed.
