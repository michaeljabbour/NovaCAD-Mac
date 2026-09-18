import Foundation
import CoreGraphics

enum SysVarValue: Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case point2(CGPoint)
}

enum SysVarScope {
    /// Eventually persists to the DXF header once Phase 1's EditableDocument
    /// exists (real per-drawing storage). For now, `.drawing`-scoped vars
    /// simply behave identically to `.application`-scoped ones — i.e.
    /// UserDefaults-backed, global to the app rather than per-document. The
    /// distinction is recorded here so the later migration only has to
    /// change where a `.drawing`-scoped var reads/writes from, not which
    /// vars are drawing-scoped.
    case drawing
    case application
}

struct SysVarDef {
    /// Canonical uppercase name, e.g. "MIRRTEXT".
    let name: String
    let scope: SysVarScope
    let defaultValue: SysVarValue
    /// Clamp or reject a candidate new value. Returning nil rejects the
    /// value entirely (the caller keeps the old value); returning a
    /// (possibly adjusted/clamped) value accepts it.
    let validate: (SysVarValue) -> SysVarValue?
    let help: String
}

/// Central store for AutoCAD-style system variables. Values are seeded from
/// `registry` defaults, then overlaid with anything persisted in
/// UserDefaults (so user changes survive relaunch). `.drawing`-scoped vars
/// are, for now, stored exactly the same way as `.application`-scoped ones —
/// see `SysVarScope.drawing`'s doc comment.
@MainActor
final class SysVars: ObservableObject {
    @Published private var values: [String: SysVarValue] = [:]

    private static func defaultsKey(_ name: String) -> String { "novacad.sysvar.\(name)" }

    init() {
        for def in Self.registry {
            values[def.name] = Self.loadPersisted(def) ?? def.defaultValue
        }
    }

    func get(_ name: String) -> SysVarValue? {
        values[name.uppercased()]
    }

    /// Sets a sysvar's value, running it through the def's validator.
    /// Returns the OLD value on success, or nil if the name is unknown or
    /// validation rejected the candidate value (in which case the stored
    /// value is left unchanged).
    @discardableResult
    func set(_ name: String, _ v: SysVarValue) -> SysVarValue? {
        let key = name.uppercased()
        guard let def = Self.registry.first(where: { $0.name == key }) else { return nil }
        guard let accepted = def.validate(v) else { return nil }
        let old = values[key]
        values[key] = accepted
        Self.persist(name: key, value: accepted)
        return old
    }

    func bool(_ name: String) -> Bool {
        switch get(name) {
        case .bool(let b): return b
        case .int(let i): return i != 0
        default: return false
        }
    }

    func int(_ name: String) -> Int {
        switch get(name) {
        case .int(let i): return i
        case .bool(let b): return b ? 1 : 0
        case .double(let d): return Int(d)
        default: return 0
        }
    }

    func double(_ name: String) -> Double {
        switch get(name) {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return 0
        }
    }

    func string(_ name: String) -> String {
        if case .string(let s)? = get(name) { return s }
        return ""
    }

    func point(_ name: String) -> CGPoint {
        if case .point2(let p)? = get(name) { return p }
        return .zero
    }

    /// Toggles a bool var (or a 0/1-style int var) — used by status-bar
    /// toggle buttons. No-op for any other var type or unknown name.
    func toggle(_ name: String) {
        let key = name.uppercased()
        switch values[key] {
        case .bool(let b):
            set(key, .bool(!b))
        case .int(let i):
            set(key, .int(i == 0 ? 1 : 0))
        default:
            break
        }
    }

    // MARK: - Persistence

    private static func loadPersisted(_ def: SysVarDef) -> SysVarValue? {
        let d = UserDefaults.standard
        let key = defaultsKey(def.name)
        guard d.object(forKey: key) != nil else { return nil }
        switch def.defaultValue {
        case .bool:
            return .bool(d.bool(forKey: key))
        case .int:
            return .int(d.integer(forKey: key))
        case .double:
            return .double(d.double(forKey: key))
        case .string:
            return .string(d.string(forKey: key) ?? "")
        case .point2:
            let arr = d.array(forKey: key) as? [Double]
            guard let arr, arr.count == 2 else { return nil }
            return .point2(CGPoint(x: arr[0], y: arr[1]))
        }
    }

