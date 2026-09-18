import Foundation
import CoreGraphics

public enum PackageLoadError: LocalizedError {
    case extractionFailed(String)
    case noDrawingFound

    public var errorDescription: String? {
        switch self {
        case .extractionFailed(let msg):
            return "Could not extract the ZIP archive: \(msg)"
        case .noDrawingFound:
            return "No DWG or DXF drawing was found in the selected package."
        }
    }
}

/// Opens a drawing together with its xrefs, AutoCAD eTransmit style.
///
/// Accepts a plain .dxf/.dwg (xrefs resolve against sibling files), a folder,
/// or an eTransmit .zip. Every unresolved xref BLOCK in the host is matched by
/// file basename against the package contents, scanned (recursively — nested
/// xrefs included), and transplanted into the host as the xref block's
/// content. Xref layers get AutoCAD-style "XREFNAME|layer" names so the layer
/// panel groups them, and the existing per-xref toggles control their
/// visibility.
public enum PackageLoader {

    public static let maxXrefFiles = 200
    public static let maxDepth = 8

    /// Hard ceiling on the raw merged-store entity count during xref
    /// resolution — a safety net INDEPENDENT of the de-dup below. Even a
    /// pathological drawing set (or one whose xrefs lack the `xrefPath`
    /// needed to de-dup by source) can never grow the store past this,
    /// bounding peak memory instead of the 16.5 GB / 65M-entity blowup a
    /// real-world factory overall layout produced before the de-dup existed
    /// (see the `resolveXrefsIntoStore` de-dup comment). That same layout
    /// de-dups to ~12.8M unique entities (~9 GB), so 16M leaves headroom for
    /// it while still capping true runaway nesting; a 731 MB single
    /// production file parses to only ~1.9M, far under.
    public static let maxMergedEntities = 16_000_000

    /// Records the host-store range a given SOURCE FILE's xref content was
    /// first merged into, so every later xref block referencing the SAME
    /// source (through any nesting path) can SHARE that range instead of
    /// re-parsing and re-copying it. See `resolveXrefsIntoStore`.
    private struct SharedXrefContent {
        var entityStart: Int32
        var entityCount: Int32
        var blockIndex: Int32
        var base: CGPoint
        var loadedPath: String
    }

    // MARK: - Entry

    public static func load(url: URL, progress: ((Double) -> Void)? = nil) throws -> DXFDocument {
        let t0 = Date()
        let fm = FileManager.default
        var mainURL = url
        var packageDir = url.deletingLastPathComponent()

        let ext = url.pathExtension.lowercased()
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: url.path, isDirectory: &isDir)

        // Temp dirs (zip extraction, batch conversion) are deleted once the
        // document is fully built — nothing references files afterwards.
        var tempDirs: [URL] = []
        defer { for d in tempDirs { try? fm.removeItem(at: d) } }

