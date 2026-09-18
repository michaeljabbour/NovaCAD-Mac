import Foundation
import CoreGraphics
import CADCore

/// Writes user markup to DXF: either a standalone markup drawing (attachable
/// as an xref) or a full copy of the original DXF with the markup merged in.
enum DXFWriter {

    static let markupLayer = "NOVACAD-MARKUP"

    enum WriteError: LocalizedError {
        case sourceUnavailable
        case malformedSource(String)
        var errorDescription: String? {
            switch self {
            case .sourceUnavailable:
                return "The original DXF file is no longer available to merge into."
            case .malformedSource(let what):
                return "The original DXF has an unexpected structure (\(what)); cannot merge safely."
            }
        }
    }

    // MARK: - Entity records

    /// DXF group-code records for one drawn entity.
    /// `modern` = handles + subclass markers + LWPOLYLINE (for injecting into
    /// AC1015+ files); otherwise R12 flavor (no handles/subclasses,
    /// POLYLINE/VERTEX/SEQEND) — the most universally accepted standalone form.
    private static func records(for e: DrawnEntity, handle: UInt64,
                                modern: Bool) -> String {
        var out = ""
        func rec(_ code: Int, _ value: String) { out += "\(code)\n\(value)\n" }
        func num(_ v: CGFloat) -> String { String(format: "%.8f", Double(v)) }
        func common(_ type: String, _ subclass: String) {
            rec(0, type)
            if modern {
                rec(5, String(handle, radix: 16, uppercase: true))
                rec(100, "AcDbEntity")
            }
            rec(8, e.layerName)
            rec(62, String(e.aci))
            if e.isPaper { rec(67, "1") }
            if modern { rec(100, subclass) }
        }

        func polylineRecords(_ pts: [CGPoint], closed: Bool) {
            if modern {
                common("LWPOLYLINE", "AcDbPolyline")
                rec(90, String(pts.count))
                rec(70, closed ? "1" : "0")
                for p in pts { rec(10, num(p.x)); rec(20, num(p.y)) }
            } else {
                common("POLYLINE", "")
                rec(66, "1")
                rec(70, closed ? "1" : "0")
                rec(10, "0.0"); rec(20, "0.0"); rec(30, "0.0")
                for p in pts {
                    rec(0, "VERTEX")
                    rec(8, e.layerName)
                    rec(10, num(p.x)); rec(20, num(p.y)); rec(30, "0.0")
                }
                rec(0, "SEQEND")
                rec(8, e.layerName)
            }
        }

        switch e.shape {
        case .line(let a, let b):
            common("LINE", "AcDbLine")
            rec(10, num(a.x)); rec(20, num(a.y)); rec(30, "0.0")
            rec(11, num(b.x)); rec(21, num(b.y)); rec(31, "0.0")

        case .polyline(let pts, let closed):
            polylineRecords(pts, closed: closed)

        case .rect(let a, let b):
            polylineRecords([CGPoint(x: a.x, y: a.y), CGPoint(x: b.x, y: a.y),
                             CGPoint(x: b.x, y: b.y), CGPoint(x: a.x, y: b.y)],
                            closed: true)

        case .circle(let c, let r):
            common("CIRCLE", "AcDbCircle")
            rec(10, num(c.x)); rec(20, num(c.y)); rec(30, "0.0")
            rec(40, num(r))

        case .arc(let c, let r, let a1, let a2):
            common("ARC", "AcDbCircle")
            rec(10, num(c.x)); rec(20, num(c.y)); rec(30, "0.0")
            rec(40, num(r))
            if modern { out += "100\nAcDbArc\n" }
            rec(50, String(format: "%.8f", a1))
            rec(51, String(format: "%.8f", a2))

        case .text(let p, let h, let s):
            common("TEXT", "AcDbText")
            rec(10, num(p.x)); rec(20, num(p.y)); rec(30, "0.0")
            rec(40, num(h))
            let oneLine = s.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            rec(1, oneLine)
        }
        return out
    }

    private static func layerRecord(handle: UInt64, name: String, aci: Int) -> String {
        """
        0
        LAYER
        5
        \(String(handle, radix: 16, uppercase: true))
        100
        AcDbSymbolTableRecord
        100
        AcDbLayerTableRecord
        2
        \(name)
        70
        0
        62
        \(aci)
        6
        CONTINUOUS
        370
        -3

        """
    }

    // MARK: - Standalone markup DXF

