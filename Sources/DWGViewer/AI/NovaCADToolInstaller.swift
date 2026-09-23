import Foundation

/// Installs NovaCAD's own OpenCode **custom tools** into the sandboxed
/// workspace so the agentic backend (`opencode serve`) can call real
/// drawing-interaction capabilities — `read_drawing`, `get_insert_attributes`,
/// `find_insert_at_point`, `propose_attribute_edits` — instead of only
/// emitting text. This is a direct port of an earlier internal project's
/// OpenCode tool installer per `Resources/Specs/AI_ASSISTANT_PORTING_GUIDE.md`
/// §3/§4, with that project's own catalog swapped for NovaCAD's drawing-tool
/// catalog (`AIToolSchema.tools`'s Anthropic-native declarations are the same
/// tools, described here in the shape opencode's Zod-based forwarders need
/// instead).
///
/// How it fits together:
///
///   OpenCode agent ──calls tool──▶ .opencode/tools/*.ts (thin forwarders)
///                                        │ HTTP POST
///                                        ▼
///                      NovaCAD Tool Bridge (in-process HTTP server)
///                                        │
///                                        ▼
///                          AIToolExecutor (the live drawing)
///
/// The `.ts` forwarders are intentionally tiny: they read the tool
/// arguments, POST them to the local bridge
/// (`http://127.0.0.1:<port>/tool/<name>`), and return the bridge's
/// response. All real logic stays in Swift, where it has typed access to
/// NovaCAD's `RegenCoordinator`/`EditableParsedDocument`.
///
/// Tools are written to `<workspace>/.opencode/tools/` (project-local
/// scope), which OpenCode auto-discovers. Reinstalling is cheap and
/// idempotent: files are only rewritten when their content changes.
enum NovaCADToolInstaller {
    /// True when the `@opencode-ai/plugin` npm package directory exists in
    /// the workspace's `.opencode/node_modules/` — the precondition for safe
    /// tool-calling. Without this package, opencode's Zod → JSON schema
    /// conversion crashes when the agent calls any typed-argument tool, and
    /// the entire turn hangs with no response (invariant #4). Install it
    /// yourself with `npm install @opencode-ai/plugin` inside
    /// `OpenCodeWorkspace.directory`'s `.opencode/` folder (matching how
    /// that earlier project's workspace is set up — this app does not
    /// automate the install itself, per the porting guide's own scope).
    static var pluginIsInstalled: Bool {
        FileManager.default.fileExists(
            atPath: OpenCodeWorkspace.directory
                .appendingPathComponent(".opencode/node_modules/@opencode-ai/plugin/package.json")
                .path
        )
    }

    /// A tool NovaCAD exposes to the OpenCode agent.
    struct ToolSpec {
        let name: String
        let description: String
        /// Zod arg declarations, e.g. `x: tool.schema.number().describe("…")`.
        let argsDeclaration: String
    }