        // Only an explicit package (zip or folder) gets a deep recursive index
        // and up-front batch conversion. Opening one drawing must never crawl
        // or convert its whole parent directory tree.
        let deepPackage: Bool
        if ext == "zip" {
            let dest = fm.temporaryDirectory
                .appendingPathComponent("etransmit-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            try extractZip(url, to: dest)
            tempDirs.append(dest)
            packageDir = dest
            mainURL = try findMainDrawing(in: dest,
                                          hint: url.deletingPathExtension().lastPathComponent)
            deepPackage = true
        } else if isDir.boolValue {
            packageDir = url
            mainURL = try findMainDrawing(in: url, hint: url.lastPathComponent)
            deepPackage = true
        } else {
            deepPackage = false
        }
        progress?(0.02)

        var index = drawingIndex(in: packageDir, recursive: deepPackage)
        if deepPackage {
            let hasDWGs = mainURL.pathExtension.lowercased() == "dwg"
                || index.values.contains { $0.pathExtension.lowercased() == "dwg" }
            if hasDWGs, DWGConverter.anyConverterAvailable {
                let outDir = try DWGConverter.convertFolder(packageDir)
                tempDirs.append(outDir)
                for (name, dxf) in drawingIndex(in: outDir, recursive: true) {
                    index[name] = dxf   // converted DXFs supersede DWGs
                }
            }
            // DWG xrefs without a converter simply stay unresolved (flagged in UI).
        }
        if mainURL.pathExtension.lowercased() == "dwg" {
            let mainBase = mainURL.deletingPathExtension().lastPathComponent.lowercased()
            if deepPackage, let converted = index[mainBase],
               converted.pathExtension.lowercased() == "dxf" {
                mainURL = converted
            } else {
                mainURL = try DWGConverter.convertToDXF(url: mainURL)
            }
        }
        progress?(0.08)

        var raw = try DXFParser.scanRaw(url: mainURL) { p in
            progress?(0.08 + p * 0.5)
        }

        var filesLoaded = 0
        var convertedCache: [String: URL] = [:]
        resolveXrefs(into: &raw, index: index,
                     chain: [canonicalKey(mainURL), canonicalKey(url)], depth: 0,
                     filesLoaded: &filesLoaded, convertedCache: &convertedCache) { p in
            progress?(0.58 + p * 0.2)
        }
        let parseSeconds = Date().timeIntervalSince(t0)

        let doc = GeometryBuilder.build(from: &raw, parseSeconds: parseSeconds) { p in
            progress?(0.78 + p * 0.21)
        }
        // Persistent DXF sources support "Save Copy with Markup" — exclude
        // anything living in a temp dir we created (zip extractions,
        // conversions), which is deleted below.
        let tmpRoot = fm.temporaryDirectory.standardizedFileURL.path
        let mainPath = mainURL.standardizedFileURL.path
        if mainURL.pathExtension.lowercased() == "dxf",
           !mainPath.hasPrefix(tmpRoot),
           !tempDirs.contains(where: { mainPath.hasPrefix($0.standardizedFileURL.path) }) {
            doc.sourceDXFURL = mainURL
        }
        progress?(1.0)
        return doc
    }

    // MARK: - Xref resolution

    private static func resolveXrefs(into host: inout RawParseOutput,
                                     index: [String: URL],
                                     chain: Set<String>, depth: Int,
                                     filesLoaded: inout Int,
                                     convertedCache: inout [String: URL],
                                     progress: (Double) -> Void) {
        guard depth < maxDepth else { return }
        let xrefNames = host.blocks
            .filter { $0.value.isXref && $0.value.entities.isEmpty }
            .keys.sorted()

        for (i, name) in xrefNames.enumerated() {
            guard filesLoaded < maxXrefFiles, let block = host.blocks[name] else { continue }

            // Match by the xref path's basename first, then by the block name.
            var candidates: [String] = []
            if !block.xrefPath.isEmpty {
                let base = (block.xrefPath.replacingOccurrences(of: "\\", with: "/")
                    as NSString).lastPathComponent
                candidates.append((base as NSString).deletingPathExtension.lowercased())
            }
            candidates.append(name.lowercased())
            guard let sourceURL = candidates.compactMap({ index[$0] }).first else { continue }

            // Cycle detection keys on the SOURCE file (stable across lazy
            // conversions that produce fresh temp paths).
            let key = canonicalKey(sourceURL)
            guard !chain.contains(key) else { continue }   // circular reference

            var fileURL = sourceURL
            if fileURL.pathExtension.lowercased() == "dwg" {
                if let cached = convertedCache[key] {
                    fileURL = cached
                } else if let converted = try? DWGConverter.convertToDXF(url: fileURL) {
                    convertedCache[key] = converted
                    fileURL = converted
                } else {
                    continue   // no converter / conversion failed → stays unresolved
                }
            }

            guard var sub = try? DXFParser.scanRaw(url: fileURL, progress: { _ in })
            else { continue }
            filesLoaded += 1

            // Nested xrefs resolve within the same package.
            resolveXrefs(into: &sub, index: index,
                         chain: chain.union([key]), depth: depth + 1,
                         filesLoaded: &filesLoaded, convertedCache: &convertedCache) { _ in }

            merge(sub: sub, asContentOf: name, into: &host)
            host.blocks[name]?.wasResolved = true
            if depth == 0 { progress(Double(i + 1) / Double(max(1, xrefNames.count))) }
        }
    }

