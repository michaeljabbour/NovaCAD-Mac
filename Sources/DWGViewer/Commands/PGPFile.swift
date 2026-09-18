import Foundation

/// Parses and manages the classic AutoCAD alias-file format (`acad.pgp`):
/// one alias per line, `ALIAS, *COMMAND`. Blank lines, lines starting with
/// `;`, and malformed lines missing the `*` are skipped.
///
/// NovaCAD ships a bundled default (`defaultContents` below, mirroring
/// Sources/DWGViewer/Resources/acad.pgp) that's copied to the user's
/// Application Support folder on first run, so it can be hand-edited without
/// touching the app bundle.
enum PGPFile {
    /// The bundled default alias file's content, embedded as a literal
    /// rather than read via `Bundle.module`/`resources: [.copy("Resources")]`
    /// at runtime.
    ///
    /// THIS IS A DELIBERATE FIX FOR A REAL CRASH, not a style choice: SwiftPM
    /// emits a SEPARATE resource bundle ("NovaCAD_DWGViewer.bundle") next to
    /// the compiled binary, and generates a `Bundle.module` accessor that
    /// HARD `fatalError`s if it can't locate that bundle at runtime. That
    /// accessor's lookup checks exactly two paths: (1)
    /// `Bundle.main.bundleURL` + the bundle name — for a `.app`,
    /// `Bundle.main.bundleURL` is the app's own TOP-LEVEL directory, which is
    /// NOT a location `codesign --deep` will accept ANY loose content at
    /// (confirmed empirically: codesign rejects "unsealed contents present
    /// in the bundle root" for literally any file/directory sitting next to
    /// `Contents/`, symlink included) — or (2) an ABSOLUTE path baked in at
    /// COMPILE TIME on whichever machine ran `swift build`, which only ever
    /// resolves on that one developer machine. There is therefore NO
    /// location that simultaneously satisfies `Bundle.module`'s runtime
    /// lookup AND a validly-signed `.app` structure — every recipient other
    /// than the exact machine that built the binary crashed on launch the
    /// instant `ContentView.body` called `PGPFile.ensureDefaultExists()`
    /// (`Bundle.module`'s one-time initializer, EXC_BREAKPOINT via
    /// `_assertionFailure`). Embedding this tiny (792-byte) file's content
    /// directly removes the dependency on `Bundle.module` (hence on
    /// SwiftPM's resource-bundle mechanism) entirely for this one resource.
    /// Keep this in sync with Sources/DWGViewer/Resources/acad.pgp if that
    /// file is ever hand-edited (the on-disk copy is retained purely as a
    /// human-readable reference/diff target — nothing reads it at runtime
    /// anymore).
    static let defaultContents = """
    ; NovaCAD default command alias file (acad.pgp format)
    ;
    ; Classic AutoCAD-style command aliases. One alias per line:
    ;     <alias>, *<COMMAND>
    ; Blank lines and lines starting with ';' are ignored. Lines missing the
    ; leading '*' before the command name are considered malformed and skipped.
    ;
    ; This file is copied to ~/Library/Application Support/NovaCAD/acad.pgp on
    ; first run (see PGPFile.ensureDefaultExists()). Edit the copy in Application
    ; Support to customize your own aliases — this bundled copy is only the
    ; template used to seed a fresh install.

    L,      *LINE
    PL,     *PLINE
    C,      *CIRCLE
    A,      *ARC
    REC,    *RECTANGLE
    POL,    *POLYGON
    T,      *TEXT
    E,      *ERASE
    M,      *MOVE
    DI,     *DISTANCE
    AREA,   *AREA
    RAD,    *RADIUS
    ANG,    *ANGLE
    Z,      *ZOOM
    U,      *UNDO
    """

    /// Parses the classic `ALIAS, *COMMAND` format. Returns pairs in file
    /// order (later duplicate aliases for the same short code simply appear
    /// twice — callers that build a dictionary naturally keep the last one,
    /// matching AutoCAD's "last one wins" semantics).
    static func parseAliases(_ text: String) -> [(alias: String, command: String)] {
        var result: [(alias: String, command: String)] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix(";") else { continue }
            guard let commaIdx = line.firstIndex(of: ",") else { continue }
            let alias = line[line.startIndex..<commaIdx]
                .trimmingCharacters(in: .whitespaces)
            var rhs = line[line.index(after: commaIdx)...]
                .trimmingCharacters(in: .whitespaces)
            guard !alias.isEmpty, rhs.hasPrefix("*") else { continue }
            rhs.removeFirst()   // drop '*'
            let command = rhs.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { continue }
            result.append((alias: alias, command: command))
        }
        return result
    }

    /// `~/Library/Application Support/NovaCAD/acad.pgp` — the user's live,
    /// editable alias file.
    static var userURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("NovaCAD", isDirectory: true)
                   .appendingPathComponent("acad.pgp")
    }

    /// Writes `defaultContents` to `userURL` if the user doesn't already
    /// have one. Never overwrites an existing user file. Best-effort —
    /// failures (e.g. sandboxing) are silently ignored since a missing pgp
    /// file just means "no aliases loaded", which is a safe fallback.
    static func ensureDefaultExists() {
        let dest = userURL
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try defaultContents.write(to: dest, atomically: true, encoding: .utf8)
        } catch {
            // Best-effort — see doc comment above.
        }
    }

    /// Best-effort live-reload watcher: calls `onChange` whenever the file at
    /// `url` is written or its containing directory changes (covering
    /// delete+recreate, which many editors do via atomic replace). Never
    /// throws or crashes if the file doesn't exist yet or is deleted out
    /// from under the watch; simply stops delivering events until re-armed.
    /// Returns nil if a descriptor for the path can't be opened (e.g. parent
    /// directory missing) — callers should treat that as "no live reload,"
    /// not a fatal condition.
    static func watch(_ url: URL, onChange: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let dir = url.deletingLastPathComponent()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: DispatchQueue.main)
        source.setEventHandler { onChange() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
