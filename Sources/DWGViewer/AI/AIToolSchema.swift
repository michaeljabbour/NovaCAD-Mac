import Foundation

/// Anthropic-native tool declarations for NovaCAD's AI Assistant — mirrors
/// Anthropic's own `{name, description, input_schema}` tool-declaration
/// shape exactly, since Anthropic's tool-calling wire format is what this
/// provider speaks. Only Anthropic gets a `tools` array in its request (see
/// `AIConfig.Provider.supportsTools`) — the other two providers in this
/// feature's scope are plain chat.
enum AIToolSchema {

    struct Tool: Encodable, Equatable {
        let name: String
        let description: String
        let inputSchema: JSONSchema

        enum CodingKeys: String, CodingKey {
            case name, description
            case inputSchema = "input_schema"
        }
    }

    struct JSONSchema: Encodable, Equatable {
        var type: String = "object"
        var properties: [String: Property]
        var required: [String]
        enum CodingKeys: String, CodingKey { case type, properties, required }
    }

    struct Property: Encodable, Equatable {
        let type: String
        let description: String
        let items: Items?
        init(type: String, description: String, items: Items? = nil) {
            self.type = type; self.description = description; self.items = items
        }
        struct Items: Encodable, Equatable { let type: String }
    }

    /// Read tools inspect the live drawing; write tools stage proposals for Apply.
    static let tools: [Tool] = [
        Tool(
            name: "read_drawing",
            description: "Read a compact overview: active space and sheet, available paper sheets, coordinate units, visible layers/counts, live viewport bounds and nearby text, and a small entity sample. Defaults to the active view. Use query_entities for targeted text/block searches and paged details; the overview is not exhaustive.",
            inputSchema: JSONSchema(
                properties: [
                    "space": Property(type: "string", description: "\"model\" or \"paper\" (default active view)")
                ],
                required: []
            )
        ),
        Tool(
            name: "list_inserts_on_layer",
            description: "Paged block references on one layer, including total count, returned count and nextOffset. Follow nextOffset for additional rows. For complete distance tables use the native export tool.",
            inputSchema: JSONSchema(properties: [
                "layerName": Property(type: "string", description: "Layer to enumerate, e.g. 'station blocks'"),
                "offset": Property(type: "integer", description: "Row offset (default 0); follow nextOffset"),
                "limit": Property(type: "integer", description: "Maximum rows (default 30, max 100, also byte-limited)"),
                "space": Property(type: "string", description: "\"model\" or \"paper\" (default active view)")
            ], required: ["layerName"])
        ),
        Tool(
            name: "export_csv",
            description: "Exports a structured dataset to a CSV file in the user-accessible ~/Documents/NovaCAD Exports folder and returns the exact path. Use for any tabular dataset the user asks to save. For workstation route distances, prefer export_workstation_travel_distances because it enumerates and routes the full drawing natively without filling model context.",
            inputSchema: JSONSchema(properties: [
                "datasetJSON": Property(type: "string", description: "JSON object encoded as a string: {\"columns\":[\"A\",\"B\"],\"rows\":[[\"1\",\"2\"]]}"),
                "filename": Property(type: "string", description: "Optional CSV filename")
            ], required: ["datasetJSON"])
        ),
        Tool(
            name: "get_insert_attributes",
            description: "List every ATTRIB tag/value on one INSERT (block reference), by its entity id (from read_drawing's \"entityId\" field for an \"insert\"-type row). Use this to see a workstation block's current attribute values (e.g. its NAME) before proposing a change.",
            inputSchema: JSONSchema(
                properties: [
                    "insertEntityId": Property(type: "integer", description: "The INSERT's entity id, from read_drawing")
                ],
                required: ["insertEntityId"]
            )
        ),
        Tool(
            name: "find_insert_at_point",
            description: "Find which top-level INSERT (block reference)'s bounding box contains a given world-space (x, y) point — use this to figure out which workstation block a loose label TEXT (one that is NOT already an ATTRIB child of a block, i.e. its \"ownerInsertId\" field from read_drawing is absent) is positioned inside of, by passing that TEXT's own position.",
            inputSchema: JSONSchema(
                properties: [
                    "x": Property(type: "number", description: "World-space X coordinate"),
                    "y": Property(type: "number", description: "World-space Y coordinate"),
                    "space": Property(type: "string", description: "\"model\" or \"paper\" (default active view)")
                ],
                required: ["x", "y"]
            )
        ),
        Tool(
            name: "propose_attribute_edits",
            description: "Stage a plan of one or more ATTRIB value changes on existing INSERTs (block references) for the user to review and approve — this does NOT modify the drawing itself. Use this once you know exactly which INSERT(s) and which ATTRIB tag to change (e.g. after reading a nearby label TEXT's content and using find_insert_at_point / get_insert_attributes to confirm the target). Also works for a tag that doesn't exist on the target yet — a brand-new ATTRIB is created rather than requiring the tag to already be present (matching AutoCAD's ATTEDIT only in that VALUES are what's edited; unlike ATTEDIT, a new tag with no existing attribute is created, not rejected). The user sees each proposed \"tag: old → new\" (or \"tag: (new attribute) → value\") change and must press Apply before anything is actually written. For changing the SAME tag/value across every object on one layer, prefer bulk_set_attribute_on_layer instead of calling this once per object.",
            inputSchema: JSONSchema(
                properties: [
                    "edits": Property(type: "array", description: "List of {insertEntityId, attributeTag, newValue} objects, each as a JSON object encoded as a string, e.g. '{\"insertEntityId\":42,\"attributeTag\":\"NAME\",\"newValue\":\"Station 7\"}'", items: .init(type: "string"))
                ],
                required: ["edits"]
            )
        ),
        Tool(
            name: "bulk_set_attribute_on_layer",
            description: "Stage the SAME attribute tag/value change across EVERY block reference (INSERT) on one layer, for the user to review and approve — this does NOT modify the drawing itself. Use this for requests like \"add an attribute called ROUTE with value R-7 to every object on layer CARRIER-STATIONS\" or \"set STATUS to ACTIVE on all MATERIAL-CARRIER blocks\" instead of calling propose_attribute_edits once per object. Works whether the target objects already have this tag (their value is updated) or not (a brand-new ATTRIB is created on each one) — the review card shows exactly which of each per object. Objects whose value already matches are skipped (not restaged as a no-op change). The user must press Apply before anything is actually written.",
            inputSchema: JSONSchema(
                properties: [
                    "layerName": Property(type: "string", description: "The layer whose block references should all receive this attribute"),
                    "attributeTag": Property(type: "string", description: "The ATTRIB tag to set on every object, e.g. \"ROUTE\" or \"STATUS\""),
                    "value": Property(type: "string", description: "The value to set that tag to on every matching object"),
                    "space": Property(type: "string", description: "\"model\" or \"paper\" (default active view)")
                ],
                required: ["layerName", "attributeTag", "value"]
            )
        ),

        // ---- Aisle network / dock apron tool catalog ----
        //
        // A real aisle centerline layer is fragmented (a plant layout with
        // 138 source segments split into 43+ disconnected pieces is typical
        // — see AisleNetwork.swift's own header comment for the measured
        // reference-file numbers) and often mixes centerlines with boundary
        // edge lines, so these tools exist in a specific order: analyze
        // first to see what's actually there, repair gaps before routing
        // (routing across a disconnected network fails honestly rather than
        // inventing a path), then shade for visualization. All four
        // geometry-creating tools (repair/route/shade_aisle_network/
        // shade_dock_aprons) stage their result for user review, same as
        // propose_attribute_edits — never applied by the tool call itself.
        Tool(
            name: "analyze_aisle_network",
            description: "Analyzes an aisle centerline layer's connectivity: how many disconnected pieces it's split into, every gap between them (with distance in feet and exact coordinates), and the aisle widths detected (either measured from parallel boundary lines, or read from the drawing's own \"13'-4\\\" AISLE\"-style text labels). Always call this BEFORE routing or shading an aisle network, since a real aisle layer is routinely fragmented into dozens of pieces that merely LOOK continuous.",
            inputSchema: JSONSchema(
                properties: [
                    "layerName": Property(type: "string", description: "The aisle centerline layer name, e.g. \"AISLE\""),
                    "space": Property(type: "string", description: "\"model\" or \"paper\" (default active view)")
                ],
                required: ["layerName"]
            )
        ),
        Tool(
            name: "repair_aisle_network",
            description: "Stages inferred bridging connectors for disconnected aisle components, iteratively reconnecting obvious chains at or below a physical distance limit. The user chooses targetLayerName: it may be the source layer, a different existing layer, or a new repair layer (default '<layerName>-REPAIRED'). Call analyze_aisle_network first; short aligned/T-junction gaps are common drafting slips, while large separations may represent walls or separate building wings.",
            inputSchema: JSONSchema(
                properties: [
                    "layerName": Property(type: "string", description: "The aisle centerline layer name"),
                    "space": Property(type: "string", description: "\"model\" or \"paper\" (default active view)"),
                    "maxGapDistanceFeet": Property(type: "number", description: "Maximum inferred connector distance in feet (default 10)"),
                    "targetLayerName": Property(type: "string", description: "Optional destination layer. Use the source layer to append repairs there, any other layer name to keep repairs separate, or omit for '<layerName>-REPAIRED'.")
                ],
                required: ["layerName"]
            )
        ),
        Tool(
            name: "find_route_endpoints",
            description: "Resolves a name to routable world-space coordinates: an individual dock door (\"Dock 4\"), a named dock group (\"blue docks\" — reduced to the centroid of its member doors), or a station/marketplace block by name (matches against INSERT block names, e.g. \"STN-101\"). Returns every match found, since names can be ambiguous. Use the returned x/y as the origin/destination for route_along_aisles.",
            inputSchema: JSONSchema(
                properties: [
                    "query": Property(type: "string", description: "A dock number, dock group name, or (partial) block name to search for"),
                    "space": Property(type: "string", description: "\"model\" or \"paper\" (default active view)")
                ],
                required: ["query"]
            )
        ),
        Tool(
            name: "route_along_aisles",
            description: "Routes one trip along an aisle network and reports BOTH one-way and round-trip distance in feet, broken down into on-aisle travel vs. the short connector legs at each end (docks/stations sit BESIDE aisles, not on them). The graph is built from TRUE AISLE CENTERLINES by default: a real aisle layer usually contains the two parallel BOUNDARY EDGE lines of each aisle, and routing those instead of the centre inflates distance roughly 1.5-2x or worse (no crossings at intersections, no way to change sides mid-aisle). Small gaps in a fragmented aisle layer are bridged in memory automatically so a drafting slip doesn't force a long detour; the reply always states which repairs and graph mode were used, so any surprising number can be checked. Set useSelectionAsOrigin=true to start from whatever the user currently has selected on canvas. Set measureOnly=true for distance without staging geometry.",
            inputSchema: JSONSchema(
                properties: [
                    "aisleLayerName": Property(type: "string", description: "The aisle layer to route along"),
                    "connectorLayerName": Property(type: "string", description: "Optional second layer to union with the aisle network (e.g. a hand-drawn connector layer)"),
                    "space": Property(type: "string", description: "\"model\" or \"paper\" (default active view)"),
                    "useSelectionAsOrigin": Property(type: "boolean", description: "If true, use the user's current canvas selection as the origin (call get_selected_objects first to confirm what is selected). Overrides originX/originY only when those are absent."),
                    "originX": Property(type: "number", description: "Origin world-space X (from find_route_endpoints)"),
                    "originY": Property(type: "number", description: "Origin world-space Y"),
                    "originLabel": Property(type: "string", description: "Human label for the origin (e.g. \"Marketplace MP-3\"). Also used as a name lookup when no coordinates and no selection are given."),
                    "destinationX": Property(type: "number", description: "Destination world-space X"),
                    "destinationY": Property(type: "number", description: "Destination world-space Y"),
                    "destinationLabel": Property(type: "string", description: "Human label for the destination (e.g. \"Station STN-101\")"),
                    "tripType": Property(type: "string", description: "\"oneWay\" or \"roundTrip\" — which figure to emphasise. BOTH are always reported regardless (default \"oneWay\")"),
                    "anchor": Property(type: "string", description: "Where a trip attaches to an object: \"nearestEdge\" (default, models a forklift leaving the closest point of the footprint), \"centroid\", or \"insertionPoint\""),
                    "centerlineMode": Property(type: "string", description: "\"auto\" (default — collapse boundary-line pairs to centerlines; correct for nearly every real drawing), \"centerlinesOnly\", or \"raw\" (route the layer verbatim; usually inflates distance — use only to diagnose)"),
                    "autoRepairFeet": Property(type: "number", description: "Bridge aisle gaps at or under this many feet in memory before routing (default 25). Repairs affect measurement only unless applied. Set 0 to disable."),
                    "routeLayerName": Property(type: "string", description: "Layer to stage the drawn route on (default \"AI-TRAVEL-PATHS\")"),
                    "measureOnly": Property(type: "boolean", description: "If true, report distance only and stage no geometry (default false)")
                ],
                required: ["aisleLayerName", "destinationX", "destinationY"]
            )
        ),
        Tool(
            name: "export_travel_distances",
            description: "THE BATCH TRAVEL-DISTANCE TOOL — use this for \"how far is it from <origin> to each <thing>\" (e.g. marketplace to every point of fit). Enumerates every block reference on a destination layer, resolves ONE shared origin (the user's canvas selection, a name, or explicit coordinates), routes each destination through the aisle network, and writes a CSV to ~/Documents/NovaCAD Exports. EVERY row carries BOTH one_way_ft and round_trip_ft, so one export answers either question. Also includes straight_line_ft and detour_ratio per row so an implausible number is immediately visible. Routes on true aisle centerlines and auto-repairs small gaps (see route_along_aisles for why this matters — routing raw boundary edge lines roughly doubles distances). Designed for huge drawings: it enumerates and routes natively without sending drawing entities through the conversation. Unroutable destinations stay in the CSV with a status explaining why, never silently dropped. Set drawPaths=true to also stage every routed path as editable polylines on one layer for visual verification.",
            inputSchema: JSONSchema(properties: [
                "destinationLayerName": Property(type: "string", description: "Layer containing the destination block references (workstations / points of fit)"),
                "aisleLayerName": Property(type: "string", description: "Primary aisle network layer"),
                "connectorLayerName": Property(type: "string", description: "Optional separate repair/connector layer to union with the primary aisle network"),
                "space": Property(type: "string", description: "\"model\" or \"paper\" (default active view)"),
                "useSelectionAsOrigin": Property(type: "boolean", description: "If true, use the user's current canvas selection as the shared origin — the normal way to measure from a marketplace the user just clicked"),
                "originQuery": Property(type: "string", description: "Reference dock, group, station, or block name used to resolve the shared origin"),
                "originX": Property(type: "number", description: "Optional explicit origin X (takes precedence over selection and name)"),
                "originY": Property(type: "number", description: "Optional explicit origin Y"),
                "tripType": Property(type: "string", description: "\"oneWay\" or \"roundTrip\" — which figure to quote in prose. BOTH columns are always written (default \"oneWay\")"),
                "anchor": Property(type: "string", description: "\"nearestEdge\" (default), \"centroid\", or \"insertionPoint\""),
                "centerlineMode": Property(type: "string", description: "\"auto\" (default), \"centerlinesOnly\", or \"raw\""),
                "autoRepairFeet": Property(type: "number", description: "Bridge aisle gaps at or under this many feet in memory before routing (default 25)"),
                "drawPaths": Property(type: "boolean", description: "If true, stage every routed path as editable polylines on one layer so the user can visually verify them (default false)"),
                "routeLayerName": Property(type: "string", description: "Layer for the drawn paths (default \"AI-TRAVEL-PATHS\")"),
                "filename": Property(type: "string", description: "Optional CSV filename")
            ], required: ["destinationLayerName", "aisleLayerName"])
        ),
        Tool(
            name: "get_selected_objects",
            description: "Reports what the user currently has SELECTED on the drawing canvas: each object's entity id, type, layer, block/display name, any text content, and its world-space footprint, plus the combined bounding box of the whole selection. Use this whenever the user refers to something by pointing rather than naming it — \"use this as the origin\", \"measure from the selected object\", \"what did I just click\". Large selections report the aggregate bounds with only the first objects listed individually.",
            inputSchema: JSONSchema(properties: [
                "space": Property(type: "string", description: "\"model\" or \"paper\" (default active view)")
            ], required: [])
        ),
        Tool(
            name: "draw_polylines",
            description: "Stages one or more polylines on the drawing for the user to review and apply — use this to make something VISUALLY VERIFIABLE (travel paths, a corridor you identified, an outline). Every path in one call goes on the SAME layer so the whole batch can be toggled, recoloured, or deleted together. Once applied these are ordinary fully-editable entities: the user can drag vertices, STRETCH, move, recolour, or delete them like any hand-drawn object. Note the routing tools can draw their own paths directly (route_along_aisles stages its route; export_travel_distances has drawPaths) — prefer those when the paths came from routing, and use this tool for paths you constructed yourself.",
            inputSchema: JSONSchema(properties: [
                "pathsJSON": Property(type: "string", description: "JSON array of paths, encoded as a string. Each path is either [[x,y],[x,y],...] or {\"points\":[[x,y],...]}. Example: '[[[0,0],[100,0],[100,50]]]'"),
                "layerName": Property(type: "string", description: "Layer to draw on (default \"AI-TRAVEL-PATHS\"). Keep a batch on one layer so it can be reviewed together."),
                "space": Property(type: "string", description: "\"model\" or \"paper\" (default active view)"),
                "closed": Property(type: "boolean", description: "If true, each path is closed into a filled shape instead of an open polyline (default false)"),
                "colorIndex": Property(type: "integer", description: "AutoCAD color index for the geometry; 256 = ByLayer (default)"),
                "replaceExistingLayerContent": Property(type: "boolean", description: "If true, clear anything already on the target layer first — use when redrawing a batch so paths don't stack up (default false)")
            ], required: ["pathsJSON"])
        ),
        Tool(
            name: "propose_explode_block",
            description: "Stage ungrouping directly editable curves from ONE local block instance, with Apply and Undo. Notes, fills, unsupported curves and nested blocks remain grouped in a private remainder block. Other instances of the original block are unchanged. Use when target geometry is inside a block: find the containing root insert with query_entities(types:[insert],visibleOnly:true), explain unpacking, then stage this tool. After the user applies, re-query and inspect the new object IDs before proposing geometry edits. Supports simple uniformly scaled 2D blocks; reports unsupported metadata/display properties rather than discarding them.",
            inputSchema: JSONSchema(properties: [
                "entityId": Property(type: "integer", description: "Root block instance ID on the active sheet/space, from query_entities or selection.")
            ], required: ["entityId"])
        ),
        Tool(
            name: "inspect_geometry",
            description: "Read exact editable 2D geometry for 1–16 object IDs, or the current selection if omitted. Returns points, polyline bulges/closed state, or arc/circle parameters in drawing coordinates, plus precise reasons for unsupported objects. Required before propose_geometry_edits; query_entities gives bounds, not exact geometry. Active sheet/space only.",
            inputSchema: JSONSchema(properties: [
                "entityIdsJSON": Property(type: "string", description: "JSON array of object IDs from query_entities/get_selected_objects, e.g. '[42,43]'. Omit to inspect the live selection.")
            ], required: [])
        ),
        Tool(
            name: "propose_geometry_edits",
            description: "Reshape or delete inspected existing CAD objects by staging exact replacements with a before/after preview, Apply and Undo. Preserves source layer/style and sheet. Supports flat 2D line, polyline (including bulges), arc and circle. Does not change blocks, text or dimensions. Inspect every source first at the current drawing revision; merged sources must share style. Only explicit source IDs are replaced, never their whole layer. A changed drawing invalidates the proposal.",
            inputSchema: JSONSchema(properties: [
                "editsJSON": Property(type: "string", description: "JSON array (max 16 edits, 64 source/replacement objects total). Each edit: {entityIds:[42],replacements:[shape,...]}. Empty replacements deletes those sources. Shapes: {type:'line',points:[[x,y],[x,y]]}; {type:'polyline',points:[[x,y],...],closed:false,bulges:[0,...]} (one bulge per vertex, signed tan(sweep/4), final open bulge 0); {type:'arc',points:[[startX,startY],[throughX,throughY],[endX,endY]]}; or {type:'arc',center:[x,y],radius:r,startAngle:degrees,endAngle:degrees} CCW; {type:'circle',center:[x,y],radius:r}. Use double quotes in JSON. Coordinates are drawing units. Preserve both wall faces and openings; annotations are not updated automatically.")
            ], required: ["editsJSON"])
        ),
        Tool(
            name: "query_entities",
            description: "Search rendered text, blocks, and line/arc/polyline geometry by layer, name or text. Use visibleOnly:true for objects in the current zoomed canvas area. Results have totalMatched and nextOffset; pages have row and byte limits. Use countOnly to size a job. Paper defaults to the active sheet; sheetName reads another sheet without moving the canvas.",
            inputSchema: JSONSchema(properties: [
                "types": Property(type: "array", description: "Entity types to include, e.g. [\"insert\"] or [\"text\"]. Omit for all supported types.", items: .init(type: "string")),
                "layerContains": Property(type: "string", description: "Only entities whose layer name contains this (case-insensitive)"),
                "nameContains": Property(type: "string", description: "For INSERTs: only those whose block/display name contains this"),
                "textContains": Property(type: "string", description: "For TEXT/MTEXT: only those whose content contains this"),
                "sheetName": Property(type: "string", description: "Exact paper sheet name from read_drawing. Use with space: paper; omitted means active sheet."),
                "space": Property(type: "string", description: "\"model\" or \"paper\" (default active view)"),
                "offset": Property(type: "integer", description: "Row offset for paging (default 0) — pass the previous reply's nextOffset to continue"),
                "limit": Property(type: "integer", description: "Maximum rows to return (default 30, max 100, also byte-limited)"),
                "visibleOnly": Property(type: "boolean", description: "Only objects intersecting the live canvas bounds; requires active space/sheet. Re-read after pan or zoom. Defaults false. Geometry bounds can overestimate curved shapes."),
                "countOnly": Property(type: "boolean", description: "If true, return only totalMatched with no rows — use to size a job first (default false)")
            ], required: [])
        ),
        Tool(
            name: "inspect_xrefs",
            description: "Lists the drawing's external references (xrefs) and, for each, the layers it contributes and how many entities it holds. IMPORTANT: xref content is ALREADY resolved and merged into the live drawing, so you never need to open the referenced files — even very large ones. Xref layers are named '<XREFNAME>|<layer>', and every layer-based tool here accepts either that qualified name or the bare layer name after the '|'. Use this to discover which layers exist inside an xref (e.g. to find the aisle or station layer of a referenced building shell) before routing or measuring against them.",
            inputSchema: JSONSchema(properties: [
                "nameContains": Property(type: "string", description: "Only xrefs whose name contains this (case-insensitive)"),
                "includeLayers": Property(type: "boolean", description: "Include each xref's layer name list (default true)")
            ], required: [])
        ),
        Tool(
            name: "shade_aisle_network",
            description: "Stages a shaded overlay covering the physical footprint of every aisle on a layer, for the user to review and approve. Aisle centerlines are zero-width, so each is buffered into a filled rectangle at its own measured/annotated width (or a fallback width where neither is known), rounded at every junction, and placed on a NEW '<layerName>-SHADED' layer — the original aisle geometry is never touched. The shapes intentionally overlap at junctions; the target layer's transparency (not per-shape opacity) should be set so overlaps don't look like dark blotches. IMPORTANT: once applied, this shading is made of ORDINARY, FULLY EDITABLE entities — every shaded region has draggable grips at each corner, so the user CAN select one and extend or reshape it (drag a corner grip, or use STRETCH with a crossing window over one end to lengthen that end), MOVE/ROTATE/SCALE/MIRROR/COPY it, recolor it, snap to its corners, double-click an edge to add a corner, or delete it — exactly like any hand-drawn object. NEVER tell the user that this geometry cannot be edited, extended, stretched or reshaped.",
            inputSchema: JSONSchema(
                properties: [
                    "layerName": Property(type: "string", description: "The aisle centerline layer to shade"),
                    "space": Property(type: "string", description: "\"model\" or \"paper\" (default active view)"),
                    "fallbackWidthFeet": Property(type: "number", description: "Width to use for aisle segments with no measured or annotated width, in feet (default 13.34, i.e. 13'-4\", the most common width found on typical plant layouts)")
                ],
                required: ["layerName"]
            )
        ),
        Tool(
            name: "shade_dock_aprons",
            description: "Detects dock doors (by their \"DOCK <n>\" text labels, across whatever layers carry them) and stages one apron shape per bank of consecutive, evenly-spaced doors, for the user to review and approve — the staging floor immediately inside the dock line where inbound/outbound freight is set down. Aprons are placed on a NEW 'Dock Apron-AI' layer, at a caller-supplied depth (dock-to-nearest-aisle distance varies too widely — from a few feet to over a thousand — to auto-measure reliably; pass depthSuggestionAisleLayerName to get an informed per-bank suggestion instead). Deterministic: call again after docks move to redraw aprons on the same layer with fresh positions. Once applied, each apron is an ORDINARY, FULLY EDITABLE shape with draggable corner grips — the user can resize/reshape/move/delete it like any other object, so never claim otherwise.",
            inputSchema: JSONSchema(
                properties: [
                    "space": Property(type: "string", description: "\"model\" or \"paper\" (default active view)"),
                    "depthFeet": Property(type: "number", description: "Apron depth inward from the dock line, in feet (default 40)"),
                    "endPaddingFeet": Property(type: "number", description: "Extra length added at each end of a bank's frontage, in feet (default 0)"),
                    "depthSuggestionAisleLayerName": Property(type: "string", description: "Optional: an aisle layer name to measure suggested per-bank depths against (reported for reference; does not change depthFeet automatically)")
                ],
                required: []
            )
        )
    ]
}
