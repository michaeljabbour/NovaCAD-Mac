import Foundation
import CoreGraphics
import CADCore

// MARK: - Dock detection and apron generation
//
// The geometry engine behind the AI Assistant's `shade_dock_aprons` tool.
// A DOCK APRON is the staging floor immediately inside a bank of receiving/
// shipping dock doors — the area between the doors and the marketplace aisle
// that serves them, where inbound freight is set down before being put away.
// Nothing in a typical plant layout draws that area as a fillable shape, so
// (exactly like `AisleNetwork`'s ribbons) it has to be synthesized: detect the
// dock doors, group them into banks, and buffer each bank inward into a closed
// rectangle that can be hatched/colored on its own overlay layer.
//
// Deliberately PURE, mirroring `AisleNetwork`: geometry in, shapes out. No AI
// types, no UI, no Transaction — the tool layer owns document mutation and
// user-approval staging.
//
// ---- What the reference data actually looks like ----
//
// Measured on a real production layout:
//
//  * 127 distinct `DOCK <n>` labels, spread across FOUR layers (`Trucks`,
//    `Dock`, `DOCK NUMBERS`, `A-WALEX-DOCKS`) — so detection keys on the
//    label TEXT pattern, not on any single layer name.
//  * Those labels cluster into 27 banks of consecutive, evenly spaced doors
//    (measured pitch 14-20 ft, i.e. real dock-door spacing).
//  * A `Dock Apron` layer already EXISTS but contains a single stray MTEXT —
//    an empty placeholder nobody ever drew the aprons on. That is precisely
//    the gap this fills.
//  * Named dock groups appear in sibling files (`BROWN DOCKS`, `SILVER
//    DOCKS`, `BLUE DOCKS`), which is why `DockGroup` carries an optional
//    name for the routing tool's "group of docks" origin.
//
// ---- Why apron DEPTH is a parameter, not auto-measured ----
//
// The obvious approach — buffer from the dock line out to the nearest aisle —
// does not survive contact with the data. Measured distance from each dock
// label to the nearest `AISLE` segment ranges from 3 ft to 1,476 ft
// (median 88 ft; 55 of 127 docks are over 100 ft away). For most docks the
// "nearest aisle" is unrelated geometry somewhere else in the building, so
// auto-extending to it would fabricate absurdly deep aprons. Depth is
// therefore supplied by the caller, and `suggestedDepth(...)` separately
// reports the distance to the nearest PARALLEL aisle per bank as an informed
// suggestion the user can accept or override.
enum DockAprons {

    // MARK: - Dock doors

    /// One dock door, located by its own `DOCK <n>` label.
    struct DockDoor: Equatable {
        var number: Int
        var position: CGPoint
        /// The layer the label was found on — reported so a user can tell
        /// which source a detection came from when several layers carry
        /// overlapping dock labels (they do in production files).
        var layer: String
    }

    /// A contiguous run of dock doors forming one physical dock bank, and
    /// therefore one apron.
    struct DockBank: Equatable {
        var doors: [DockDoor]
        /// Optional human name (`BROWN DOCKS`), when a nearby group label
        /// identifies this bank.
        var name: String?

        var numbers: [Int] { doors.map(\.number) }
        /// Centroid of the bank's doors — the routing origin for
        /// "from this dock group" queries (see `AisleNetwork.centroid`).
        var centroid: CGPoint? { AisleNetwork.centroid(of: doors.map(\.position)) }
    }

