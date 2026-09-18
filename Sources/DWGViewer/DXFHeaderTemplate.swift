import Foundation

// MARK: - Phase 3: HEADER section default-variable template
//
// A real AutoCAD-authored DXF's HEADER section carries on the order of
// 150-250 `$VAR`s even for a brand-new empty drawing. This codebase's parser
// retains every `$VAR` actually present in whatever file was opened
// (`OrderedHeaderVars`), so re-emitting an EDITED version of an
// already-AutoCAD-authored file just echoes what was there. But two cases
// need defaults this writer must supply itself:
//   1. A file that started life R12 or otherwise minimal (few/no `$VAR`s)
//      gets upgraded to AC1015+ on save — AutoCAD expects a baseline set of
//      vars to exist for R2000+ features (handles, LWPOLYLINE, dictionaries)
//      to make sense at all.
//   2. This app's own drafting tools may eventually construct entities
//      needing header state (current layer, running object snap, etc.) that
//      was never present in an old source file.
//
// Per the task brief: there is no real "empty AutoCAD 2018 save" fixture
// available in this environment to capture verbatim, so this list is
// hand-authored from this codebase's own accumulated DXF-format knowledge
// (the parser/writer code elsewhere in this project, plus the DXF group-code
// reference every other part of this codebase already relies on). It is
// explicitly a best-effort curated subset — NOT a claim of exhaustive
// AutoCAd-2018-empty-save parity — focused on the variables that matter for
// (a) a file being ACCEPTED by AutoCAD at all and (b) this app's own features
// (units, linetype scale, layer/color state, extents) functioning correctly
// after a round trip. Every var below is one AutoCAD itself would also
// write to a genuinely empty new drawing; the ones commented "essential"
// are the ones most likely to cause an open failure or visibly wrong
// behavior (wrong units, invisible geometry, wrong current layer) if absent
// — the rest are lower-risk "AutoCAD always has an opinion about this, might
// as well match it" filler.
enum DXFHeaderTemplate {

    /// One template entry: the var name plus its DEFAULT group-code/value
    /// pairs, used ONLY when the source didn't already define that var —
    /// this is a fill-the-gaps template, never an override of something the
    /// source file actually specified (see `DXFStructuralWriter`'s HEADER
    /// emitter: source vars always win; template vars are appended after,
    /// in this list's order, skipping any name already emitted).
    struct Entry {
        var name: String
        var pairs: [(Int, RawGroupValue)]
    }

    /// Vars computed fresh by the writer itself every time, regardless of
    /// what the source had — never taken from the template (they're
    /// documented here only so `requiredComputedVars` and the template list
    /// are visibly disjoint at a glance): `$ACADVER`, `$HANDSEED`, `$EXTMIN`,
    /// `$EXTMAX`, `$INSUNITS`. See `DXFStructuralWriter`'s HEADER emitter for
    /// where these are actually computed and written.
    ///
    /// `$MEASUREMENT` is DELIBERATELY NOT in this set, even though it also
    /// has writer-side logic (`measurementValue(forInsUnits:)`) — unlike the
    /// vars here, which the writer must ALWAYS freshly (re)compute regardless
    /// of what the source said, `$MEASUREMENT` should only be a smarter
    /// DEFAULT (derived from `$INSUNITS`) for when the source has no
    /// `$MEASUREMENT` of its own — an explicit source value must be echoed
    /// verbatim, never second-guessed. That's the same "only fill a true
    /// gap" contract `defaults` below has, just computed instead of a
    /// hardcoded constant — see `writeHeaderSection`'s handling of it at the
    /// gap-fill step, not the always-overwrite `emitComputed` step.
    static let computedVarNames: Set<String> = [
        "$ACADVER", "$HANDSEED", "$EXTMIN", "$EXTMAX", "$INSUNITS",
    ]

    /// Derives a sensible `$MEASUREMENT` default (0 = imperial, 1 = metric —
    /// governs which default hatch-pattern/linetype library AutoCAD assumes)
    /// from `$INSUNITS`, rather than the previous hardcoded `0` regardless of
    /// the drawing's actual units. Only used when the SOURCE didn't already
    /// specify `$MEASUREMENT` itself (see `writeHeaderSection`'s "source vars
    /// always win" rule) — this only matters for a minimal/synthetic/from-
    /// scratch source that has `$INSUNITS` but no `$MEASUREMENT` at all.
    /// Mapping follows the standard DXF `$INSUNITS` code table (see
    /// `UnitFormat.metresPerUnit` for the same table used elsewhere in this
    /// codebase): imperial-lineage units (inch/foot/mile/microinch/mil/yard/
    /// US survey foot) -> 0; metric-lineage units (mm/cm/m/km/angstrom/nm/
    /// micron/decimetre/decametre/hectometre) -> 1; unitless/unrecognized
    /// (0, or anything outside the known table) keeps the historical
    /// imperial-default fallback of 0, matching AutoCAD's own behavior for
    /// an unspecified-units drawing.
    static func measurementValue(forInsUnits insUnits: Int) -> Int {
        let metricInsUnitsCodes: Set<Int> = [4, 5, 6, 7, 11, 12, 13, 14, 15, 16]
        return metricInsUnitsCodes.contains(insUnits) ? 1 : 0
    }

