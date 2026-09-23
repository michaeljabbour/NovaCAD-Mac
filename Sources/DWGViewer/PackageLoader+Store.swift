import Foundation
import CoreGraphics
import CADCore

// MARK: - EntityStore parsing path (stayed in NovaCAD per Option B)
//
// WS-N2 fix: the CADCore extraction (commit dacafda) replaced this file's
// original `loadIntoStore` — which fully resolved xrefs into the
// `EntityStore`, matching `PackageLoader.load`'s (CADCore's render-only
// path) xref handling exactly — with a stub that just calls
// `EntityStoreParser.parse` on the main file and returns, silently dropping
// ALL xref resolution for the EntityStore/Regenerator path used by the live
// app's real "Open File" flow (`RegenCoordinator.loadPackage`). That
// regression is what `XrefMergeTests`, `MarkupStoreTests
// .testLoadPackageResolvesXrefs`, and `RoundTripTests
// .testResolvedXrefBlockContentSurvivesRoundTrip` were catching. This
// restores the original package/xref-resolution logic (package plumbing —
// zip/folder handling, DWG batch conversion, xref merge with AutoCAD
// dependent naming) verbatim from the pre-extraction implementation. All the
// types this needs (`EditableParsedDocument`, `EditableBlockDef`,
// `OwnerRef`, `EntityStore.appendCopy`) live in NovaCAD's own
// EntityStore.swift/EntityStoreParser.swift — none of this required a
// CADCore change.

enum PackageLoadStoreError: LocalizedError {
    case extractionFailed(String)
    case noDrawingFound
    /// The caller's `isCancelled` polling closure returned true (a user
    /// clicked "Cancel" on the loading UI). Carries no message of its own
    /// — callers must special-case this rather than surfacing it through
    /// the ordinary error-alert path, since a user-initiated abort is not
    /// a failure.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .extractionFailed(let msg):
            return "Could not extract the ZIP archive: \(msg)"
        case .noDrawingFound:
            return "No DWG or DXF drawing was found in the selected package."
        case .cancelled:
            return "Loading was cancelled."
        }
    }
}

extension PackageLoader {

    static let storeMaxXrefFiles = 200

    /// Hard ceiling on the raw merged-store entity count during xref
    /// resolution — a safety net independent of the source-level de-dup
    /// below. See `CADCore.PackageLoader.maxMergedEntities`'s doc comment
    /// for the real-production-layout motivation; mirrored here since that
    /// constant isn't `public` in CADCore.
    static let storeMaxMergedEntities = 16_000_000

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

    /// One xref-resolution progress tick — richer than a bare fraction so
    /// the loading UI can show WHICH file is being merged, not just a
    /// number that (before the O(n²) `children(of:)` fix — see
    /// `EntityStore.childrenByParent()`'s doc comment) could sit motionless
    /// for hours on a single large xref with no indication anything was
    /// still happening. `fileName` is nil for ticks that aren't
    /// file-granular (e.g. the initial/final fractions).
    struct XrefProgress {
        var fraction: Double
        var fileName: String?
        var fileIndex: Int
        var fileTotal: Int
    }

