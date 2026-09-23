import Foundation

public enum DWGConversionError: LocalizedError {
    case converterNotFound
    case conversionFailed(String)
    case noOutputProduced

    public var errorDescription: String? {
        switch self {
        case .converterNotFound:
            return """
            No DWG converter was found. Install the free ODA File Converter from \
            https://www.opendesign.com/guestfiles/oda_file_converter (best fidelity), \
            or GNU LibreDWG via Homebrew (`brew install libredwg`), then try again.
            """
        case .conversionFailed(let msg):
            return "DWG → DXF conversion failed: \(msg)"
        case .noOutputProduced:
            return "The converter ran but produced no DXF output."
        }
    }
}

public struct DWGConverter {

    public init() {}


    /// Common install locations for the ODA File Converter CLI binary on macOS.
    private static let candidatePaths = [
        "/Applications/ODAFileConverter.app/Contents/MacOS/ODAFileConverter",
        "/Applications/ODAFileConverter 25.4.0.app/Contents/MacOS/ODAFileConverter",
        "/Applications/ODAFileConverter 24.0.0.app/Contents/MacOS/ODAFileConverter"
    ]

    public static func locateConverter() -> String? {
        // Exact known paths first.
        for p in candidatePaths where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        // Fallback: any ODAFileConverter*.app in /Applications.
        if let apps = try? FileManager.default.contentsOfDirectory(atPath: "/Applications") {
            for app in apps where app.hasPrefix("ODAFileConverter") && app.hasSuffix(".app") {
                let p = "/Applications/\(app)/Contents/MacOS/ODAFileConverter"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    /// GNU LibreDWG's dwg2dxf (Homebrew) — fallback when ODA isn't installed.
    public static func locateLibreDWG() -> String? {
        for p in ["/opt/homebrew/bin/dwg2dxf", "/usr/local/bin/dwg2dxf"]
        where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    public static var anyConverterAvailable: Bool {
        locateConverter() != nil || locateLibreDWG() != nil
    }

    /// Runs the ODA File Converter via LaunchServices with its GUI hidden.
    ///
    /// The converter is a Qt app whose progress window pops up over NovaCAD
    /// when the binary is exec'd directly, and its bundle ships only the cocoa
    /// Qt platform plugin, so `QT_QPA_PLATFORM=offscreen` cannot suppress the
    /// window. `open -n -W -j -g` launches the app hidden (-j) without
    /// activating it (-g) and waits for it to exit (-W). LaunchServices does
    /// not surface the app's exit code, so callers must judge success by the
    /// presence of output files; the returned combined stdout+stderr log and
    /// ODA's `.err` sidecar files carry the failure detail.
    private static func runConverterHidden(binary: String, arguments: [String],
                                           logDir: URL) throws -> String {
        let fm = FileManager.default
        let appBundle = URL(fileURLWithPath: binary)
            .deletingLastPathComponent()   // MacOS
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // ODAFileConverter*.app
        let outLog = logDir.appendingPathComponent(".oda-out-\(UUID().uuidString).log")
        let errLog = logDir.appendingPathComponent(".oda-err-\(UUID().uuidString).log")

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // Qt can activate itself even after LaunchServices starts it hidden.
        // Scope both controls to this converter process, never global defaults.
        // See Qt cocoa qcocoaintegration.mm and qcocoawindow.mm.
        open.arguments = ["-n", "-W", "-j", "-g",
                          "--env", "QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM=1",
                          "--env", "QT_MAC_SET_RAISE_PROCESS=0",
                          "--stdout", outLog.path, "--stderr", errLog.path,
                          "-a", appBundle.path, "--args"] + arguments
        // This pipe captures `open`'s own launch errors; the converter's output
        // goes to the log files above.
        let pipe = Pipe()
        open.standardError = pipe
        open.standardOutput = pipe
        try open.run()
        let openLog = pipe.fileHandleForReading.readDataToEndOfFile()
        open.waitUntilExit()

        var log = ""
        for f in [outLog, errLog] {
            if let d = fm.contents(atPath: f.path),
               let s = String(data: d, encoding: .utf8) { log += s }
            try? fm.removeItem(at: f)
        }
        guard open.terminationStatus == 0 else {
            let msg = String(data: openLog, encoding: .utf8) ?? ""
            throw DWGConversionError.conversionFailed(
                "could not launch ODA File Converter: "
                + (msg.isEmpty ? "open exit \(open.terminationStatus)" : msg))
        }
        return log
    }

    /// ODA writes a `<name>.err` sidecar next to outputs when a drawing fails;
    /// collect their contents (recursively) for error messages.
    private static func odaErrorSidecars(in dir: URL) -> String {
        let fm = FileManager.default
        var parts: [String] = []
        let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil)
        while case let file as URL = walker?.nextObject() {
            guard file.pathExtension.lowercased() == "err" else { continue }
            if let d = fm.contents(atPath: file.path),
               let s = String(data: d, encoding: .utf8), !s.isEmpty {
                parts.append(s)
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Converts every .dwg under `folder` (recursively) to DXF. Prefers ODA's
    /// native batch mode (best fidelity); falls back to looping GNU LibreDWG's
    /// dwg2dxf per file. Returns the output directory. Individual LibreDWG
    /// failures are tolerated — those drawings simply stay unresolved.
    public static func convertFolder(_ folder: URL) throws -> URL {
        let fm = FileManager.default
        let outDir = fm.temporaryDirectory
            .appendingPathComponent("dwgconv-batch-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        if let converter = locateConverter() {
            // <in> <out> <outVer> <outType> <recurse:1> <audit:1> [filter]
            let log = try runConverterHidden(
                binary: converter,
                arguments: [folder.path, outDir.path, "ACAD2018", "DXF", "1", "1", "*.DWG"],
                logDir: outDir)

            // Hidden LaunchServices launch hides the exit code: an entirely
            // empty output tree is the batch-failure signal. Per-file failures
            // leave .err sidecars and are tolerated — PackageLoader flags
            // those drawings as unresolved. (convertFolder is only called
            // when the package contains at least one DWG.)
            let anyDXF = (fm.enumerator(at: outDir, includingPropertiesForKeys: nil)?
                .allObjects.compactMap { $0 as? URL }
                .contains { $0.pathExtension.lowercased() == "dxf" }) ?? false
            guard anyDXF else {
                let detail = [odaErrorSidecars(in: outDir), log]
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                throw DWGConversionError.conversionFailed(
                    detail.isEmpty ? "converter produced no DXF output"
                                   : String(detail.suffix(600)))
            }
            return outDir
        }

        if let dwg2dxf = locateLibreDWG() {
            let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil,
                                       options: [.skipsHiddenFiles])
            while case let file as URL = walker?.nextObject() {
                guard file.pathExtension.lowercased() == "dwg" else { continue }
                let out = outDir.appendingPathComponent(
                    file.deletingPathExtension().lastPathComponent + ".dxf")
                // First-wins on duplicate basenames across subfolders — matches
                // drawingIndex's collision rule (flattened output can collide).
                guard !fm.fileExists(atPath: out.path) else { continue }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: dwg2dxf)
                p.arguments = ["-y", "--as", "r2000", "-o", out.path, file.path]
                let pipe = Pipe()
                p.standardError = pipe
                p.standardOutput = pipe
                try? p.run()
                _ = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                // Tolerate per-file failures; PackageLoader flags the gaps.
            }
            return outDir
        }

        throw DWGConversionError.converterNotFound
    }

    /// Converts a .dwg at `url` to a .dxf and returns the resulting file URL.
    /// Runs off the main thread; call from a background Task.
    public static func convertToDXF(url: URL) throws -> URL {
        guard let converter = locateConverter() else {
            // Fall back to LibreDWG for single files too.
            if let dwg2dxf = locateLibreDWG() {
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".dxf")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: dwg2dxf)
                p.arguments = ["-y", "--as", "r2000", "-o", out.path, url.path]
                let pipe = Pipe()
                p.standardError = pipe
                p.standardOutput = pipe
                try p.run()
                let logData = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard FileManager.default.fileExists(atPath: out.path) else {
                    let log = String(data: logData, encoding: .utf8) ?? ""
                    throw DWGConversionError.conversionFailed(
                        log.isEmpty ? "dwg2dxf exit \(p.terminationStatus)" : String(log.suffix(400)))
                }
                return out
            }
            throw DWGConversionError.converterNotFound
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("dwgconv-\(UUID().uuidString)", isDirectory: true)
        let inDir = work.appendingPathComponent("in", isDirectory: true)
        let outDir = work.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: inDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        // Stage the DWG into the input folder.
        let staged = inDir.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
        try fm.copyItem(at: url, to: staged)

        // ODAFileConverter <in> <out> <outVer> <outType> <recurse> <audit> [filter]
        //   outVer:  ACAD2018  |  outType: DXF  |  recurse: 0  |  audit: 1
        let log = try runConverterHidden(
            binary: converter,
            arguments: [inDir.path, outDir.path, "ACAD2018", "DXF", "0", "1", "*.DWG"],
            logDir: work)

        // Find the produced .dxf. (The hidden launch hides the exit code, so
        // output presence is the success signal; .err sidecars carry detail.)
        let produced = (try? fm.contentsOfDirectory(at: outDir,
                                                    includingPropertiesForKeys: nil))?
            .first { $0.pathExtension.lowercased() == "dxf" }

        guard let dxf = produced else {
            let detail = [odaErrorSidecars(in: outDir), log]
                .filter { !$0.isEmpty }.joined(separator: "\n")
            if detail.isEmpty { throw DWGConversionError.noOutputProduced }
            throw DWGConversionError.conversionFailed(String(detail.suffix(600)))
        }

        // Move to a stable temp location so the work dir can be cleaned up.
        let final = fm.temporaryDirectory
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".dxf")
        if fm.fileExists(atPath: final.path) { try? fm.removeItem(at: final) }
        try fm.moveItem(at: dxf, to: final)
        try? fm.removeItem(at: work)

        return final
    }

    // MARK: - Cache-aware conversion (persistent, cross-session)

    /// Like `convertFolder`, but writes converted DXFs into a PERSISTENT cache
    /// bucket (`DWGCache`) and re-converts only the DWGs whose source changed
    /// since last time. Returns the bucket directory (whose DXFs the caller
    /// folds into its drawing index exactly like `convertFolder`'s temp dir).
    ///
    /// The relative source subtree is preserved inside the bucket so two DWGs
    /// with the same basename in different subfolders never collide.
    public static func convertFolderCached(_ folder: URL, bucket: URL) throws -> URL {
        let fm = FileManager.default
        let converterId = DWGCache.currentConverterId()
        var manifest = DWGCache.loadManifest(in: bucket)

        // Enumerate all source DWGs and split into fresh (reuse) vs stale (convert).
        var stale: [(source: URL, rel: String)] = []
        let base = folder.standardizedFileURL.path
        let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                   options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while case let file as URL = walker?.nextObject() {
            guard file.pathExtension.lowercased() == "dwg" else { continue }
            let rel = relativePath(of: file, under: base)
            if DWGCache.isFresh(source: file, relativeKey: rel, bucket: bucket,
                                manifest: manifest, converter: converterId) {
                continue   // cached DXF is still valid — reuse it
            }
            stale.append((file, rel))
        }

        // Everything already cached: instant path.
        if stale.isEmpty { return bucket }

        // Convert the stale DWGs. Stage them (relative tree preserved) into a
        // temp input dir, run one batch conversion, then move outputs into the
        // persistent bucket and record freshness.
        let work = fm.temporaryDirectory
            .appendingPathComponent("dwgconv-cache-\(UUID().uuidString)", isDirectory: true)
        let inDir = work.appendingPathComponent("in", isDirectory: true)
        let outDir = work.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: inDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        for item in stale {
            let staged = inDir.appendingPathComponent(item.rel)
            try? fm.createDirectory(at: staged.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if fm.fileExists(atPath: staged.path) { try? fm.removeItem(at: staged) }
            try? fm.copyItem(at: item.source, to: staged)
        }

        if let converter = locateConverter() {
            _ = try runConverterHidden(
                binary: converter,
                arguments: [inDir.path, outDir.path, "ACAD2018", "DXF", "1", "1", "*.DWG"],
                logDir: work)
        } else if let dwg2dxf = locateLibreDWG() {
            for item in stale {
                let src = inDir.appendingPathComponent(item.rel)
                let out = outDir.appendingPathComponent(
                    (item.rel as NSString).deletingPathExtension + ".dxf")
                try? fm.createDirectory(at: out.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: dwg2dxf)
                p.arguments = ["-y", "--as", "r2000", "-o", out.path, src.path]
                let pipe = Pipe(); p.standardError = pipe; p.standardOutput = pipe
                try? p.run()
                _ = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
            }
        } else {
            throw DWGConversionError.converterNotFound
        }

        // Harvest produced DXFs into the persistent bucket by matching basenames
        // back to each stale source's relative location, and record freshness.
        let producedByBase = indexDXFsByBasename(in: outDir)
        for item in stale {
            let baseName = (item.rel as NSString).lastPathComponent
            let stem = (baseName as NSString).deletingPathExtension.lowercased()
            guard let produced = producedByBase[stem] else { continue }   // per-file failure tolerated
            let destRel = (item.rel as NSString).deletingPathExtension + ".dxf"
            let dest = bucket.appendingPathComponent(destRel)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            do {
                try fm.moveItem(at: produced, to: dest)
            } catch {
                try? fm.copyItem(at: produced, to: dest)
            }
            if let st = DWGCache.stat(item.source) {
                manifest[item.rel] = DWGCache.Entry(size: st.size, mtime: st.mtime,
                                                    dxfRelPath: destRel, converter: converterId)
            }
        }
        DWGCache.saveManifest(manifest, in: bucket)
        return bucket
    }

    /// Single-file cache-aware conversion for the lazy per-xref fallback.
    /// Reuses the cached DXF if the source is unchanged; otherwise converts and
    /// records it. `bucket` is the package's `DWGCache` bucket.
    public static func convertToDXFCached(url: URL, bucket: URL) throws -> URL {
        let fm = FileManager.default
        let converterId = DWGCache.currentConverterId()
        var manifest = DWGCache.loadManifest(in: bucket)
        // Key single-file conversions by absolute path hash to avoid collisions
        // with folder-relative keys and across different source locations.
        let key = "abs:" + DWGCache.sha256Hex(url.standardizedFileURL.path)
        if DWGCache.isFresh(source: url, relativeKey: key, bucket: bucket,
                            manifest: manifest, converter: converterId),
           let entry = manifest[key] {
            return bucket.appendingPathComponent(entry.dxfRelPath)
        }

        let produced = try convertToDXF(url: url)   // reuse the proven single-file path
        let destRel = "single/" + url.deletingPathExtension().lastPathComponent + "-"
            + String(DWGCache.sha256Hex(url.standardizedFileURL.path).prefix(8)) + ".dxf"
        let dest = bucket.appendingPathComponent(destRel)
        try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        do { try fm.moveItem(at: produced, to: dest) }
        catch { try? fm.copyItem(at: produced, to: dest) }
        if let st = DWGCache.stat(url) {
            manifest[key] = DWGCache.Entry(size: st.size, mtime: st.mtime,
                                           dxfRelPath: destRel, converter: converterId)
            DWGCache.saveManifest(manifest, in: bucket)
        }
        return dest
    }

    // MARK: - Path helpers

    /// `file`'s path relative to `base` (a standardized directory path),
    /// falling back to the last path component if it isn't actually under base.
    private static func relativePath(of file: URL, under base: String) -> String {
        let full = file.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        if full.hasPrefix(prefix) { return String(full.dropFirst(prefix.count)) }
        return file.lastPathComponent
    }

    /// Maps lowercased DXF basename (no extension) → URL for every DXF under
    /// `dir`. First-wins on collisions (matches drawingIndex's rule).
    private static func indexDXFsByBasename(in dir: URL) -> [String: URL] {
        let fm = FileManager.default
        var index: [String: URL] = [:]
        let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil)
        while case let file as URL = walker?.nextObject() {
            guard file.pathExtension.lowercased() == "dxf" else { continue }
            let stem = file.deletingPathExtension().lastPathComponent.lowercased()
            if index[stem] == nil { index[stem] = file }
        }
        return index
    }
}