    /// The curated default template, in the order AutoCAD conventionally
    /// emits them (grouped roughly the way AutoCAD's own HEADER section is
    /// laid out: drawing/version info, then units/scale, then display
    /// defaults, then dimension-adjacent globals, then table-pointer
    /// placeholders). `$ACADVER`/`$HANDSEED`/`$EXTMIN`/`$EXTMAX`/`$INSUNITS`
    /// are DELIBERATELY excluded — the writer always computes and emits
    /// those itself (see `computedVarNames`).
    static let defaults: [Entry] = [
        // --- essential: drawing/version-adjacent bookkeeping AutoCAD checks on open ---
        Entry(name: "$DWGCODEPAGE", pairs: [(3, .string("ANSI_1252"))]),
        Entry(name: "$INSBASE", pairs: [(10, .double(0)), (20, .double(0)), (30, .double(0))]),
        Entry(name: "$LIMMIN", pairs: [(10, .double(0)), (20, .double(0))]),
        Entry(name: "$LIMMAX", pairs: [(10, .double(420)), (20, .double(297))]),

        // --- essential: unit/scale/angle interpretation ---
        Entry(name: "$LUNITS", pairs: [(70, .int(2))]),          // decimal
        Entry(name: "$LUPREC", pairs: [(70, .int(4))]),
        Entry(name: "$AUNITS", pairs: [(70, .int(0))]),          // decimal degrees
        Entry(name: "$AUPREC", pairs: [(70, .int(0))]),
        Entry(name: "$ANGBASE", pairs: [(50, .double(0))]),
        Entry(name: "$ANGDIR", pairs: [(70, .int(0))]),          // CCW
        Entry(name: "$LTSCALE", pairs: [(40, .double(1))]),
        Entry(name: "$CELTSCALE", pairs: [(40, .double(1))]),
        // $MEASUREMENT moved to `computedVarNames`/`measurementValue(forInsUnits:)`
        // so it can be derived from $INSUNITS instead of hardcoded — see that
        // function's doc comment.

        // --- essential: current-state pointers this app's own features read/write ---
        Entry(name: "$CLAYER", pairs: [(8, .string("0"))]),
        Entry(name: "$CELTYPE", pairs: [(6, .string("BYLAYER"))]),
        Entry(name: "$CECOLOR", pairs: [(62, .int(256))]),        // BYLAYER
        Entry(name: "$CELWEIGHT", pairs: [(370, .int(-1))]),      // BYLAYER

        // --- display/edit defaults AutoCAD always carries ---
        Entry(name: "$MIRRTEXT", pairs: [(70, .int(0))]),
        Entry(name: "$PDMODE", pairs: [(70, .int(0))]),
        Entry(name: "$PDSIZE", pairs: [(40, .double(0))]),
        Entry(name: "$FILLMODE", pairs: [(70, .int(1))]),
        Entry(name: "$TILEMODE", pairs: [(70, .int(1))]),        // 1 = model space active (this app has no legacy tiled-viewport mode)
        Entry(name: "$PLINEGEN", pairs: [(70, .int(0))]),
        Entry(name: "$ORTHOMODE", pairs: [(70, .int(0))]),
        Entry(name: "$REGENMODE", pairs: [(70, .int(1))]),
        Entry(name: "$USRTIMER", pairs: [(70, .int(0))]),
        Entry(name: "$SKPOLY", pairs: [(70, .int(0))]),
        Entry(name: "$SPLINETYPE", pairs: [(70, .int(6))]),
        Entry(name: "$SPLINESEGS", pairs: [(70, .int(8))]),
        Entry(name: "$SURFTYPE", pairs: [(70, .int(6))]),
        Entry(name: "$SURFU", pairs: [(70, .int(6))]),
        Entry(name: "$SURFV", pairs: [(70, .int(6))]),

        // --- text/dim style name pointers (by NAME, not handle — legal and
        // universally supported; AutoCAD resolves these against the STYLE/
        // DIMSTYLE tables by name at load) ---
        Entry(name: "$TEXTSTYLE", pairs: [(7, .string("STANDARD"))]),
        Entry(name: "$DIMSTYLE", pairs: [(2, .string("STANDARD"))]),
        Entry(name: "$CMLSTYLE", pairs: [(2, .string("STANDARD"))]),
        Entry(name: "$CMLSCALE", pairs: [(40, .double(1))]),
        Entry(name: "$CMLJUST", pairs: [(70, .int(0))]),

        // --- misc filler AutoCAD always writes, low behavioral risk if wrong ---
        Entry(name: "$ATTMODE", pairs: [(70, .int(1))]),
        Entry(name: "$TEXTSIZE", pairs: [(40, .double(2.5))]),
        Entry(name: "$TEXTQLTY", pairs: [(70, .int(50))]),
        Entry(name: "$SHADEDGE", pairs: [(70, .int(3))]),
        Entry(name: "$SHADEDIF", pairs: [(70, .int(70))]),
        Entry(name: "$UCSNAME", pairs: [(2, .string(""))]),
        Entry(name: "$UCSORG", pairs: [(10, .double(0)), (20, .double(0)), (30, .double(0))]),
        Entry(name: "$UCSXDIR", pairs: [(10, .double(1)), (20, .double(0)), (30, .double(0))]),
        Entry(name: "$UCSYDIR", pairs: [(10, .double(0)), (20, .double(1)), (30, .double(0))]),
        Entry(name: "$PUCSNAME", pairs: [(2, .string(""))]),
        Entry(name: "$PUCSORG", pairs: [(10, .double(0)), (20, .double(0)), (30, .double(0))]),
        Entry(name: "$PUCSXDIR", pairs: [(10, .double(1)), (20, .double(0)), (30, .double(0))]),
        Entry(name: "$PUCSYDIR", pairs: [(10, .double(0)), (20, .double(1)), (30, .double(0))]),
    ]
}
