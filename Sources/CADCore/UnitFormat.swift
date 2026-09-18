import Foundation
import CoreGraphics

/// Unit system for decimal/scientific display. Architectural, engineering, and
/// fractional styles always work in inches (AutoCAD convention).
public enum UnitSystem: String, CaseIterable, Identifiable {
    case asDrawn, imperial, metric
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .asDrawn: return "As Drawn"
        case .imperial: return "Imperial (in)"
        case .metric: return "Metric (mm)"
        }
    }
}

/// Length display style, matching AutoCAD's UNITS command.
public enum LengthStyle: String, CaseIterable, Identifiable {
    case decimal, architectural, engineering, fractional, scientific
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .decimal: return "Decimal"
        case .architectural: return "Architectural"
        case .engineering: return "Engineering"
        case .fractional: return "Fractional"
        case .scientific: return "Scientific"
        }
    }
    /// True when the style expresses lengths in feet & inches (assumes the
    /// drawing unit is the inch).
    public var isFeetInches: Bool { self == .architectural || self == .engineering }
}

/// Formats drawing-unit lengths, areas, and angles for display. Value-typed so
/// it can travel into the renderer overlay and property lookups.
public struct MeasureFormat: Equatable {
    public var system: UnitSystem = .asDrawn
    public var style: LengthStyle = .decimal
    /// Decimal places (decimal/engineering/scientific) OR fraction-denominator
    /// exponent 0…6 → 1,1/2,…1/64 (architectural/fractional).
    public var precision: Int = 3
    /// The drawing's $INSUNITS code (0 = unitless/unknown).
    public var insUnits: Int = 0

    public init(system: UnitSystem = .asDrawn, style: LengthStyle = .decimal,
                precision: Int = 3, insUnits: Int = 0) {
        self.system = system
        self.style = style
        self.precision = precision
        self.insUnits = insUnits
    }

    // MARK: Unit scale

    /// Metres represented by one drawing unit, or nil if unknown.
    private var metresPerUnit: Double? {
        switch insUnits {
        case 1: return 0.0254            // inch
        case 2: return 0.3048            // foot
        case 3: return 1609.344          // mile
        case 4: return 0.001             // mm
        case 5: return 0.01              // cm
        case 6: return 1.0               // metre
        case 7: return 1000.0            // km
        case 8: return 0.0254e-6         // microinch
        case 9: return 0.0254e-3         // mil
        case 10: return 0.9144           // yard
        case 11: return 1e-10            // angstrom
        case 12: return 1e-9             // nanometre
        case 13: return 1e-6             // micron
        case 14: return 0.1              // decimetre
        case 15: return 10.0             // decametre
        case 16: return 100.0            // hectometre
        case 21: return 0.3048006096     // US survey foot
        default: return nil
        }
    }

    /// Drawing-unit suffix ("mm", "in", …) for as-drawn decimal display.
    public var drawnSuffix: String {
        [1: "in", 2: "ft", 3: "mi", 4: "mm", 5: "cm", 6: "m", 7: "km",
         9: "mil", 10: "yd", 13: "µm", 14: "dm"][insUnits] ?? ""
    }

    /// Inches per drawing unit (assumes inch when the unit is unknown).
    private var inchesPerUnit: Double {
        guard let m = metresPerUnit else { return 1 }
        return m / 0.0254
    }

    /// Converts a drawing-unit value to the chosen display unit + returns the
    /// suffix, for decimal/scientific styles.
    private func toDisplay(_ v: Double) -> (value: Double, suffix: String) {
        switch system {
        case .asDrawn:
            return (v, drawnSuffix)
        case .imperial:
            return (v * inchesPerUnit, "in")
        case .metric:
            guard let m = metresPerUnit else { return (v, "") }
            return (v * m * 1000.0, "mm")   // millimetres
        }
    }

    // MARK: Length

    public func length(_ value: CGFloat) -> String {
        let v = Double(value)
        switch style {
        case .architectural:
            return feetInchesFractional(inches: v * inchesPerUnit)
        case .engineering:
            return feetInchesDecimal(inches: v * inchesPerUnit)
        case .fractional:
            let d = toDisplay(v)
            return fractional(d.value) + suffixed(d.suffix)
        case .scientific:
            let d = toDisplay(v)
            return String(format: "%.\(clampDec)e", d.value) + suffixed(d.suffix)
        case .decimal:
            let d = toDisplay(v)
            return String(format: "%.\(clampDec)f", d.value) + suffixed(d.suffix)
        }
    }

    /// Area given a value already in (drawing units)². Reported as a decimal in
    /// the display unit squared (fractional areas are not idiomatic).
    public func area(_ value: CGFloat) -> String {
        let v = Double(value)
        let factor: Double
        let suffix: String
        switch (style.isFeetInches, system) {
        case (true, _):
            factor = inchesPerUnit * inchesPerUnit; suffix = "in²"
        case (false, .asDrawn):
            factor = 1; suffix = drawnSuffix.isEmpty ? "" : drawnSuffix + "²"
        case (false, .imperial):
            factor = inchesPerUnit * inchesPerUnit; suffix = "in²"
        case (false, .metric):
            let mm = (metresPerUnit ?? 1) * 1000.0
            factor = mm * mm; suffix = "mm²"
        }
        return String(format: "%.\(clampDec)f", v * factor) + suffixed(suffix)
    }

    public func angle(_ degrees: Double) -> String {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return String(format: "%.\(clampDec)f", d) + "°"
    }

    // MARK: Helpers

    private var clampDec: Int { min(max(precision, 0), 8) }
    private var denom: Int { 1 << min(max(precision, 0), 6) }   // 1…64
    private func suffixed(_ s: String) -> String { s.isEmpty ? "" : " " + s }

    private func feetInchesFractional(inches: Double) -> String {
        let neg = inches < 0
        var total = abs(inches)
        var feet = Int(total / 12)
        total -= Double(feet * 12)
        var whole = Int(total)
        var num = Int((total - Double(whole)) * Double(denom) + 0.5)
        if num >= denom { whole += 1; num = 0 }
        if whole >= 12 { feet += whole / 12; whole %= 12 }
        var s = "\(feet)'-\(whole)"
        if num > 0 {
            let g = gcd(num, denom)
            s += "-\(num / g)/\(denom / g)"
        }
        return (neg ? "-" : "") + s + "\""
    }

    private func feetInchesDecimal(inches: Double) -> String {
        let neg = inches < 0
        let total = abs(inches)
        let feet = Int(total / 12)
        let rem = total - Double(feet * 12)
        return (neg ? "-" : "") + "\(feet)'-" + String(format: "%.\(clampDec)f", rem) + "\""
    }

    private func fractional(_ v: Double) -> String {
        let neg = v < 0
        var total = abs(v)
        var whole = Int(total)
        total -= Double(whole)
        var num = Int(total * Double(denom) + 0.5)
        if num >= denom { whole += 1; num = 0 }
        var s = "\(whole)"
        if num > 0 {
            let g = gcd(num, denom)
            s = whole == 0 ? "\(num / g)/\(denom / g)" : "\(whole) \(num / g)/\(denom / g)"
        }
        return (neg ? "-" : "") + s
    }

    private func gcd(_ a: Int, _ b: Int) -> Int {
        var x = a, y = b
        while y != 0 { (x, y) = (y, x % y) }
        return max(1, x)
    }
}
