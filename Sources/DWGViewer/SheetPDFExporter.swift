import Foundation
import CoreGraphics
import CADCore

struct SheetPageSetup {
    var widthMM: Double = 420
    var heightMM: Double = 297
    var leftMM: Double = 0
    var bottomMM: Double = 0
    var rightMM: Double = 0
    var topMM: Double = 0
    var originXMM: Double = 0
    var originYMM: Double = 0
    var unitsMM: Double = 1
    var scale: Double = 1
    var rotation = 0
    var hasStoredSize = false
    var styleSheet: String?

    init(layout: LayoutObject?) {
        guard let layout else { return }
        var inPlot = false
        var pairs: [RawGroupPair] = []
        for pair in layout.rawPairs {
            if pair.code == 100, case .string(let name) = pair.value { inPlot = name == "AcDbPlotSettings" }
            else if inPlot { pairs.append(pair) }
        }
        func number(_ code: Int32) -> Double? {
            guard let value = pairs.first(where: { $0.code == code })?.value else { return nil }
            switch value { case .double(let n): return n; case .int(let n): return Double(n); default: return nil }
        }
        if let w = number(44), let h = number(45), w > 0, h > 0, w.isFinite, h.isFinite {
            widthMM = w; heightMM = h; hasStoredSize = true
        }
        leftMM = number(40) ?? 0; bottomMM = number(41) ?? 0
        rightMM = number(42) ?? 0; topMM = number(43) ?? 0
        originXMM = number(46) ?? 0; originYMM = number(47) ?? 0
        unitsMM = number(72) == 0 ? 25.4 : 1
        rotation = Int(number(73) ?? 0)
        if let numerator = number(142), let denominator = number(143), numerator > 0, denominator > 0 {
            scale = numerator / denominator
        } else if let standard = number(147), standard > 0 { scale = standard }
        if let value = pairs.first(where: { $0.code == 7 })?.value, case .string(let name) = value, !name.isEmpty { styleSheet = name }
    }
    var pageSize: CGSize {
        let rotated = rotation == 1 || rotation == 3
        return CGSize(width: (rotated ? heightMM : widthMM) * 72 / 25.4,
                      height: (rotated ? widthMM : heightMM) * 72 / 25.4)
    }
}

enum PDFScale: String, CaseIterable, Identifiable {
    case pageSetup = "Drawing page setup", fit = "Fit to page", actual = "1:1", fifty = "1:50", hundred = "1:100"
    var id: String { rawValue }
}
enum PDFPaper: String, CaseIterable, Identifiable {
    case drawing = "From drawing (A3 if unspecified)", a4 = "A4 landscape", a3 = "A3 landscape"
    case letter = "US Letter landscape", tabloid = "US Tabloid landscape", archD = "ARCH D landscape"
    var id: String { rawValue }
    var millimeters: CGSize? {
        switch self {
        case .drawing: return nil
        case .a4: return CGSize(width: 297, height: 210)
        case .a3: return CGSize(width: 420, height: 297)
        case .letter: return CGSize(width: 279.4, height: 215.9)
        case .tabloid: return CGSize(width: 431.8, height: 279.4)
        case .archD: return CGSize(width: 914.4, height: 609.6)
        }
    }
}
struct PDFExportOptions {
    /// nil is model space; named sheets use their stable BLOCK_RECORD ids.
    var sheets: [UInt64?]
    var paper: PDFPaper = .drawing
    var scale: PDFScale = .pageSetup
    var visibility = VisibilityState()
}