    /// Opens a .dxf/.dwg (or a folder/eTransmit .zip package) and returns an
    /// `EditableParsedDocument` (EntityStore path) with every xref BLOCK
    /// resolved — the store-level equivalent of `PackageLoader.load`.
    ///
    /// `isCancelled` is polled between merge-eligible units of work (each
    /// top-level xref file, plus each chunk of the main-file parse) so a
    /// user can abort an unexpectedly huge package instead of waiting out a
    /// load that — even after the O(n²) merge fix — can still legitimately
    /// take minutes on a multi-hundred-MB, multi-xref eTransmit package.
    /// Returns `PackageLoadStoreError.cancelled` when it fires; callers
    /// should treat that as a normal user-initiated abort, not a failure to
    /// report as an error alert.
    static func loadIntoStore(url: URL,
                              isCancelled: (() -> Bool)? = nil,
                              xrefProgress: ((XrefProgress) -> Void)? = nil,
                              drawingIndexer: (URL, Bool) -> [String: URL] = {
                                  PackageLoader.drawingIndex(in: $0, recursive: $1)
                              },
                              progress: ((Double) -> Void)? = nil) throws -> EditableParsedDocument {
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

        // Cancellation is polled at each of the coarse stage boundaries
        // below (zip extract, DWG batch conversion, main-file parse,
        // each individual xref file) — the granularity that matters, since
        // those are the units of work a user actually waits through on a
        // large eTransmit package. The byte-level DXF scan itself
        // (`EntityStoreParser`/`scanIntoStore`) is NOT interrupted
        // mid-file: it mirrors CADCore's own scanner algorithmically (see
        // this file's header comment) and AGENTS.md flags it as
        // performance/correctness-sensitive, so this deliberately doesn't
        // thread cancellation into its inner loop — a single file's parse
        // is bounded (seconds, not the hours the O(n²) merge used to take)
        // and finishes before the next cancellation check fires.
        func checkCancelled() throws {
            if isCancelled?() == true { throw PackageLoadStoreError.cancelled }
        }

        // Only an explicit package (zip or folder) gets a deep recursive
        // index and up-front batch conversion. Opening one drawing must
        // never crawl or convert its whole parent directory tree.
        let deepPackage: Bool
        if ext == "zip" {
            let dest = fm.temporaryDirectory
                .appendingPathComponent("etransmit-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            try extractZip(url, to: dest)
            tempDirs.append(dest)
            packageDir = dest
            mainURL = try findMainDrawingStore(in: dest,
                                                hint: url.deletingPathExtension().lastPathComponent)
            deepPackage = true
        } else if isDir.boolValue {
            packageDir = url
            mainURL = try findMainDrawingStore(in: url, hint: url.lastPathComponent)
            deepPackage = true
        } else {
            deepPackage = false
        }
        progress?(0.02)
        try checkCancelled()

        // Persistent DWG→DXF cache: for a folder/zip package, converted DXFs
        // land in a stable per-package bucket and only changed DWGs
        // re-convert on re-open. Disabled (or non-deep single-file opens)
        // fall back to the original temp-dir conversion, cleaned up via
        // `tempDirs`. `DWGCache.isEnabled` itself is `internal` to CADCore
        // (not `public`), so this reads the exact same UserDefaults key
        // CADCore's own `DWGCache.isEnabled` getter reads, mirroring its
        // "default ON" semantics without needing a CADCore API change.
        let dwgCacheEnabled: Bool = {
            if UserDefaults.standard.object(forKey: "dwgCacheEnabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "dwgCacheEnabled")
        }()
        let cacheBucket: URL? = (deepPackage && dwgCacheEnabled)
            ? DWGCache.bucket(forPackage: packageDir) : nil

        // Finder grants access to the selected file, not necessarily its
        // parent folder. Avoid triggering a folder-access prompt for drawings
        // that have no external references to resolve.
        var index = deepPackage ? drawingIndexer(packageDir, true) : [:]
        if deepPackage {
            let hasDWGs = mainURL.pathExtension.lowercased() == "dwg"
                || index.values.contains { $0.pathExtension.lowercased() == "dwg" }
            if hasDWGs, DWGConverter.anyConverterAvailable {
                let outDir: URL
                if let bucket = cacheBucket {
                    outDir = try DWGConverter.convertFolderCached(packageDir, bucket: bucket)
                    // NOTE: do NOT add `outDir` to tempDirs — the cache persists.
                } else {
                    outDir = try DWGConverter.convertFolder(packageDir)
                    tempDirs.append(outDir)
                }
                for (name, dxf) in PackageLoader.drawingIndex(in: outDir, recursive: true) {
                    index[name] = dxf
                }
            }
            // DWG xrefs without a converter simply stay unresolved (flagged in UI).
        }
        try checkCancelled()
        if mainURL.pathExtension.lowercased() == "dwg" {
            let mainBase = mainURL.deletingPathExtension().lastPathComponent.lowercased()
            if deepPackage, let converted = index[mainBase],
               converted.pathExtension.lowercased() == "dxf" {
                mainURL = converted
            } else if let bucket = cacheBucket {
                mainURL = try DWGConverter.convertToDXFCached(url: mainURL, bucket: bucket)
            } else {
                mainURL = try DWGConverter.convertToDXF(url: mainURL)
            }
        }
        progress?(0.08)
        try checkCancelled()

        let parsed = try EntityStoreParser.parse(url: mainURL) { p in
            progress?(0.08 + p * 0.5)
        }
        try checkCancelled()

        if !deepPackage, parsed.blocks.values.contains(where: { $0.isXref && $0.entityCount == 0 }) {
            index = drawingIndexer(packageDir, false)
        }

        var filesLoaded = 0
        var convertedCache: [String: URL] = [:]
        var capped = false
        try resolveXrefsIntoStore(into: parsed, index: index,
                              chain: [PackageLoader.canonicalKey(mainURL), PackageLoader.canonicalKey(url)], depth: 0,
                              filesLoaded: &filesLoaded, convertedCache: &convertedCache,
                              cacheBucket: cacheBucket, capped: &capped,
                              isCancelled: isCancelled) { p, fileName, idx, total in
            progress?(0.58 + p * 0.2)
            xrefProgress?(XrefProgress(fraction: p, fileName: fileName, fileIndex: idx, fileTotal: total))
        }
        parsed.xrefMergeCapped = capped
        progress?(1.0)
        parsed.resourceDirectories.insert(packageDir, at: 0)
        return parsed
    }

    // MARK: - Xref resolution (EntityStore path)

    /// Resolves every xref BLOCK in `host` — top-level and nested — into the
    /// host store, storing each unique SOURCE FILE exactly once and
    /// ALIASING every other reference to it. See the pre-extraction
    /// `CADCore.PackageLoader.resolveXrefsIntoStore` doc comment (git
    /// history, commit dacafda^) for the full de-dup rationale; reproduced
    /// verbatim here since this logic doesn't belong in CADCore (it operates
    /// on NovaCAD-only `EditableParsedDocument`/`EntityStore` types).
    private static func resolveXrefsIntoStore(into host: EditableParsedDocument,
                                              index: [String: URL],
                                              chain: Set<String>, depth: Int,
                                              filesLoaded: inout Int,
                                              convertedCache: inout [String: URL],
                                              cacheBucket: URL? = nil,
                                              capped: inout Bool,
                                              isCancelled: (() -> Bool)? = nil,
                                              progress: (Double, String?, Int, Int) -> Void) throws {
        // canonical source key -> the host range its content was merged into.
        var sharedContent: [String: SharedXrefContent] = [:]
        // Block names already attempted (resolved, aliased, or
        // unresolvable) — so a block that can't be resolved isn't retried
        // every pass, and the loop terminates.
        var processed: Set<String> = []
        // Bounded by the number of distinct nesting depths actually
        // present; the cap is only a runaway backstop (each pass must
        // resolve at least one new block or the terminating `isEmpty`
        // check fires).
        let maxPasses = 256

        // Polled once per xref FILE about to be converted/parsed/merged —
        // the granularity a user waiting on a large package actually
        // notices — not once per block (many blocks alias an
        // already-merged file via `sharedContent` and cost nothing).
        func checkCancelledInLoop() throws {
            if isCancelled?() == true { throw PackageLoadStoreError.cancelled }
        }

        var pass = 0
        while pass < maxPasses {
            pass += 1
            let xrefNames = host.blocks
                .filter { $0.value.isXref && $0.value.entityCount == 0 && !processed.contains($0.key) }
                .keys.sorted()
            if xrefNames.isEmpty { break }

            for (i, name) in xrefNames.enumerated() {
                processed.insert(name)
                guard let block = host.blocks[name] else { continue }

                // Find the source file. Dependent xref blocks are named
                // "PARENT$…$SOURCE"; the source basename is the last
                // '$'-segment (a plain top-level xref has no '$', so this is
                // just the name). Try the saved xrefPath basename first,
                // then that last segment, then the whole name.
                var candidates: [String] = []
                if !block.xrefPath.isEmpty {
                    let base = (block.xrefPath.replacingOccurrences(of: "\\", with: "/")
                        as NSString).lastPathComponent
                    candidates.append((base as NSString).deletingPathExtension.lowercased())
                }
                candidates.append((name.components(separatedBy: "$").last ?? name).lowercased())
                candidates.append(name.lowercased())
                // Prefer a file in the opened package; otherwise fall back
                // to a user-provided location the user linked via "Set Xref
                // Path…" for an xref that isn't embedded in this DXF.
                var overrideURL: URL? = nil
                let sourceURLOpt: URL?
                if let inPackage = candidates.compactMap({ index[$0] }).first {
                    sourceURLOpt = inPackage
                } else if let linked = XrefPathOverrides.resolvedURL(forBlockName: name) {
                    overrideURL = linked
                    sourceURLOpt = linked
                } else {
                    sourceURLOpt = nil
                }
                guard let sourceURL = sourceURLOpt else { continue }
                // Balance security-scoped access for user-linked
                // (out-of-package) files for the duration of this
                // iteration's read/convert.
                let overrideScoped = overrideURL?.startAccessingSecurityScopedResource() ?? false
                defer { if overrideScoped { overrideURL?.stopAccessingSecurityScopedResource() } }

                let key = PackageLoader.canonicalKey(sourceURL)
                guard !chain.contains(key) else { continue }   // host/ancestor: don't re-resolve

                // De-dup: this exact source was already merged under some
                // other reference — point THIS block at that same host
                // range instead of parsing/copying it again. THE memory fix.
                if let shared = sharedContent[key] {
                    block.entityStart = shared.entityStart
                    block.entityCount = shared.entityCount
                    block.blockIndex = shared.blockIndex
                    block.base = shared.base
                    block.xrefSourcePath = sourceURL.path
                    block.xrefLoadedPath = shared.loadedPath
                    block.wasResolved = true
                    block.isXrefDependent = false
                    continue
                }

                // Safety net: never grow the merged store past the budget.
                // Recorded via `capped` (not just silently skipped) so the
                // caller can raise one clear "this drawing hit its size
                // limit" notice instead of the cap manifesting as an
                // unremarkable extra unresolved-xref row — see
                // `EditableParsedDocument.xrefMergeCapped`'s doc comment.
                guard host.store.count < storeMaxMergedEntities else { capped = true; continue }
                guard filesLoaded < storeMaxXrefFiles else { capped = true; continue }

                try checkCancelledInLoop()

                var fileURL = sourceURL
                if fileURL.pathExtension.lowercased() == "dwg" {
                    if let cached = convertedCache[key] {
                        fileURL = cached
                    } else if let bucket = cacheBucket,
                              let converted = try? DWGConverter.convertToDXFCached(url: fileURL, bucket: bucket) {
                        // Persistent cache path: reuses a prior conversion
                        // when the source dwg is unchanged (cross-session
                        // speedup).
                        convertedCache[key] = converted
                        fileURL = converted
                    } else if let converted = try? DWGConverter.convertToDXF(url: fileURL) {
                        convertedCache[key] = converted
                        fileURL = converted
                    } else {
                        continue
                    }
                }

                // Report BEFORE the (potentially slow, even post-O(n²)-fix,
                // for a multi-hundred-MB xref) parse+merge starts, not
                // after — so a user watching the loading UI sees the
                // CURRENT file name update immediately instead of the
                // previous file's name lingering for the file's whole
                // parse+merge duration.
                if depth == 0 {
                    progress(Double(i) / Double(max(1, xrefNames.count)),
                             sourceURL.lastPathComponent, i + 1, xrefNames.count)
                }

                guard let sub = try? EntityStoreParser.parse(url: fileURL, progress: { _ in })
                else { continue }
                filesLoaded += 1

                // Merge the sub's OWN content only; its nested xref blocks
                // come across as unresolved stubs and are resolved (and
                // de-duped) by a later pass of this loop — see the doc
                // comment above.
                mergeIntoStore(sub: sub, asContentOf: name, into: host)
                block.xrefSourcePath = sourceURL.path
                block.xrefLoadedPath = fileURL.path
                block.wasResolved = true
                sharedContent[key] = SharedXrefContent(
                    entityStart: block.entityStart, entityCount: block.entityCount,
                    blockIndex: block.blockIndex, base: block.base,
                    loadedPath: fileURL.path)
                if depth == 0 {
                    progress(Double(i + 1) / Double(max(1, xrefNames.count)),
                             sourceURL.lastPathComponent, i + 1, xrefNames.count)
                }
            }
        }
    }

    /// Store-level equivalent of `CADCore.PackageLoader`'s `merge(sub:asContentOf:into:)`:
    /// transplants a scanned xref file's `EntityStore` content into the
    /// host's `EntityStore`, applying the exact same AutoCAD
    /// dependent-naming rules ("XREF|layer", "XREF$block") and the same
    /// "unconditional rename, even dangling" INSERT-name-rewrite safety
    /// rule.
    private static func mergeIntoStore(sub: EditableParsedDocument, asContentOf xrefName: String,
                                       into host: EditableParsedDocument) {
        let hostStore = host.store
        let subStore = sub.store

        // Dependent-LAYER names join the xref-nesting path with '|', not the
        // '$' used for block names — i.e. a nested xref layer is
        // "PARENT|CHILD|layer", never "PARENT$CHILD|layer". The caller
        // resolves nested xrefs at the HOST level (see
        // `resolveXrefsIntoStore`), so `xrefName` here can already be a
        // '$'-joined dependent block path ("PARENT$CHILD"); convert those
        // separators to '|' for layer naming so the result is identical to
        // the recursive-merge path (which prefixed one '|' level per
        // recursion). Block names below deliberately keep '$'.
        let layerPrefix = xrefName.replacingOccurrences(of: "$", with: "|")

        // ---- Layers: sub layer 0 keeps host layer 0; others get XREF|name ----
        var layerMap = [Int32: Int32]()
        for subLayer in sub.layers {
            if subLayer.id == 0 { layerMap[0] = 0; continue }
            let depName = "\(layerPrefix)|\(subLayer.name)"
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
            let depName = "\(layerPrefix)|\(subLayer.name)"
            if let hostId = host.layerIdByName[depName] {
                let mapped = ltMap[Int16(subLayer.linetypeId)] ?? 0
                host.layers[Int(hostId)].linetypeId = Int(max(mapped, 0))
                host.layers[Int(hostId)].lineweight = subLayer.lineweight
            }
        }

        func remapLayer(_ id: Int32) -> Int32 { layerMap[id] ?? 0 }
        func remapLinetype(_ id: Int16) -> Int16 { ltMap[id] ?? 0 }

        // ---- Block names: XREF$name ----
        var blockNameMap = [String: String]()
        for (subName, _) in sub.blocks {
            let upper = subName.uppercased()
            guard !upper.hasPrefix("*MODEL_SPACE"), !upper.hasPrefix("*PAPER_SPACE"),
                  upper != "$MODEL_SPACE" else { continue }
            blockNameMap[subName] = "\(xrefName)$\(subName)"
        }
        // Unconditional prefix: a dangling reference (definition missing
        // from the xref file) must NOT bind to an unrelated host block of
        // the same name — AutoCAD renders nothing. Mirrors `merge`'s
        // `remap` closure exactly.
        func remapBlockName(_ name: String) -> String {
            blockNameMap[name] ?? "\(xrefName)$\(name)"
        }

        // ---- Content: sub model space (+ *Model_Space blocks) fills the xref block ----
        // The xref BLOCK definition already exists in the host (it's the
        // stub the host's own INSERT/BLOCK record pointed at) — allocate it
        // a fresh block index up front, the same way `EntityStoreParser`
        // does when a BLOCK record starts (index assigned BEFORE any entity
        // is appended), so every transplanted entity's owner is a valid
        // `.block(index)` from the moment it's copied — no placeholder
        // owner, no second fix-up pass.
        guard let hostBlock = host.blocks[xrefName] else { return }
        if hostBlock.blockIndex < 0 {
            hostBlock.blockIndex = nextFreeBlockIndex(host)
        }
        let xrefOwner = OwnerRef.block(hostBlock.blockIndex)

        // Every OTHER sub-block also needs its host block index allocated
        // up front (same reason) — register them all before copying any
        // entities, so `nextFreeBlockIndex` never hands out the same index
        // twice and every block's content lands under the right owner from
        // its very first appended entity.
        var newBlockIndex = [String: Int32]()
        for (subName, _) in sub.blocks.sorted(by: { $0.key < $1.key }) {
            guard blockNameMap[subName] != nil else { continue }
            newBlockIndex[subName] = nextFreeBlockIndex(host, reserving: newBlockIndex.count)
        }

        // Image-definition handles are scoped to their source DXF, just like
        // entity handles. Remap them once per xref instead of accidentally
        // showing a host image with the same numeric handle.
        var imageDefinitions: [UInt64: UInt64] = [:]
        if !sub.objects.imageDefs.isEmpty {
            let graph = DXFStructuralWriter.buildHandleGraph(parsed: host, store: hostStore, version: .r2018)
            for definition in sub.objects.imageDefs.values {
                let handle = graph.allocator.allocate()
                var copy = definition
                copy.handle = handle; copy.ownerHandle = 0
                copy.fileName = SheetRenderSupport.resourceURL(definition.fileName, directories: sub.resourceDirectories)?.path ?? definition.fileName
                copy.rawPairs = []
                host.objects.imageDefs[handle] = copy
                imageDefinitions[definition.handle] = handle
            }
        }

        // Built ONCE per sub-store (O(n) over this xref file's own entity
        // count only — never the host's, which only grows) so the
        // recursive copy below can look up an entity's ATTRIB children in
        // O(1) instead of re-scanning `subStore` per copied entity. See
        // `copyWithAttributeChildren`'s own doc comment for the full
        // "stuck at 51%" performance rationale.
        let subChildrenByParent = subStore.childrenByParent()

        /// Copies `id` from `subStore` into `hostStore` under `owner`, THEN
        /// recursively copies every `.parentEntity`-owned child `subStore
        /// .children(of: id)` finds (e.g. an INSERT's ATTRIBs), re-parented
        /// onto the NEW copy's id in the host — mirroring
        /// `CrossDocumentPaste.createEntity`'s identical recursion for
        /// cross-drawing paste. Without this, `forEachEntity`/`transplant`
        /// (below) only ever copy entities matching a FIXED top-level
        /// owner test (`.isModel`/`.isPaper`, or a caller-supplied constant
        /// `owner:`), which a `.parentEntity`-owned ATTRIB can never satisfy
        /// — so an xref'd INSERT's attribute text was silently OMITTED
        /// entirely from the host store (not merely mis-owned), reproducing
        /// exactly the reported "attributes missing only when viewed as an
        /// xref, present when the same file is opened directly" bug: the
        /// direct-open path's `EntityStoreParser` already links ATTRIBs via
        /// `.parentEntity` correctly (and `Regenerator`'s render walk
        /// already knows to visit `store.children(of:)` for them — see
        /// AGENTS.md's ATTRIB-linking invariant), so the SAME already-linked
        /// sub-document simply had that linkage dropped on the floor during
        /// the xref cross-store transplant, before `Regenerator` ever ran
        /// against the host.
        ///
        /// PERFORMANCE (the "stuck at 51%" fix): this used to call
        /// `subStore.children(of: id)` — a FULL linear scan of every header
        /// in the sub-store — once per copied entity, making the whole merge
        /// O(entities^2) PER XREF FILE. On a real production eTransmit package
        /// (33 xrefs, ~14M geometry entities, several individual xrefs at 1.3–1.9M
        /// entities each) that is 1.6e13+ header reads, i.e. HOURS of 100%
        /// CPU with the progress bar frozen — the user-reported hang, which a
        /// stack sample of the live app confirmed exactly (99.7% of samples
        /// inside `EntityStore.children(of:)` under this function). It is now
        /// a single O(n) `childrenByParent()` index built ONCE per sub-store
        /// by the caller and an O(1) lookup here, exactly as
        /// `DXFStructuralWriter`/`Regenerator` already do for the same
        /// reason. Behavior is otherwise IDENTICAL (same children, same
        /// ascending-id order, deleted still skipped), so AGENTS.md's
        /// ATTRIB-linking invariant #1 is preserved verbatim.
        @discardableResult
        func copyWithAttributeChildren(_ id: EntityID, owner: OwnerRef) -> EntityID? {
            guard let newId = hostStore.appendCopy(of: id, from: subStore,
                                                   remapLayer: remapLayer, remapLinetype: remapLinetype,
                                                   remapBlockName: remapBlockName, owner: owner) else { return nil }
            if let header = hostStore.header(newId), header.type == .image {
                let index = Int(header.payload)
                hostStore.images[index].imageDefHandle = imageDefinitions[hostStore.images[index].imageDefHandle] ?? 0
                // A source IMAGEDEF_REACTOR pointer cannot refer into the host.
                hostStore.residualPairs[newId.raw]?.pairs.removeAll { $0.code == 360 }
            }
            // O(1) lookup; absent key == no children (the overwhelmingly
            // common case — plain LINEs etc. never have any).
            if let kids = subChildrenByParent[id.raw] {
                for childId in kids {
                    // `childrenByParent()` already filtered deleted entities,
                    // so no re-check is needed here.
                    _ = copyWithAttributeChildren(childId, owner: .parentEntity(newId))
                }
            }
            return newId
        }

        /// Appends a contiguous copy of `range` from `subStore` into
        /// `hostStore` under `owner`, remapping layer/linetype/insert-name
        /// references, and returns the (start, count) range it occupies in
        /// the host — block content must stay contiguous
        /// (`EditableBlockDef.entityStart/entityCount`'s documented
        /// invariant), so each call fully finishes appending its own range
        /// before the next one starts.
        ///
        /// Entities already owned via `.parentEntity` in the SOURCE range
        /// (a nested attributed block reference's own ATTRIBs) are skipped
        /// here on their first pass through the range and copied instead
        /// by their parent's own `copyWithAttributeChildren` recursion when
        /// that parent INSERT is reached earlier in the SAME range —
        /// `EntityStoreParser` always appends an INSERT's ATTRIB children
        /// immediately after it (before its SEQEND), so the parent is
        /// guaranteed to appear first. Without this, every entity in the
        /// range unconditionally got the SAME fixed `owner:` regardless of
        /// its own original owner, silently overwriting a nested INSERT's
        /// ATTRIBs from `.parentEntity(nestedInsertId)` to flat block
        /// content and severing the link just as thoroughly as the
        /// top-level omission above (see `copyWithAttributeChildren`'s doc
        /// comment).
        @discardableResult
        func transplant(_ start: Int32, _ count: Int32, owner: OwnerRef) -> (start: Int32, count: Int32) {
            let newStart = Int32(hostStore.count)
            if count > 0 {
                for i in Int(start)..<Int(start + count) {
                    let id = EntityID(raw: Int32(i))
                    guard let h = subStore.header(id), !h.flags.contains(.deleted) else { continue }
                    guard h.owner.parentEntityID == nil else { continue }
                    _ = copyWithAttributeChildren(id, owner: owner)
                }
            }
            let newCount = Int32(hostStore.count) - newStart
            return (newStart, newCount)
        }

        // Model space first, in file order, then each *MODEL_SPACE-ish
        // block's content appended right after — matches `merge`'s `var
        // content = sub.model; content.append(...)` order exactly.
        let modelStart = Int32(hostStore.count)
        forEachEntity(in: sub, space: .model) { id in
            guard let h = subStore.header(id), !h.flags.contains(.deleted) else { return }
            _ = copyWithAttributeChildren(id, owner: xrefOwner)
        }
        for (subName, b) in sub.blocks.sorted(by: { $0.key < $1.key }) {
            let upper = subName.uppercased()
            if upper.hasPrefix("*MODEL_SPACE") || upper == "$MODEL_SPACE" {
                transplant(b.entityStart, b.entityCount, owner: xrefOwner)
            }
        }
        let modelCount = Int32(hostStore.count) - modelStart
        hostBlock.entityStart = modelStart
        hostBlock.entityCount = modelCount
        hostBlock.isXrefDependent = false   // the host-side block itself

        // ---- Transplant the sub file's OTHER block definitions ----
        for (subName, b) in sub.blocks.sorted(by: { $0.key < $1.key }) {
            guard let newName = blockNameMap[subName], let blockIndex = newBlockIndex[subName] else { continue }
            let (start, count) = transplant(b.entityStart, b.entityCount, owner: .block(blockIndex))
            let copy = EditableBlockDef()
            copy.name = newName
            copy.base = b.base
            copy.flags = b.flags
            copy.xrefPath = b.xrefPath
            copy.xrefSourcePath = b.xrefSourcePath
            copy.xrefLoadedPath = b.xrefLoadedPath
            copy.blockIndex = blockIndex
            copy.entityStart = start
            copy.entityCount = count
            copy.isXrefDependent = true
            copy.wasResolved = b.wasResolved
            host.blocks[newName] = copy
        }

        for (k, v) in sub.skippedTypes { host.skippedTypes[k, default: 0] += v }
    }

    /// Iterates a sub-document's model or paper space, mirroring
    /// `Regenerator`'s `EntitySource.space` walk (used only for xref merge
    /// here — never touches the host store).
    private static func forEachEntity(in doc: EditableParsedDocument, space: SpaceID,
                                      _ body: (EntityID) -> Void) {
        let store = doc.store
        for i in store.headers.indices {
            let h = store.headers[i]
            guard !h.flags.contains(.deleted) else { continue }
            let matches: Bool
            switch space {
            case .model: matches = h.owner.isModel
            case .paper: matches = h.owner.isPaper
            }
            guard matches else { continue }
            body(EntityID(raw: Int32(i)))
        }
    }

    /// Next unused `EditableBlockDef.blockIndex` in `host` — needed because
    /// merged-in xref content allocates fresh block slots the original
    /// single-file parse never assigned (the xref block itself starts with
    /// `blockIndex == -1`, an unresolved stub; transplanted dependent blocks
    /// don't exist yet at all). `reserving` offsets past indices already
    /// handed out earlier in the SAME merge call (before any of them is
    /// actually stored on a `host.blocks` entry, so `host.blocks.values`
    /// alone wouldn't see them yet) — callers allocating a batch up front
    /// pass `0, 1, 2, ...` for successive reservations within one batch.
    private static func nextFreeBlockIndex(_ host: EditableParsedDocument, reserving: Int = 0) -> Int32 {
        let maxIndex = host.blocks.values.map(\.blockIndex).max() ?? -1
        return maxIndex + 1 + Int32(reserving)
    }

    // MARK: - Package plumbing (zip/folder helpers not exposed as `public` by CADCore)

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
            throw PackageLoadStoreError.extractionFailed(
                String(data: logData, encoding: .utf8) ?? "exit \(p.terminationStatus)")
        }
    }

    /// Picks the main drawing of a package: prefer a file matching the
    /// package's own name, then a single root-level drawing, then the
    /// largest. Store-path-local copy of `CADCore.PackageLoader`'s private
    /// `findMainDrawing` (that one isn't `public`).
    private static func findMainDrawingStore(in dir: URL, hint: String) throws -> URL {
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

        // AutoCAD eTransmit writes a report .txt named after the MAIN
        // drawing — the most reliable signal in a package full of xref
        // DWGs. Guard against stray .txt files: prefer a hint-matching
        // candidate, and otherwise only trust the heuristic when exactly
        // one txt matches a drawing.
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
        let all = Array(PackageLoader.drawingIndex(in: root).values)
        if let match = all.first(where: {
            $0.deletingPathExtension().lastPathComponent.lowercased() == hintLower
        }) { return match }
        if let largest = all.max(by: { size($0) < size($1) }) { return largest }
        throw PackageLoadStoreError.noDrawingFound
    }
}