    private static func persist(name: String, value: SysVarValue) {
        let d = UserDefaults.standard
        let key = defaultsKey(name)
        switch value {
        case .bool(let b): d.set(b, forKey: key)
        case .int(let i): d.set(i, forKey: key)
        case .double(let v): d.set(v, forKey: key)
        case .string(let s): d.set(s, forKey: key)
        case .point2(let p): d.set([Double(p.x), Double(p.y)], forKey: key)
        }
    }

    // MARK: - Validators

    private static func anyBool(_ v: SysVarValue) -> SysVarValue? {
        switch v {
        case .bool: return v
        case .int(let i): return .bool(i != 0)
        default: return nil
        }
    }

    private static func clampedInt(_ lo: Int, _ hi: Int) -> (SysVarValue) -> SysVarValue? {
        { v in
            switch v {
            case .int(let i): return .int(max(lo, min(hi, i)))
            case .bool(let b): return .int(max(lo, min(hi, b ? 1 : 0)))
            default: return nil
            }
        }
    }

    private static func nonNegativeDouble(_ v: SysVarValue) -> SysVarValue? {
        guard case .double(let d) = v else { return nil }
        return .double(max(0, d))
    }

    private static func anyDouble(_ v: SysVarValue) -> SysVarValue? {
        guard case .double = v else { return nil }
        return v
    }

    private static func anyString(_ v: SysVarValue) -> SysVarValue? {
        guard case .string = v else { return nil }
        return v
    }

    private static func anyPoint(_ v: SysVarValue) -> SysVarValue? {
        guard case .point2 = v else { return nil }
        return v
    }

    // MARK: - Registry

