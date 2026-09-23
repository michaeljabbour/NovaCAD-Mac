# Non-Destructive Original Entity Editing Design

> Historical proposal, not the current save implementation. NovaCAD now edits
> the live entity store through undoable transactions and writes the complete
> document with `DocumentDXFWriter`. DWG inputs save to DXF; their source DWG is
> not rewritten. See [README.md](README.md#save--export) for current behavior.

## 1. Overview & Goals
When editing legacy CAD drawings, altering the original AutoCAD entity tables directly carries severe risks of file corruption and invalidation of structural metadata. To solve this, NovaCAD adopts a **non-destructive additive design override system**.

Instead of writing edits back to original DXF/DWG tables, edit operations (such as translations, color overrides, layer reassignments, and deletion tombstones) are registered as high-level metadata records. These overrides are written directly to the additive `NOVACAD-MARKUP` layer. When a document is reloaded, or during DXF merging, these metadata override records are parsed and dynamically applied on top of the original entity collection to reconstruct the modified workspace in-memory.

This design document outlines the technical specification, data formats, and the Swift implementation architecture.

---

## 2. Dynamic Override Architecture

### 2.1 Override Record Representation
Every edit operation on a non-markup (original) entity is represented by a `NonDestructiveOverride` record. These records are encoded into DXF entities (like lines, text, or custom dictionary objects) residing on the `NOVACAD-MARKUP` layer.

Each override targets a source entity by its handle (the unique, stable identifier in DWG/DXF).

```swift
import Foundation
import CoreGraphics
import CADCore

/// Represents the type of override mutation applied to a legacy entity.
public enum OverrideMutation: Codable, Equatable {
    /// Shifts/translates the geometry of the target entity by a 3D vector offset.
    case translate(dx: Double, dy: Double, dz: Double)
    
    /// Overrides the color of the target entity using an ACI (AutoCAD Color Index) or RGB value.
    case colorOverride(aci: Int16)
    
    /// Reassigns the target entity to a different layer name.
    case layerOverride(toLayer: String)
    
    /// Marks the target entity as deleted (a tombstone override).
    case delete
}

/// A structured override record binding a stable entity handle to a list of mutation operations.
public struct NonDestructiveOverride: Codable, Equatable {
    /// The unique stable handle of the original entity being modified.
    public let targetHandle: UInt64
    
    /// The sequence of mutations to apply.
    public var mutations: [OverrideMutation]
    
    public init(targetHandle: UInt64, mutations: [OverrideMutation]) {
        self.targetHandle = targetHandle
        self.mutations = mutations
    }
}
```

### 2.2 Serialization to `NOVACAD-MARKUP`
To persist these overrides natively without adding custom binary formats, they are serialized to DXF `TEXT` or `XRECORD` entities on the `NOVACAD-MARKUP` layer.
We embed the JSON representation of the `NonDestructiveOverride` array into specialized DXF text entries prefixed with a unique signature (e.g., `NOVACAD-OVERRIDE:`).

```swift
/// Manages serialization and deserialization of overrides on the markup layer.
public enum OverrideSerializer {
    public static let prefix = "NOVACAD-OVERRIDE:"
    
    /// Encodes a list of overrides into a string safe for DXF TEXT payloads.
    public static func encode(_ overrides: [NonDestructiveOverride]) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(overrides),
              let jsonString = String(data: data, encoding: .utf8) else {
            return nil
        }
        return "\(prefix)\(jsonString)"
    }
    
    /// Decodes a list of overrides from a DXF TEXT payload string, returning nil if the signature doesn't match.
    public static func decode(_ text: String) -> [NonDestructiveOverride]? {
        guard text.hasPrefix(prefix) else { return nil }
        let jsonPart = String(text.dropFirst(prefix.count))
        guard let data = jsonPart.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode([NonDestructiveOverride].self, from: data)
    }
}
```

---

## 3. Dynamic Override Pipeline & Layer Overlays

### 3.1 The Override Registry
A central manager, `OverrideRegistry`, is maintained in-memory for the active session. This registry reads all override markers from the markup layer, keeps them indexed by target handle, and provides APIs to apply them on the fly.

```swift
/// An in-memory cache and resolver for non-destructive overrides.
public final class OverrideRegistry {
    /// Maps original entity handles to their active list of mutations.
    private var overridesByHandle: [UInt64: [OverrideMutation]] = [:]
    
    public init() {}
    
    /// Clears and repopulates the registry by scanning all entities on the markup layer.
    public func reload(from store: EntityStore, markupLayerId: Int32) {
        overridesByHandle.removeAll()
        
        for i in store.headers.indices {
            let h = store.headers[i]
            guard !h.flags.contains(.deleted), h.layerId == markupLayerId else { continue }
            if h.type == .text {
                let p = Int(h.payload)
                let textPayload = store.texts[p]
                let textString = store.strings.string(for: textPayload.stringId)
                if let decodedOverrides = OverrideSerializer.decode(textString) {
                    for override in decodedOverrides {
                        self.register(override)
                    }
                }
            }
        }
    }
    
    /// Registers or updates an override record.
    public func register(_ override: NonDestructiveOverride) {
        if var existing = overridesByHandle[override.targetHandle] {
            existing.append(contentsOf: override.mutations)
            overridesByHandle[override.targetHandle] = existing
        } else {
            overridesByHandle[override.targetHandle] = override.mutations
        }
    }
    
    /// Resolves and returns mutations registered for a specific entity.
    public func mutations(for handle: UInt64) -> [OverrideMutation]? {
        return overridesByHandle[handle]
    }
    
    /// Appends a new mutation for a specific entity.
    public func appendMutation(for handle: UInt64, mutation: OverrideMutation) {
        var mutations = overridesByHandle[handle] ?? []
        mutations.append(mutation)
        overridesByHandle[handle] = mutations
    }
    
    /// Clears any registered overrides for a specific handle (reverting to original state).
    public func clearOverrides(for handle: UInt64) {
        overridesByHandle.removeValue(forKey: handle)
    }
}
```

### 3.2 Dynamic In-Memory Merging on Reload
During document loading or DXF reconstruction, the regenerator or document manager applies these overrides immediately after parsing.

```swift
/// Orchestrates applying non-destructive overrides over a live EntityStore.
public enum DynamicOverrideEngine {
    
    /// Processes and mutates the EntityStore in place, applying overrides dynamically.
    /// Original geometries and values are modified safely inside the temporary edit session.
    public static func apply(overrides: OverrideRegistry, to store: EntityStore, document: EditableDocument) {
        // Run as a single transaction to maintain undo/redo consistency
        document.transact("Apply Non-Destructive Overrides") { tx in
            for i in store.headers.indices {
                let id = EntityID(raw: Int32(i))
                let h = store.headers[i]
                guard !h.flags.contains(.deleted) else { continue }
                
                // Retrieve the stable handle for this entity
                let handle = h.handle
                guard let mutations = overrides.mutations(for: handle) else { continue }
                
                for mutation in mutations {
                    switch mutation {
                    case .delete:
                        tx.delete(id)
                        
                    case .colorOverride(let aci):
                        tx.modifyHeader(id) { header in
                            header.aci = aci
                        }
                        
                    case .layerOverride(let layerName):
                        tx.modifyHeader(id) { header in
                            // Ensure layer exists and retrieve its ID
                            let layerId = MarkupStore.ensureLayer(named: layerName, in: document.store.parsedDocument)
                            header.layerId = layerId
                        }
                        
                    case .translate(let dx, let dy, let dz):
                        tx.modifyPayload(id) { payload in
                            let transform = Transform2.translation(dx: dx, dy: dy)
                            EntityTransform.apply(transform, to: &payload, mirrtext: false)
                            // Note: 3D z-translation handles may be integrated here as required by 3D views.
                        }
                    }
                }
            }
        }
    }
}

// Extension placeholder demonstrating integration with parsed document structure
private extension EntityStore {
    var parsedDocument: EditableParsedDocument {
        // Retargeting/lookup placeholder
        fatalError("Resolved dynamically from DocumentSession context")
    }
}
```

---

## 4. User Interaction & Operations

When the user attempts to move, delete, or alter the color of an original drawing entity:
1. Instead of mutating the original AutoCAD entity's database records directly, the system intercepts the action.
2. The system adds/appends a `NonDestructiveOverride` entity to the transaction list.
3. The mutation is saved as a JSON-encoded `TEXT` block on the `NOVACAD-MARKUP` layer.
4. During rendering, `RegenCoordinator` reads the override registry to dynamically offset or recolor the source entities, displaying the edited result in real-time.
5. Deletion shifts the entity to invisible/deleted states in-memory during session load, but the raw geometry remains completely untouched on disk.

This keeps legacy DWG/DXF files safe from writer errors, maintaining 100% round-trip fidelity for external AutoCAD users.