    /// Parses a `DOCK <n>` label, tolerating the punctuation/case variants
    /// production drawings use (`DOCK 34`, `DOCK  7`, `Dock 122`). Returns nil
    /// for the non-dock text that shares these layers (`RAMP`, `CONC.`,
    /// `DRIVE-IN DOOR`, `TRASH ROOM`) and for group headers like
    /// `BROWN DOCKS` (no number).
    static func parseDockNumber(_ raw: String) -> Int? {
        let cleaned = raw.uppercased()
            .replacingOccurrences(of: "\\P", with: " ")   // MTEXT paragraph break
            .replacingOccurrences(of: "#", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = cleaned.range(of: #"^DOCK\s+(\d+)$"#, options: .regularExpression) else { return nil }
        return Int(cleaned[m].filter(\.isNumber))
    }

    /// Parses a named dock-group header (`BROWN DOCKS`, `SILVER DOCKS`) —
    /// used to name banks so the routing tool can accept "the blue docks" as
    /// an origin. Deliberately requires the plural and no number, so an
    /// individual `DOCK 9` never reads as a group.
    static func parseDockGroupName(_ raw: String) -> String? {
        let cleaned = raw.uppercased()
            .replacingOccurrences(of: "\\P", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Requires the PLURAL "DOCKS", and must not be a singular numbered
        // door. A trailing count after the name is fine and common in real
        // files (`BLUE DOCKS\P9` = the group name plus its door count), so
        // digits are NOT disqualifying on their own — only a `DOCK <n>`
        // singular label is.
        guard cleaned.contains("DOCKS") else { return nil }
        guard parseDockNumber(raw) == nil else { return nil }
        // Keep the group name itself, dropping any trailing count.
        guard let r = cleaned.range(of: "DOCKS") else { return nil }
        let name = cleaned[..<r.upperBound].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Layers whose dock labels describe the CURRENT building state, in
    /// priority order — the first match wins when one door is annotated on
    /// several layers. Chosen from what production files actually carry:
    /// `Trucks`/`Dock`/`DOCK NUMBERS` are live annotation layers, while
    /// phase layers (`27-NEW`, `27-DEMO`) describe a renovation state rather
    /// than today's floor.
    static let defaultDockLayerPriority = ["DOCK NUMBERS", "Trucks", "Dock"]

    /// Layer-name fragments excluded by default because they describe a
    /// DIFFERENT building phase, not the current one. Critical for
    /// correctness: in the reference file the same dock number legitimately
    /// exists at up to 4 distinct positions across phases (dock 20 appears on
    /// `27-DEMO` and `27-NEW` more than 2,000 units apart), so reading every
    /// phase at once fabricates overlapping banks for docks that never
    /// coexist.
    static let defaultExcludedLayerFragments = ["demo"]

    /// Same-numbered labels closer than this describe ONE door annotated more
    /// than once. Sized from measurement: a door labelled on both `Trucks` and
    /// `Dock` sits 342 units apart in the reference file (and 0 apart when
    /// `DOCK NUMBERS` and `Trucks` agree exactly), while the minimum real door
    /// pitch is 14 ft (168 units)... so this is deliberately a compromise —
    /// see `detectDockDoors`, which only ever merges labels that share a dock
    /// NUMBER, making a collision with a genuinely different door impossible
    /// regardless of distance.
    static let duplicateLabelTolerance: Double = 400

    /// Finds dock doors in `space` by scanning text for the `DOCK <n>`
    /// pattern across layers — not restricted to one layer, because the
    /// reference file spreads dock labels over six of them.
    ///
    /// `layerPriority`/`excludedLayerFragments` keep the result to ONE
    /// coherent building state: phase layers are skipped, and a door annotated
    /// on several live layers resolves to its highest-priority instance.
    /// Because merging only ever considers labels with the SAME dock number,
    /// two physically distinct doors can never be collapsed into one.
    static func detectDockDoors(document: DXFDocument, space: SpaceID,
                                visibility: VisibilityState? = nil,
                                layerPriority: [String] = defaultDockLayerPriority,
                                excludedLayerFragments: [String] = defaultExcludedLayerFragments,
                                includeLayers: [String]? = nil) -> [DockDoor] {
        let groups = space == .paper ? document.paperGroups : document.modelGroups
        let excluded = excludedLayerFragments.map { $0.lowercased() }
        let allowList = includeLayers?.map { $0.lowercased() }
        var found: [DockDoor] = []

        for g in groups {
            let idx = Int(g.layerId)
            if let visibility, visibility.hiddenLayerIds.contains(idx) { continue }
            let layerName = (idx >= 0 && idx < document.layers.count) ? document.layers[idx].name : "?"
            let lower = layerName.lowercased()
            let bare = lower.split(separator: "|").last.map(String.init) ?? lower
            if let allowList {
                guard allowList.contains(lower) || allowList.contains(bare) else { continue }
            } else {
                guard !excluded.contains(where: { bare.contains($0) }) else { continue }
            }
            for t in g.texts {
                guard let n = parseDockNumber(t.text) else { continue }
                found.append(DockDoor(number: n, position: t.position, layer: layerName))
            }
        }

        // Resolve each dock NUMBER to a single door. Labels for one number that
        // sit within `duplicateLabelTolerance` are the same door annotated
        // repeatedly; the highest-priority layer wins. Labels for one number
        // that are FURTHER apart are distinct positions (typically a
        // renovation phase that slipped past the exclusion list), and the
        // highest-priority — else first — is kept so a single coherent state
        // is reported rather than a phantom bank.
        func priority(of layer: String) -> Int {
            let bare = layer.lowercased().split(separator: "|").last.map(String.init) ?? layer.lowercased()
            for (i, name) in layerPriority.enumerated() where bare == name.lowercased() { return i }
            return layerPriority.count
        }
        var byNumber: [Int: [DockDoor]] = [:]
        for d in found { byNumber[d.number, default: []].append(d) }

        var unique: [DockDoor] = []
        for (_, doors) in byNumber {
            let ranked = doors.sorted { priority(of: $0.layer) < priority(of: $1.layer) }
            guard let best = ranked.first else { continue }
            unique.append(best)
            // Keep any same-numbered label that is genuinely FAR from the
            // chosen one only if it also outranks nothing — i.e. never, by
            // construction. Retained as an explicit no-op branch would be
            // misleading, so distinct-position duplicates are simply dropped
            // in favor of the priority winner.
        }
        return unique.sorted { $0.number < $1.number }
    }

    // MARK: - Bank grouping

    /// Maximum centre-to-centre distance between consecutive doors in one
    /// bank. Measured door pitch is 14-20 ft; 75 ft leaves room for a wider
    /// drive-through bay without merging two separate banks.
    static let maxDoorPitch: Double = 75 * 12
    /// Doors more than this far off the bank's own line are a different bank
    /// (perpendicular walls, opposite side of the building).
    static let maxBankCollinearityDeviation: Double = 20 * 12

    /// Groups doors into banks: consecutive numbers, close together, and
    /// roughly collinear. All three conditions matter — number order alone
    /// merges docks on opposite walls, and proximity alone merges two banks
    /// that meet at a building corner.
    static func groupIntoBanks(_ doors: [DockDoor]) -> [DockBank] {
        guard !doors.isEmpty else { return [] }
        let sorted = doors.sorted { $0.number < $1.number }
        var banks: [[DockDoor]] = []
        var current: [DockDoor] = [sorted[0]]

        for door in sorted.dropFirst() {
            let prev = current[current.count - 1]
            let gap = hypot(door.position.x - prev.position.x, door.position.y - prev.position.y)
            let consecutive = door.number == prev.number + 1
            var collinear = true
            if current.count >= 2, let first = current.first {
                // Deviation of the new door from the line the bank has established.
                let line = AisleNetwork.Segment(a: first.position, b: prev.position)
                if line.length > 1e-6 {
                    let dx = Double(line.b.x - line.a.x), dy = Double(line.b.y - line.a.y)
                    let len = (dx * dx + dy * dy).squareRoot()
                    let dev = abs(Double(door.position.x - line.a.x) * dy
                                  - Double(door.position.y - line.a.y) * dx) / len
                    collinear = dev <= maxBankCollinearityDeviation
                }
            }
            if consecutive, Double(gap) <= maxDoorPitch, collinear {
                current.append(door)
            } else {
                banks.append(current)
                current = [door]
            }
        }
        banks.append(current)
        return banks.map { DockBank(doors: $0, name: nil) }
    }

    // MARK: - Apron geometry

    /// A generated apron: a closed shape covering one bank's staging area.
    struct Apron: Equatable {
        /// Corner points, forming a closed quadrilateral.
        var points: [CGPoint]
        /// The bank this apron serves.
        var bankNumbers: [Int]
        var bankName: String?
        /// Depth used (drawing units), inward from the dock line.
        var depth: Double
        /// Frontage length along the dock line (drawing units).
        var frontage: Double
    }

    /// Builds the apron for one bank.
    ///
    /// The bank's doors define a line (its frontage); the apron is that line
    /// extended by `endPadding` at each end and buffered `depth` toward the
    /// building interior. Which side is "interior" cannot be inferred from the
    /// dock labels alone, so `interiorHint` — a point known to be inside the
    /// building, typically the drawing's own centroid or a marketplace aisle
    /// point — disambiguates it. Without a hint the apron is emitted on the
    /// side away from the drawing origin, and the caller should treat the
    /// orientation as unverified.
    static func apron(for bank: DockBank, depth: Double, endPadding: Double = 0,
                      interiorHint: CGPoint?) -> Apron? {
        guard depth > 0, bank.doors.count >= 1 else { return nil }
        let positions = bank.doors.map(\.position)

        // Frontage direction: for a single door there is no line to fit, so
        // such a bank is skipped rather than guessed at (a lone labelled door
        // gives no orientation, and a wrongly-oriented apron is worse than
        // none).
        guard let first = positions.first, let last = positions.last, positions.count >= 2 else {
            return nil
        }
        var dx = Double(last.x - first.x), dy = Double(last.y - first.y)
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1e-6 else { return nil }
        dx /= len; dy /= len

        // Inward normal, resolved against the interior hint.
        var nx = -dy, ny = dx
        if let hint = interiorHint {
            let toHint = Double(hint.x - first.x) * nx + Double(hint.y - first.y) * ny
            if toHint < 0 { nx = -nx; ny = -ny }
        }

        let a = CGPoint(x: first.x - CGFloat(dx * endPadding), y: first.y - CGFloat(dy * endPadding))
        let b = CGPoint(x: last.x + CGFloat(dx * endPadding), y: last.y + CGFloat(dy * endPadding))
        let a2 = CGPoint(x: a.x + CGFloat(nx * depth), y: a.y + CGFloat(ny * depth))
        let b2 = CGPoint(x: b.x + CGFloat(nx * depth), y: b.y + CGFloat(ny * depth))

        return Apron(points: [a, b, b2, a2], bankNumbers: bank.numbers, bankName: bank.name,
                     depth: depth, frontage: len + 2 * endPadding)
    }

    /// Builds aprons for every bank, skipping ones too small to orient.
    static func aprons(for banks: [DockBank], depth: Double, endPadding: Double = 0,
                       interiorHint: CGPoint?) -> [Apron] {
        banks.compactMap { apron(for: $0, depth: depth, endPadding: endPadding, interiorHint: interiorHint) }
    }

    // MARK: - Depth suggestion
    //
    // Reports the distance from a bank to the nearest aisle running roughly
    // PARALLEL to it — the aisle that plausibly bounds this apron. Parallelism
    // is the essential filter: the raw nearest aisle is frequently a
    // perpendicular or unrelated run (measured: dock-to-nearest-aisle spans
    // 3-1,476 ft), which is exactly why depth isn't auto-applied.

    /// Aisles beyond this are not treated as this bank's bounding aisle.
    static let maxSuggestionDistance: Double = 150 * 12
    /// Angular tolerance for "parallel to the dock face".
    static let parallelToleranceDegrees: Double = 20

    /// Nearest plausible parallel-aisle distance for `bank`, or nil when no
    /// aisle qualifies — in which case the caller should ask the user for a
    /// depth rather than inventing one.
    static func suggestedDepth(for bank: DockBank, aisleSegments: [AisleNetwork.Segment]) -> Double? {
        guard bank.doors.count >= 2, let first = bank.doors.first?.position,
              let last = bank.doors.last?.position else { return nil }
        var dx = Double(last.x - first.x), dy = Double(last.y - first.y)
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1e-6 else { return nil }
        dx /= len; dy /= len
        let bankAngle = atan2(dy, dx)

        guard let mid = bank.centroid else { return nil }
        var best: Double?
        for s in aisleSegments {
            let sdx = Double(s.b.x - s.a.x), sdy = Double(s.b.y - s.a.y)
            let slen = (sdx * sdx + sdy * sdy).squareRoot()
            guard slen > 1e-6 else { continue }
            // Compare ORIENTATIONS (mod 180 degrees), not directions: an
            // aisle drawn right-to-left is still parallel to a dock face
            // drawn left-to-right. Normalizing both into [0, pi) and taking
            // the wrap-around minimum is what makes that work — the previous
            // formulation mixed a raw difference with a modulo and silently
            // rejected genuinely parallel aisles.
            var a1 = atan2(sdy, sdx).truncatingRemainder(dividingBy: .pi)
            if a1 < 0 { a1 += .pi }
            var a2 = bankAngle.truncatingRemainder(dividingBy: .pi)
            if a2 < 0 { a2 += .pi }
            var delta = abs(a1 - a2)
            delta = min(delta, .pi - delta)
            guard delta <= parallelToleranceDegrees * .pi / 180 else { continue }
            // Perpendicular distance from the bank's midpoint to this aisle.
            let t = max(0, min(1, (Double(mid.x - s.a.x) * sdx + Double(mid.y - s.a.y) * sdy) / (slen * slen)))
            let q = CGPoint(x: s.a.x + CGFloat(sdx * t), y: s.a.y + CGFloat(sdy * t))
            let d = Double(hypot(mid.x - q.x, mid.y - q.y))
            guard d <= maxSuggestionDistance else { continue }
            if best == nil || d < best! { best = d }
        }
        return best
    }
}