    static let registry: [SysVarDef] = [
        SysVarDef(name: "INSUNITS", scope: .drawing, defaultValue: .int(1),
                  validate: clampedInt(0, 20),
                  help: "Drawing insertion units (DXF header $INSUNITS code)."),
        SysVarDef(name: "MEASUREMENT", scope: .drawing, defaultValue: .int(0),
                  validate: clampedInt(0, 1),
                  help: "0 = imperial hatch/linetype defaults, 1 = metric."),
        SysVarDef(name: "LTSCALE", scope: .drawing, defaultValue: .double(1.0),
                  validate: nonNegativeDouble,
                  help: "Global linetype scale factor."),
        SysVarDef(name: "CELTSCALE", scope: .drawing, defaultValue: .double(1.0),
                  validate: nonNegativeDouble,
                  help: "Current entity linetype scale factor."),
        SysVarDef(name: "ANGBASE", scope: .drawing, defaultValue: .double(0.0),
                  validate: anyDouble,
                  help: "Direction (degrees) of angle zero for this drawing."),
        SysVarDef(name: "ANGDIR", scope: .drawing, defaultValue: .int(0),
                  validate: clampedInt(0, 1),
                  help: "0 = counterclockwise angles, 1 = clockwise."),
        SysVarDef(name: "PDMODE", scope: .drawing, defaultValue: .int(0),
                  validate: clampedInt(0, 99),
                  help: "POINT entity display style."),
        SysVarDef(name: "PDSIZE", scope: .drawing, defaultValue: .double(0.0),
                  validate: anyDouble,
                  help: "POINT entity display size (0 = 5% of viewport height)."),
        SysVarDef(name: "MIRRTEXT", scope: .drawing, defaultValue: .int(0),
                  validate: clampedInt(0, 1),
                  help: "Controls whether text is mirrored by MIRROR."),
        SysVarDef(name: "TILEMODE", scope: .drawing, defaultValue: .int(1),
                  validate: clampedInt(0, 1),
                  help: "1 = model space tiled viewports, 0 = paper space layouts."),
        SysVarDef(name: "HPNAME", scope: .application, defaultValue: .string("ANSI31"),
                  validate: anyString,
                  help: "Default hatch pattern name."),
        SysVarDef(name: "HPSCALE", scope: .drawing, defaultValue: .double(1.0),
                  validate: nonNegativeDouble,
                  help: "Default hatch pattern scale."),
        SysVarDef(name: "HPANG", scope: .drawing, defaultValue: .double(0.0),
                  validate: anyDouble,
                  help: "Default hatch pattern angle."),
        SysVarDef(name: "HPASSOC", scope: .application, defaultValue: .int(1),
                  validate: clampedInt(0, 1),
                  help: "Whether new hatches are associative with their boundary."),
        SysVarDef(name: "PICKFIRST", scope: .application, defaultValue: .int(1),
                  validate: clampedInt(0, 1),
                  help: "Select objects before invoking a command (noun-verb)."),
        SysVarDef(name: "PICKADD", scope: .application, defaultValue: .int(1),
                  validate: clampedInt(0, 1),
                  help: "Whether each new pick adds to the selection set."),
        SysVarDef(name: "PICKAUTO", scope: .application, defaultValue: .int(1),
                  validate: clampedInt(0, 1),
                  help: "Automatic windowing at the Select Objects prompt."),
        SysVarDef(name: "PICKBOX", scope: .application, defaultValue: .int(5),
                  validate: clampedInt(0, 50),
                  help: "Object selection pickbox height, in pixels."),
        SysVarDef(name: "EDGEMODE", scope: .application, defaultValue: .int(0),
                  validate: clampedInt(0, 1),
                  help: "Controls how TRIM/EXTEND determine cutting/boundary edges."),
        SysVarDef(name: "OSMODE", scope: .application, defaultValue: .int(4133),
                  validate: clampedInt(0, 16383),
                  help: "Running object snap bitmask."),
        SysVarDef(name: "AUTOSNAP", scope: .application, defaultValue: .int(63),
                  validate: clampedInt(0, 255),
                  help: "Object snap marker/magnet/tooltip/aperture bitmask."),
        SysVarDef(name: "DYNMODE", scope: .application, defaultValue: .int(3),
                  validate: clampedInt(-4, 3),
                  help: "Dynamic input on/off state."),
        SysVarDef(name: "GRIDMODE", scope: .application, defaultValue: .int(0),
                  validate: clampedInt(0, 1),
                  help: "Whether the grid is displayed."),
        SysVarDef(name: "GRIDUNIT", scope: .application, defaultValue: .point2(CGPoint(x: 10, y: 10)),
                  validate: anyPoint,
                  help: "Grid X/Y spacing."),
        SysVarDef(name: "SNAPMODE", scope: .application, defaultValue: .int(0),
                  validate: clampedInt(0, 1),
                  help: "Whether Snap mode is on."),
        SysVarDef(name: "SNAPUNIT", scope: .application, defaultValue: .point2(CGPoint(x: 10, y: 10)),
                  validate: anyPoint,
                  help: "Snap grid X/Y spacing."),
        SysVarDef(name: "ORTHOMODE", scope: .application, defaultValue: .int(0),
                  validate: clampedInt(0, 1),
                  help: "Whether Ortho mode constrains cursor movement."),
        SysVarDef(name: "POLARMODE", scope: .application, defaultValue: .int(0),
                  validate: clampedInt(0, 15),
                  help: "Polar/object snap tracking settings bitmask."),
        SysVarDef(name: "POLARANG", scope: .application, defaultValue: .double(90.0),
                  validate: anyDouble,
                  help: "Polar tracking increment angle, in degrees."),
        SysVarDef(name: "LWDISPLAY", scope: .application, defaultValue: .int(0),
                  validate: clampedInt(0, 1),
                  help: "Whether lineweights are displayed on screen."),
        SysVarDef(name: "FILLETRAD", scope: .application, defaultValue: .double(0.0),
                  validate: nonNegativeDouble,
                  help: "Current fillet radius."),
        SysVarDef(name: "TRIMMODE", scope: .application, defaultValue: .int(1),
                  validate: clampedInt(0, 1),
                  help: "Whether FILLET/CHAMFER trim the selected edges."),
        SysVarDef(name: "OFFSETDIST", scope: .application, defaultValue: .double(1.0),
                  validate: anyDouble,
                  help: "Default OFFSET distance (-1 = through-point mode)."),
    ]
}