    /// The catalog of tools NovaCAD installs — the SAME four tools
    /// `AIToolSchema.tools` declares for the Anthropic tool-calling path
    /// (`read_drawing`, `get_insert_attributes`, `find_insert_at_point`,
    /// `propose_attribute_edits`), described here in the Zod-forwarder shape
    /// opencode needs instead. Keep this list, `AIToolSchema.tools`, and
    /// `NovaCADToolRouter.knownTools`/`handle(tool:body:)` in sync — see
    /// `AIToolExecutor.execute(tool:arguments:)`, which both the Anthropic
    /// loop AND this bridge ultimately call into.
    static let tools: [ToolSpec] = [
        ToolSpec(
            name: "read_drawing",
            description: "Read a compact overview: active space and sheet, available paper sheets, coordinate units, visible layers/counts, live viewport bounds and nearby text, and a small entity sample. Defaults to the active view. Use query_entities for targeted text/block searches and paged details; the overview is not exhaustive.",
            argsDeclaration: "space: \(arg("str", "\"model\" or \"paper\" (default active view)", optional: true))"
        ),
        ToolSpec(
            name: "list_inserts_on_layer",
            description: "Paged block references on one layer, including total count, returned count and nextOffset. Follow nextOffset for additional rows. For complete distance tables use the native export tool.",
            argsDeclaration: """
    layerName: \(arg("str", "Layer to enumerate, e.g. 'station blocks'")),
    offset: \(arg("num", "Row offset, default 0; follow nextOffset", optional: true)),
    limit: \(arg("num", "Maximum rows, default 30, max 100; also byte-limited", optional: true)),
    space: \(arg("str", "\"model\" or \"paper\" (default active view)", optional: true))
    """
        ),
        ToolSpec(
            name: "export_csv",
            description: "Exports any structured tabular dataset to CSV in ~/Documents/NovaCAD Exports and returns the exact path.",
            argsDeclaration: """
    datasetJSON: \(arg("str", "JSON string with columns and rows arrays")),
    filename: \(arg("str", "Optional CSV filename", optional: true))
    """
        ),
        ToolSpec(
            name: "get_insert_attributes",
            description: "List every ATTRIB tag/value on one INSERT (block reference), by its entity id (from read_drawing's \"entityId\" field for an \"insert\"-type row). Use this to see a workstation block's current attribute values (e.g. its NAME) before proposing a change.",
            argsDeclaration: "insertEntityId: \(arg("num", "The INSERT's entity id, from read_drawing"))"
        ),
        ToolSpec(
            name: "find_insert_at_point",
            description: "Find which top-level INSERT (block reference)'s bounding box contains a given world-space (x, y) point — use this to figure out which workstation block a loose label TEXT (one that is NOT already an ATTRIB child of a block) is positioned inside of, by passing that TEXT's own position.",
            argsDeclaration: """
    x: \(arg("num", "World-space X coordinate")),
    y: \(arg("num", "World-space Y coordinate")),
    space: \(arg("str", "\"model\" or \"paper\" (default active view)", optional: true))
    """
        ),
        ToolSpec(
            name: "propose_attribute_edits",
            description: "Stage a plan of one or more ATTRIB value changes on existing INSERTs (block references) for the user to review and approve — this does NOT modify the drawing itself. Use this once you know exactly which INSERT(s) and which ATTRIB tag to change. Also works for a tag that doesn't exist on the target yet — a brand-new ATTRIB is created rather than requiring it to already be present. The user sees each proposed \"tag: old → new\" (or \"tag: (new attribute) → value\") change and must press Apply before anything is actually written. For the SAME tag/value across every object on one layer, prefer bulk_set_attribute_on_layer instead of calling this once per object.",
            argsDeclaration: "edits: \(arg("str", "JSON array of {insertEntityId, attributeTag, newValue} objects, encoded as a string, e.g. '[{\"insertEntityId\":42,\"attributeTag\":\"NAME\",\"newValue\":\"Station 7\"}]'"))"
        ),
        ToolSpec(
            name: "bulk_set_attribute_on_layer",
            description: "Stage the SAME attribute tag/value change across EVERY block reference (INSERT) on one layer, for the user to review and approve — this does NOT modify the drawing itself. Use this for requests like \"add an attribute called ROUTE with value R-7 to every object on layer CARRIER-STATIONS\" instead of calling propose_attribute_edits once per object. Works whether the target objects already have this tag (updated) or not (a brand-new ATTRIB is created on each). Objects whose value already matches are skipped. The user must press Apply before anything is actually written.",
            argsDeclaration: """
    layerName: \(arg("str", "The layer whose block references should all receive this attribute")),
    attributeTag: \(arg("str", "The ATTRIB tag to set on every object, e.g. \"ROUTE\" or \"STATUS\"")),
    value: \(arg("str", "The value to set that tag to on every matching object")),
    space: \(arg("str", "\"model\" or \"paper\" (default active view)", optional: true))
    """
        ),

        // ---- Aisle network / dock apron tool catalog ----
        // See `AIToolSchema.tools`'s matching entries for the full design
        // rationale (why analyze-before-repair-before-route, why gaps are
        // reported not silently bridged, etc) — descriptions here are kept
        // byte-identical to that file's so the two backends present the
        // exact same tool behavior to the model.
        ToolSpec(
            name: "analyze_aisle_network",
            description: "Analyzes an aisle centerline layer's connectivity: how many disconnected pieces it's split into, every gap between them (with distance in feet and exact coordinates), and the aisle widths detected (either measured from parallel boundary lines, or read from the drawing's own \"13'-4\\\" AISLE\"-style text labels). Always call this BEFORE routing or shading an aisle network, since a real aisle layer is routinely fragmented into dozens of pieces that merely LOOK continuous.",
            argsDeclaration: """
    layerName: \(arg("str", "The aisle centerline layer name, e.g. \"AISLE\"")),
    space: \(arg("str", "\"model\" or \"paper\" (default active view)", optional: true))
    """
        ),
        ToolSpec(
            name: "repair_aisle_network",
            description: "Stages inferred bridging connectors for disconnected aisle components. The target may be the same aisle layer, another existing layer, or a new repair layer. Short gaps are common drafting slips; large physical separations should not be bridged.",
            argsDeclaration: """
    layerName: \(arg("str", "The aisle centerline layer name")),
    space: \(arg("str", "\"model\" or \"paper\" (default active view)", optional: true)),
    maxGapDistanceFeet: \(arg("num", "Maximum inferred connector distance in feet (default 10)", optional: true)),
    targetLayerName: \(arg("str", "Optional destination layer; omit for '<layerName>-REPAIRED'", optional: true))
    """
        ),
        ToolSpec(
            name: "find_route_endpoints",
            description: "Resolves a name to routable world-space coordinates: an individual dock door (\"Dock 4\"), a named dock group (\"blue docks\" — reduced to the centroid of its member doors), or a station/marketplace block by name. Returns every match found. Use the returned x/y as the origin/destination for route_along_aisles.",
            argsDeclaration: """
    query: \(arg("str", "A dock number, dock group name, or (partial) block name to search for")),
    space: \(arg("str", "\"model\" or \"paper\" (default active view)", optional: true))
    """
        ),
        ToolSpec(
            name: "route_along_aisles",
            description: "Routes one trip along an aisle network and reports BOTH one-way and round-trip distance in feet, split into on-aisle travel vs. connector legs at each end. Routes on TRUE AISLE CENTERLINES by default — a real aisle layer usually contains each aisle's two parallel boundary edge lines, and routing those instead of the centre inflates distance roughly 1.5-2x or worse. Small gaps are bridged in memory automatically; the reply states which repairs and graph mode were used. Set useSelectionAsOrigin=true to start from the user's current canvas selection. Set measureOnly=true for distance without staging geometry.",
            argsDeclaration: """
    aisleLayerName: \(arg("str", "The aisle layer to route along")),
    connectorLayerName: \(arg("str", "Optional second layer to union with the aisle network", optional: true)),
    space: \(arg("str", "\"model\" or \"paper\" (default active view)", optional: true)),
    useSelectionAsOrigin: \(arg("bool", "Use the user's current canvas selection as the origin", optional: true)),
    originX: \(arg("num", "Origin world-space X", optional: true)),
    originY: \(arg("num", "Origin world-space Y", optional: true)),
    originLabel: \(arg("str", "Human label for the origin; also used as a name lookup when no coordinates/selection are given", optional: true)),
    destinationX: \(arg("num", "Destination world-space X")),
    destinationY: \(arg("num", "Destination world-space Y")),
    destinationLabel: \(arg("str", "Human label for the destination, e.g. \"Station STN-101\"", optional: true)),
    tripType: \(arg("str", "\"oneWay\" or \"roundTrip\" — which to emphasise; both are always reported (default \"oneWay\")", optional: true)),
    anchor: \(arg("str", "\"nearestEdge\" (default), \"centroid\", or \"insertionPoint\"", optional: true)),
    centerlineMode: \(arg("str", "\"auto\" (default), \"centerlinesOnly\", or \"raw\"", optional: true)),
    autoRepairFeet: \(arg("num", "Bridge aisle gaps at or under this many feet in memory before routing (default 25)", optional: true)),
    routeLayerName: \(arg("str", "Layer to stage the drawn route on (default \"AI-TRAVEL-PATHS\")", optional: true)),
    measureOnly: \(arg("bool", "If true, report distance only and stage no geometry (default false)", optional: true))
    """
        ),
        ToolSpec(
            name: "export_travel_distances",
            description: "THE BATCH TRAVEL-DISTANCE TOOL — use for \"how far from <origin> to each <thing>\" (e.g. marketplace to every point of fit). Enumerates every block reference on a destination layer, resolves ONE shared origin (canvas selection, name, or coordinates), routes each through the aisle network, and writes a CSV to ~/Documents/NovaCAD Exports. EVERY row carries BOTH one_way_ft and round_trip_ft, plus straight_line_ft and detour_ratio so implausible numbers are visible. Routes on true centerlines and auto-repairs small gaps. Unroutable destinations stay in the CSV with a status. Set drawPaths=true to also stage every path as editable polylines for visual verification.",
            argsDeclaration: """
    destinationLayerName: \(arg("str", "Layer containing the destination block references (workstations / points of fit)")),
    aisleLayerName: \(arg("str", "Primary aisle network layer")),
    connectorLayerName: \(arg("str", "Optional separate repair/connector layer", optional: true)),
    space: \(arg("str", "\"model\" or \"paper\" (default active view)", optional: true)),
    useSelectionAsOrigin: \(arg("bool", "Use the user's current canvas selection as the shared origin", optional: true)),
    originQuery: \(arg("str", "Reference dock, group, station, or block name", optional: true)),
    originX: \(arg("num", "Optional explicit origin X", optional: true)),
    originY: \(arg("num", "Optional explicit origin Y", optional: true)),
    tripType: \(arg("str", "\"oneWay\" or \"roundTrip\" — which to quote; both columns are always written (default \"oneWay\")", optional: true)),
    anchor: \(arg("str", "\"nearestEdge\" (default), \"centroid\", or \"insertionPoint\"", optional: true)),
    centerlineMode: \(arg("str", "\"auto\" (default), \"centerlinesOnly\", or \"raw\"", optional: true)),
    autoRepairFeet: \(arg("num", "Bridge aisle gaps at or under this many feet in memory before routing (default 25)", optional: true)),
    drawPaths: \(arg("bool", "Stage every routed path as editable polylines for visual verification (default false)", optional: true)),
    routeLayerName: \(arg("str", "Layer for the drawn paths (default \"AI-TRAVEL-PATHS\")", optional: true)),
    filename: \(arg("str", "Optional CSV filename", optional: true))
    """
        ),
        ToolSpec(
            name: "get_selected_objects",
            description: "Reports what the user currently has SELECTED on the drawing canvas: entity id, type, layer, block/display name, text content, and world-space footprint for each, plus the combined bounding box. Use whenever the user points rather than names — \"use this as the origin\", \"measure from the selected object\", \"what did I just click\".",
            argsDeclaration: "space: \(arg("str", "\"model\" or \"paper\" (default active view)", optional: true))"
        ),
        ToolSpec(
            name: "draw_polylines",
            description: "Stages one or more polylines on the drawing for review — use to make something VISUALLY VERIFIABLE. Every path in one call goes on the SAME layer so the batch can be toggled or deleted together. Once applied these are ordinary fully-editable entities. The routing tools can draw their own paths (route_along_aisles, and export_travel_distances' drawPaths) — prefer those for routed paths and use this for paths you constructed yourself.",
            argsDeclaration: """
    pathsJSON: \(arg("str", "JSON array of paths as a string; each path is [[x,y],[x,y],...] or {\"points\":[[x,y],...]}")),
    layerName: \(arg("str", "Layer to draw on (default \"AI-TRAVEL-PATHS\")", optional: true)),
    space: \(arg("str", "\"model\" or \"paper\" (default active view)", optional: true)),
    closed: \(arg("bool", "Close each path into a filled shape instead of an open polyline (default false)", optional: true)),
    colorIndex: \(arg("num", "AutoCAD color index; 256 = ByLayer (default)", optional: true)),
    replaceExistingLayerContent: \(arg("bool", "Clear the target layer first so redrawn batches don't stack (default false)", optional: true))
    """
        ),
        ToolSpec(
            name: "query_entities",
            description: "Search rendered text, blocks, and line/arc/polyline geometry by layer, name or text. Use visibleOnly:true for objects in the current zoomed canvas area. Results have totalMatched and nextOffset; pages have row and byte limits. Use countOnly to size a job. Paper defaults to the active sheet; sheetName reads another sheet without moving the canvas.",
            argsDeclaration: """
    types: \(arg("str", "Comma-separated entity types to include, e.g. \"insert\" or \"text\". Omit for all.", optional: true)),
    layerContains: \(arg("str", "Only entities whose layer name contains this (case-insensitive)", optional: true)),
    nameContains: \(arg("str", "For INSERTs: only those whose block/display name contains this", optional: true)),
    textContains: \(arg("str", "For TEXT/MTEXT: only those whose content contains this", optional: true)),
    sheetName: \(arg("str", "Exact paper sheet name; use with space: paper. Omit for active sheet.", optional: true)),
    space: \(arg("str", "\"model\" or \"paper\" (default active view)", optional: true)),
    offset: \(arg("num", "Row offset for paging (default 0) — pass the previous reply's nextOffset", optional: true)),
    limit: \(arg("num", "Maximum rows to return (default 30, max 100, also byte-limited)", optional: true)),
    visibleOnly: \(arg("bool", "Only objects intersecting the live canvas bounds; requires active space/sheet. Re-read after pan/zoom. Curved-shape bounds are approximate.", optional: true)),
    countOnly: \(arg("bool", "Return only totalMatched with no rows (default false)", optional: true))
    """
        ),
        ToolSpec(
            name: "inspect_xrefs",
            description: "Lists the drawing's external references and, per xref, the layers it contributes and its entity count. Xref content is ALREADY merged into the live drawing, so the referenced files never need opening even when very large. Xref layers are named '<XREFNAME>|<layer>' and every layer-based tool accepts either that or the bare layer name. Use to discover layers inside an xref before routing or measuring against them.",
            argsDeclaration: """
    nameContains: \(arg("str", "Only xrefs whose name contains this (case-insensitive)", optional: true)),
    includeLayers: \(arg("bool", "Include each xref's layer name list (default true)", optional: true))
    """
        ),
        ToolSpec(
            name: "shade_aisle_network",
            description: "Stages a shaded overlay covering the physical footprint of every aisle on a layer, for the user to review and approve. Each aisle is buffered into a filled rectangle at its own measured/annotated width and placed on a NEW '<layerName>-SHADED' layer. The shapes intentionally overlap at junctions; the target layer's transparency should be set so overlaps don't look like dark blotches.",
            argsDeclaration: """
    layerName: \(arg("str", "The aisle centerline layer to shade")),
    space: \(arg("str", "\"model\" or \"paper\" (default active view)", optional: true)),
    fallbackWidthFeet: \(arg("num", "Width to use for aisle segments with no measured or annotated width, in feet (default 13.34)", optional: true))
    """
        ),
        ToolSpec(
            name: "shade_dock_aprons",
            description: "Detects dock doors (by their \"DOCK <n>\" text labels) and stages one apron shape per bank of consecutive, evenly-spaced doors, for the user to review and approve. Aprons are placed on a NEW 'Dock Apron-AI' layer, at a caller-supplied depth. Deterministic: call again after docks move to redraw aprons on the same layer with fresh positions.",
            argsDeclaration: """
    space: \(arg("str", "\"model\" or \"paper\" (default active view)", optional: true)),
    depthFeet: \(arg("num", "Apron depth inward from the dock line, in feet (default 40)", optional: true)),
    endPaddingFeet: \(arg("num", "Extra length added at each end of a bank's frontage, in feet (default 0)", optional: true)),
    depthSuggestionAisleLayerName: \(arg("str", "Optional aisle layer name to measure suggested per-bank depths against", optional: true))
    """
        )
    ]

    /// Installs (or refreshes) all tool forwarders into the workspace's
    /// `.opencode/tools/` directory and the shared bridge client just *above*
    /// it in `.opencode/`, pointing them at the given local bridge port and
    /// authenticating with the per-launch `token`. Returns the tools
    /// directory URL.
    ///
    /// The shared `_novacad_bridge.ts` helper deliberately lives in
    /// `.opencode/`, NOT in `.opencode/tools/`: opencode treats *every*
    /// module in the tools directory as a tool and builds an argument schema
    /// for its default/exports. A schema-less helper sitting in `tools/`
    /// gets mis-registered as a phantom tool and crashes resolving its
    /// (absent) args — see the earlier project's installer's identical note.
    @discardableResult
    static func install(bridgePort: Int,
                        token: String,
                        workspace: URL = OpenCodeWorkspace.directory) throws -> URL {
        let opencodeDir = workspace.appendingPathComponent(".opencode", isDirectory: true)
        let toolsDir = opencodeDir.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsDir, withIntermediateDirectories: true)

        try writeIfChanged(bridgeClientSource(port: bridgePort, token: token),
                           to: opencodeDir.appendingPathComponent("_novacad_bridge.ts"))

        for spec in tools {
            try writeIfChanged(forwarderSource(for: spec),
                               to: toolsDir.appendingPathComponent("\(spec.name).ts"))
        }
        return toolsDir
    }

    /// Removes all installed NovaCAD tools + the shared bridge helper (used
    /// when disabling the agentic backend, or when the plugin isn't
    /// installed — see `AIAssistantSession.runAgentic`).
    static func uninstall(workspace: URL = OpenCodeWorkspace.directory) throws {
        let opencodeDir = workspace.appendingPathComponent(".opencode", isDirectory: true)
        let toolsDir = opencodeDir.appendingPathComponent("tools", isDirectory: true)
        if FileManager.default.fileExists(atPath: toolsDir.path) {
            try FileManager.default.removeItem(at: toolsDir)
        }
        let bridge = opencodeDir.appendingPathComponent("_novacad_bridge.ts")
        if FileManager.default.fileExists(atPath: bridge.path) {
            try FileManager.default.removeItem(at: bridge)
        }
    }

    // MARK: - Source generation

    /// The shared bridge client. Kept in one file (in `.opencode/`, above
    /// the tools directory) so the port lives in exactly one place;
    /// forwarders import it via `../_novacad_bridge`.
    static func bridgeClientSource(port: Int, token: String) -> String {
        """
        // AUTO-GENERATED by NovaCAD (NovaCADToolInstaller). Do not edit by hand.
        // Thin client that forwards a tool call to the in-process NovaCAD Tool
        // Bridge, which executes it against the live drawing in Swift.
        const NOVACAD_BRIDGE_URL = "http://127.0.0.1:\(port)"
        const NOVACAD_BRIDGE_TOKEN = \(jsString(token))

        export async function callBridge(tool: string, args: unknown): Promise<string> {
          const res = await fetch(`${NOVACAD_BRIDGE_URL}/tool/${tool}`, {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "X-NovaCAD-Bridge-Token": NOVACAD_BRIDGE_TOKEN,
            },
            body: JSON.stringify(args ?? {}),
          })
          const text = await res.text()
          if (!res.ok) {
            return `NovaCAD tool error (${res.status}): ${text}`
          }
          return text
        }
        """
    }

    /// A single tool forwarder file. Uses the **real** `@opencode-ai/plugin`
    /// `tool(...)` helper and its bundled Zod (`tool.schema`, i.e. Zod v4) to
    /// declare argument schemas — see the earlier project's installer's
    /// `forwarderSource` doc comment for why a hand-rolled shim crashes
    /// opencode's schema conversion and the genuine package is required.
    static func forwarderSource(for spec: ToolSpec) -> String {
        """
        // AUTO-GENERATED by NovaCAD (NovaCADToolInstaller). Do not edit by hand.
        import { tool } from "@opencode-ai/plugin"
        // The bridge helper lives in .opencode/ (one level up), NOT in tools/,
        // so opencode doesn't mis-register it as a schema-less phantom tool.
        import { callBridge } from "../_novacad_bridge"

        const str = (desc) => tool.schema.string().describe(desc)
        const num = (desc) => tool.schema.number().describe(desc)
        const bool = (desc) => tool.schema.boolean().describe(desc)

        export default tool({
          description: \(jsString(spec.description)),
          args: { \(spec.argsDeclaration) },
          async execute(args) {
            return await callBridge("\(spec.name)", args)
          },
        })
        """
    }

    /// A Zod-v4 arg declaration for each tool, built from the plugin's real
    /// schema factory. `str("…")`/`num("…")` are the tiny local helpers
    /// defined in `forwarderSource`, and a trailing `.optional()` marks
    /// nullable fields.
    private static func arg(_ type: String, _ desc: String, optional: Bool = false) -> String {
        "\(type)(\(jsString(desc)))\(optional ? ".optional()" : "")"
    }

    // MARK: - Helpers

    /// Encodes a Swift string as a JavaScript double-quoted literal.
    static func jsString(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    /// Writes `content` to `url` only if it differs from what's already
    /// there, so reinstalling doesn't needlessly churn file mtimes.
    private static func writeIfChanged(_ content: String, to url: URL) throws {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == content {
            return
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