enum SheetPDFExporter {
    static func transform(bounds: CGRect, setup: SheetPageSetup, mode: PDFScale) -> CGAffineTransform {
        let pointsPerMM = 72.0 / 25.4
        let page = setup.pageSize
        if mode == .fit {
            let margin = 10 * pointsPerMM
            let scale = min(max(1, page.width - 2 * margin) / max(bounds.width, 1e-9),
                            max(1, page.height - 2 * margin) / max(bounds.height, 1e-9))
            return CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                tx: page.width / 2 - bounds.midX * scale, ty: page.height / 2 + bounds.midY * scale)
        }
        let ratio: Double
        switch mode { case .fifty: ratio = 1 / 50; case .hundred: ratio = 1 / 100; case .actual: ratio = 1; default: ratio = setup.scale }
        let s = setup.unitsMM * pointsPerMM * ratio
        var t = CGAffineTransform(a: s, b: 0, c: 0, d: s,
            tx: (setup.leftMM + setup.originXMM) * pointsPerMM,
            ty: (setup.bottomMM + setup.originYMM) * pointsPerMM)
        let w = setup.widthMM * pointsPerMM, h = setup.heightMM * pointsPerMM
        switch setup.rotation {
        case 1: t = t.concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0))
        case 2: t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h))
        case 3: t = t.concatenating(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w))
        default: break
        }
        return t.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: page.height))
    }

    static func write(_ parsed: EditableParsedDocument, to destination: URL, options: PDFExportOptions,
                      progress: (Int, Int) -> Void = { _, _ in }) throws -> [String] {
        guard !options.sheets.isEmpty else { throw exportError("Choose at least one sheet.") }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".novacad-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let consumer = CGDataConsumer(url: temporary as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, [kCGPDFContextCreator: "NovaCAD"] as CFDictionary) else {
            throw exportError("Could not create the PDF.")
        }
        let original = parsed.activePaperLayoutID
        defer { parsed.activePaperLayoutID = original }
        var warnings = Set<String>()
        for (index, id) in options.sheets.enumerated() {
            if let id, !parsed.paperLayouts.contains(where: { $0.id == id }) { throw exportError("The selected sheet no longer exists.") }
            parsed.activePaperLayoutID = id
            let document = Regenerator.build(from: parsed, parseSeconds: 0, progress: { _ in })
            let sheet = parsed.paperLayouts.first { $0.id == id }
            let layout = parsed.objects.layouts.values.first { $0.name == sheet?.name }
            var setup = SheetPageSetup(layout: layout)
            if let size = options.paper.millimeters { setup.widthMM = size.width; setup.heightMM = size.height; setup.rotation = 0 }
            if id == nil {
                setup.unitsMM = [1: 25.4, 2: 304.8, 4: 1, 5: 10, 6: 1000][parsed.insUnits] ?? 1
                if parsed.insUnits == 0 && options.scale != .fit { warnings.insert("Model units are unspecified; exported as millimeters.") }
            }
            guard setup.pageSize.width.isFinite, setup.pageSize.height.isFinite,
                  setup.pageSize.width > 0, setup.pageSize.height > 0,
                  setup.pageSize.width <= 20000, setup.pageSize.height <= 20000 else { throw exportError("Invalid or excessive paper dimensions.") }
            if !setup.hasStoredSize && options.paper == .drawing { warnings.insert("A3 landscape was used where no paper size was stored.") }
            if setup.styleSheet != nil { warnings.insert("CTB/STB plot styles are not applied; drawing colors and lineweights are used.") }
            var box = CGRect(origin: .zero, size: setup.pageSize)
            let data = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: data] as CFDictionary)
            let bounds = id == nil ? document.modelBounds : document.paperBounds
            var params = RenderParams()
            params.viewSize = setup.pageSize; params.backingScale = 1; params.darkBackground = false
            params.vectorOutput = true; params.quality = 5; params.usePaperSpace = id != nil
            params.visibility = options.visibility
            params.worldToView = transform(bounds: bounds, setup: setup, mode: options.scale)
            params.zoom = hypot(params.worldToView.a, params.worldToView.b)
            if !bounds.isNull && !bounds.isEmpty {
                if !CGRect(origin: .zero, size: setup.pageSize).contains(bounds.applying(params.worldToView)) && options.scale != .fit {
                    warnings.insert("\(sheet?.name ?? "Model"): content extends beyond the page at the selected scale. Use Fit to page if needed.")
                }
                CGRenderCore.draw(into: context, document: document, params: params)
            }
            context.endPDFPage()
            warnings.formUnion(document.renderingWarnings)
            progress(index + 1, options.sheets.count)
        }
        context.closePDF()
        if rename(temporary.path, destination.path) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return warnings.sorted()
    }
    private static func exportError(_ message: String) -> NSError {
        NSError(domain: "NovaCAD.PDF", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