    /// Transplants a scanned xref file into the host: its model space becomes
    /// the xref block's content; its layers/linetypes/blocks merge in with
    /// AutoCAD-style dependent naming ("XREF|layer", "XREF$block").
    private static func merge(sub: RawParseOutput, asContentOf xrefName: String,
                              into host: inout RawParseOutput) {
        // ---- Layers: sub layer 0 keeps host layer 0; others get XREF|name ----
        var layerMap = [Int32: Int32]()
        for subLayer in sub.layers {
            if subLayer.id == 0 { layerMap[0] = 0; continue }
            let depName = "\(xrefName)|\(subLayer.name)"
            let hostId: Int32
            if let existing = host.layerIdByName[depName] {
                hostId = existing
            } else {
                hostId = Int32(host.layers.count)
                host.layers.append(DXFLayer(id: Int(hostId), name: depName,
                                            color: subLayer.color,
                                            linetypeId: 0,   // fixed up below
                                            isOffByDefault: subLayer.isOffByDefault,
                                            isFrozen: subLayer.isFrozen,
                                            entityCount: 0))
                host.layerIdByName[depName] = hostId
            }
            layerMap[Int32(subLayer.id)] = hostId
        }

        // ---- Linetypes: merge by name ----
        var ltMap = [Int16: Int16]()
        ltMap[-1] = -1; ltMap[-2] = -2
        for (subId, subLt) in sub.linetypes.enumerated() {
            let upper = subLt.name.uppercased()
            let hostId: Int16
            if let existing = host.linetypeIdByName[upper] {
                hostId = existing
            } else {
                hostId = Int16(host.linetypes.count)
                host.linetypes.append(subLt)
                host.linetypeIdByName[upper] = hostId
            }
            ltMap[Int16(subId)] = hostId
        }
        // Now fix the merged layers' linetype references.
        for subLayer in sub.layers where subLayer.id != 0 {
            let depName = "\(xrefName)|\(subLayer.name)"
            if let hostId = host.layerIdByName[depName] {
                let mapped = ltMap[Int16(subLayer.linetypeId)] ?? 0
                host.layers[Int(hostId)].linetypeId = Int(max(mapped, 0))
            }
        }

        // ---- Block names: XREF$name ----
        var blockNameMap = [String: String]()
        for (subName, _) in sub.blocks {
            let upper = subName.uppercased()
            guard !upper.hasPrefix("*MODEL_SPACE"), !upper.hasPrefix("*PAPER_SPACE"),
                  upper != "$MODEL_SPACE" else { continue }
            blockNameMap[subName] = "\(xrefName)$\(subName)"
        }

        func remap(_ entities: [RawEntity]) -> [RawEntity] {
            entities.map { e in
                var e = e
                e.layerId = layerMap[e.layerId] ?? 0
                if e.linetypeId >= 0 { e.linetypeId = ltMap[e.linetypeId] ?? 0 }
                if case .insert(var ins) = e.geom {
                    // Unconditional prefix: a dangling reference (definition
                    // missing from the xref file) must NOT bind to an unrelated
                    // host block of the same name — AutoCAD renders nothing.
                    ins.name = blockNameMap[ins.name] ?? "\(xrefName)$\(ins.name)"
                    e.geom = .insert(ins)
                }
                return e
            }
        }

        // ---- Content: sub model space (+ *Model_Space blocks) fills the xref block ----
        var content = sub.model
        for (subName, b) in sub.blocks {
            let upper = subName.uppercased()
            if upper.hasPrefix("*MODEL_SPACE") || upper == "$MODEL_SPACE" {
                content.append(contentsOf: b.entities)
            }
        }
        host.blocks[xrefName]?.entities = remap(content)
        host.blocks[xrefName]?.isXrefDependent = false   // the host-side block itself

        // ---- Transplant the sub file's block definitions ----
        for (subName, b) in sub.blocks {
            guard let newName = blockNameMap[subName] else { continue }
            let copy = BlockDef()
            copy.name = newName
            copy.base = b.base
            copy.flags = b.flags
            copy.xrefPath = b.xrefPath
            copy.entities = remap(b.entities)
            copy.isXrefDependent = true
            host.blocks[newName] = copy
        }

        host.totalEntities += sub.totalEntities
        for (k, v) in sub.skippedTypes { host.skippedTypes[k, default: 0] += v }
    }