    /// Writes ONLY the markup as a small self-contained DXF (attach it as an
    /// xref over the master drawing in AutoCAD). Written R12-style —
    /// entities-only, no handles or tables — the form AutoCAD accepts without
    /// requiring the full R2000+ table/objects skeleton; referenced layers are
    /// auto-created on import.
    static func writeMarkupDXF(_ entities: [DrawnEntity], to url: URL,
                               insUnits: Int = 0) throws {
        var out = ""
        if insUnits > 0 {
            out += "0\nSECTION\n2\nHEADER\n"
            out += "9\n$INSUNITS\n70\n\(insUnits)\n"
            out += "0\nENDSEC\n"
        }
        out += "0\nSECTION\n2\nENTITIES\n"
        for e in entities {
            out += records(for: e, handle: 0, modern: false)
        }
        out += "0\nENDSEC\n0\nEOF\n"

        try out.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    // MARK: - Merged copy of the original

    /// Copies the original ASCII DXF byte-for-byte, injecting the markup layer
    /// into the LAYER table and the drawn entities into the ENTITIES section,
    /// with fresh handles chained off the file's $HANDSEED.
    static func writeMergedCopy(original: URL, entities: [DrawnEntity],
                                to destination: URL) throws {
        let data = try Data(contentsOf: original, options: .mappedIfSafe)

        if data.prefix(18).elementsEqual("AutoCAD Binary DXF".utf8) {
            throw WriteError.malformedSource("binary DXF")
        }

        // ---- Pass 1: find injection offsets + $HANDSEED + existing layer names.
        var handseed: UInt64 = 0
        var maxHandleSeen: UInt64 = 0
        var handseedValueRange: Range<Int>? = nil
        var layerEndTabOffset: Int? = nil
        var entitiesEndSecOffset: Int? = nil
        var markupLayerExists = false

        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let bytes = buf.bindMemory(to: UInt8.self)
            let n = bytes.count
            var i = (n >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) ? 3 : 0
            var lineNo = 0
            var code = -9999
            var codeLineStart = 0

            var section = ""
            var table = ""
            var expectSection = false, expectTable = false
            var headerVar = ""
            var inLayerRecord = false

            func str(_ s: Int, _ e: Int) -> String {
                var st = s, en = e
                while st < en && bytes[st] == 0x20 { st += 1 }
                while en > st && (bytes[en - 1] == 0x20 || bytes[en - 1] == 0x0D) { en -= 1 }
                return String(decoding: UnsafeRawBufferPointer(rebasing: buf[st..<en]),
                              as: UTF8.self)
            }

            while i < n {
                var e = i
                while e < n && bytes[e] != 0x0A { e += 1 }
                var lineEnd = e
                if lineEnd > i && bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }

                if lineNo & 1 == 0 {
                    code = Int(str(i, lineEnd)) ?? -9999
                    codeLineStart = i
                } else {
                    let v = str(i, lineEnd)
                    if code == 0 || code == 9 {
                        let upper = v.uppercased()
                        if code == 9 { headerVar = upper }
                        else if upper == "SECTION" { expectSection = true }
                        else if upper == "ENDSEC" {
                            if section == "ENTITIES" && entitiesEndSecOffset == nil {
                                entitiesEndSecOffset = codeLineStart
                            }
                            section = ""
                        }
                        else if upper == "TABLE" { expectTable = true }
                        else if upper == "ENDTAB" {
                            if table == "LAYER" && layerEndTabOffset == nil {
                                layerEndTabOffset = codeLineStart
                            }
                            table = ""; inLayerRecord = false
                        }
                        else if upper == "LAYER" && table == "LAYER" { inLayerRecord = true }
                        else if upper == "EOF" { break }
                    } else if expectSection && code == 2 {
                        section = v.uppercased(); expectSection = false
                    } else if expectTable && code == 2 {
                        table = v.uppercased(); expectTable = false
                    } else if section == "HEADER", headerVar == "$HANDSEED", code == 5 {
                        handseed = UInt64(v, radix: 16) ?? handseed
                        handseedValueRange = i..<lineEnd
                        headerVar = ""
                    } else if code == 5 {
                        if let h = UInt64(v, radix: 16), h > maxHandleSeen {
                            maxHandleSeen = h
                        }
                    } else if inLayerRecord, code == 2,
                              v.uppercased() == markupLayer.uppercased() {
                        markupLayerExists = true
                    }
                }
                lineNo += 1
                i = e + 1
            }
        }

        guard let entEnd = entitiesEndSecOffset else {
            throw WriteError.malformedSource("no ENTITIES section found")
        }

        let needed = UInt64(entities.count) + (markupLayerExists ? 0 : 1) + 1
        var seedBase = max(max(handseed, maxHandleSeen &+ 1), 1)
        if seedBase > UInt64.max - needed - 16 { seedBase = UInt64.max - needed - 16 }
        var handle = seedBase

        var writeEntities = entities
        if layerEndTabOffset == nil {
            for i in writeEntities.indices { writeEntities[i].layerName = "0" }
        }

        var layerInjection = Data()
        if !markupLayerExists, layerEndTabOffset != nil {
            layerInjection = layerRecord(handle: handle, name: markupLayer, aci: 1)
                .data(using: .utf8)!
            handle += 1
        }
        var entityInjection = Data()
        for e in writeEntities {
            entityInjection += records(for: e, handle: handle, modern: true)
                .data(using: .utf8)!
            handle += 1
        }
        let newSeed = String(seedBase + needed, radix: 16, uppercase: true)

        var out = Data(capacity: data.count + entityInjection.count + 4096)
        var cursor = 0
        var points: [(offset: Int, payload: Data, replaceLen: Int)] = []
        if let r = handseedValueRange {
            points.append((r.lowerBound, newSeed.data(using: .utf8)!, r.count))
        }
        if let lt = layerEndTabOffset, !layerInjection.isEmpty {
            points.append((lt, layerInjection, 0))
        }
        points.append((entEnd, entityInjection, 0))
        points.sort { $0.offset < $1.offset }

        for p in points {
            out.append(data.subdata(in: cursor..<p.offset))
            out.append(p.payload)
            cursor = p.offset + p.replaceLen
        }
        out.append(data.subdata(in: cursor..<data.count))
        try out.write(to: destination, options: .atomic)
    }
}