    // MARK: - Package plumbing

    public static func canonicalKey(_ url: URL) -> String {
        url.standardizedFileURL.path.lowercased()
    }

    private static func extractZip(_ zip: URL, to dest: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dest.path]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        try p.run()
        let logData = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw PackageLoadError.extractionFailed(
                String(data: logData, encoding: .utf8) ?? "exit \(p.terminationStatus)")
        }
    }

    /// All drawings under `dir`, keyed by lowercased basename (no extension).
    /// DXF beats DWG for the same basename (converted output supersedes).
    public static func drawingIndex(in dir: URL, recursive: Bool = true) -> [String: URL] {
        var index = [String: URL]()
        let keys: [URLResourceKey] = [.isRegularFileKey]
        var options: FileManager.DirectoryEnumerationOptions =
            [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: keys,
            options: options) else { return index }
        for case let file as URL in walker {
            let ext = file.pathExtension.lowercased()
            guard ext == "dxf" || ext == "dwg" else { continue }
            let base = file.deletingPathExtension().lastPathComponent.lowercased()
            if let existing = index[base] {
                if existing.pathExtension.lowercased() == "dwg" && ext == "dxf" {
                    index[base] = file
                }
            } else {
                index[base] = file
            }
        }
        return index
    }

    /// Picks the main drawing of a package: prefer a file matching the
    /// package's own name, then a single root-level drawing, then the largest.
    public static func findMainDrawing(in dir: URL, hint: String) throws -> URL {
        let fm = FileManager.default
        func drawings(at url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                          options: [.skipsHiddenFiles])) ?? [])
                .filter { ["dxf", "dwg"].contains($0.pathExtension.lowercased()) }
        }

        // eTransmit ZIPs sometimes wrap everything in one folder — descend into it.
        var root = dir
        for _ in 0..<3 {
            let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])) ?? []
            if drawings(at: root).isEmpty, entries.count == 1,
               (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                root = entries[0]
            } else { break }
        }

        let rootDrawings = drawings(at: root)

        let hintLower = hint.lowercased()

        // AutoCAD eTransmit writes a report .txt named after the MAIN drawing —
        // the most reliable signal in a package full of xref DWGs. Guard against
        // stray .txt files: prefer a hint-matching candidate, and otherwise only
        // trust the heuristic when exactly one txt matches a drawing.
        if let reports = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) {
            var txtMatches: [URL] = []
            for report in reports.sorted(by: { $0.path < $1.path })
            where report.pathExtension.lowercased() == "txt" {
                let base = report.deletingPathExtension().lastPathComponent.lowercased()
                if let match = rootDrawings.first(where: {
                    $0.deletingPathExtension().lastPathComponent.lowercased() == base
                }) { txtMatches.append(match) }
            }
            if let hintPick = txtMatches.first(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased() == hintLower
            }) { return hintPick }
            if txtMatches.count == 1 { return txtMatches[0] }
        }

        if let match = rootDrawings.first(where: {
            $0.deletingPathExtension().lastPathComponent.lowercased() == hintLower
        }) { return match }
        if rootDrawings.count == 1 { return rootDrawings[0] }

        func size(_ u: URL) -> Int {
            (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        if let largest = rootDrawings.max(by: { size($0) < size($1) }) { return largest }

        // Nothing at root — search the whole tree.
        let all = Array(drawingIndex(in: root).values)
        if let match = all.first(where: {
            $0.deletingPathExtension().lastPathComponent.lowercased() == hintLower
        }) { return match }
        if let largest = all.max(by: { size($0) < size($1) }) { return largest }
        throw PackageLoadError.noDrawingFound
    }
}
