# NovaCAD Native DWG Writing Evaluation

> Research document. Native DWG writing remains unimplemented. The current
> supported save path is full-document DXF export; see [README.md](README.md#save--export).

## 1. Context & Objective
NovaCAD currently reads DWG through conversion and edits a live DXF entity store
(see `IMPLEMENTED_FEATURES.md`):
- Core drawing assets in **DWG** format are read-only and converted to **DXF** via external command-line utilities (ODA File Converter or GNU LibreDWG fallback) for byte-level parsing by `CADCore` (implemented in Swift).
- Save/Save As writes the complete edited document as DXF via `DocumentDXFWriter`. Separate primitive-markup exporters remain available through `DXFWriter`.
- Native **DWG writing** (directly outputting binary DWG files) is not yet supported. This document evaluates options, licensing, architecture, and a concrete path forward for introducing native DWG writing capabilities to NovaCAD.

---

## 2. Technical Evaluation of Options

### Option A: Open Design Alliance (ODA) SDK Integration
The Open Design Alliance (ODA) is the industry standard for DWG reading and writing outside of Autodesk. They offer the **ODA Drawings SDK** (formerly Teigha/Drawings).

#### Implementation Details
- **Architecture**: A set of native C++ dynamic libraries/SDK containing APIs to build, query, modify, and write `.dwg` database structures directly.
- **Integration Seam**: Since NovaCAD is a native macOS Swift app, integrating ODA would involve creating an Objective-C++ (`.mm`) or C wrapper layer to bridge Swift models to ODA's C++ native database objects (e.g., `OdDbDatabase`, `OdDbBlockTable`, `OdDbEntity`).
- **Fidelity**: 100% professional grade. It has full support for every DWG version (from ancient R12 up to the latest AC1032/AutoCAD 2018 format), complex geometries, tables, block references, and paper space layouts.

#### Licensing & Commercial Viability
- **License Type**: Proprietary commercial membership.
- **Cost**: Requires an ODA Corporate, Sustaining, or Founding Membership. Membership fees start around \$2,000–\$5,000+ USD per year depending on organization size and target distribution, with potential royalties for certain commercial deployments.
- **Suitability**: Strictly necessary for enterprise-grade, high-performance native DWG editing applications that cannot rely on command-line bridge conversions.

---

### Option B: Command-Line Bridge Roundtrip (The Recommended Near-Term Path)
Instead of linking an expensive, proprietary C++ library directly into the Swift codebase, NovaCAD can leverage its existing integration with the **ODA File Converter CLI** and **GNU LibreDWG** to achieve DWG writing via a DXF-to-DWG bridge pipeline.

#### Implementation Details
1. **DXF Generation**: Generate a pristine DXF containing the modified/merged geometry using the already-robust `DXFWriter`.
2. **CLI Bridge Execution**: Use the local installation of the ODA File Converter or LibreDWG CLI in reverse (DXF → DWG) to generate a binary `.dwg` file from the DXF.
3. **Execution Commands**:
   - **ODA File Converter** (hidden cocoa-launched Qt application CLI):
     ```sh
     # Arguments: <inFolder> <outFolder> <outVersion> <outType> <recurse> <audit> [filter]
     ODAFileConverter /path/to/dxf/dir /path/to/dwg/dir ACAD2018 DWG 0 1 "*.DXF"
     ```
   - **GNU LibreDWG** (`dwgwrite` or `dxf2dwg` binary if compiled with write support, or `dwgconvert` utility):
     ```sh
     # Converts a DXF to DWG format
     dwgwrite -y --as r2000 -o /path/to/output.dwg /path/to/input.dxf
     ```

#### Evaluation
- **Pros**:
  - Extremely cost-effective (free under existing installations).
  - Reuses NovaCAD's fully verified `DXFWriter` and `DWGConverter` infrastructure.
  - Zero-risk to current codebase stability and build setup.
  - No licensing overhead or expensive third-party library bundling inside the App Store bundle.
- **Cons**:
  - Requires ODA File Converter (or LibreDWG) to be present on the host machine.
  - Slower than in-memory binary generation due to file I/O overhead.

---

### Option C: Custom Swift Binary DWG Writer
Developing a custom binary encoder in Swift that serializes CADCore structures directly into DWG binary format (which is highly complex, compressed, and relies heavily on bit-packing, custom CRC checksums, and secret-key encryption on some DWG headers).

#### Evaluation
- **Pros**: Zero external dependencies.
- **Cons**: Monolithic, highly error-prone undertaking. Decoding DWG is already exceptionally hard; writing a valid binary DWG from scratch requires years of engineering work to avoid corrupting drawings in AutoCAD. **Strongly discouraged.**

---

## 3. Concrete Recommended Implementation Path

We recommend implementing **Option B (DXF-to-DWG Command-Line Bridge)** as the immediate native DWG writing capability in NovaCAD. This can be integrated cleanly without introducing bulky commercial binary SDKs, keeping the codebase lightweight and highly maintainable.

### Recommended Steps:

#### Step 1: Extend `DWGConverter` with DXF-to-DWG writing capability
We can add static methods to `DWGConverter` inside `CADCore` to handle reverse conversion:
```swift
/// Converts a .dxf file at `url` to a .dwg file and returns the resulting file URL.
public static func convertToDWG(url: URL) throws -> URL {
    // 1. Check for ODA File Converter or LibreDWG write tools
    // 2. Setup standard input/output directories in temporary storage
    // 3. Exec CLI tool with DXF -> DWG parameters
    // 4. Return resulting .dwg URL
}
```

#### Step 2: Implement Save/Export workflows in the Editor UI
- When a user selects **"Save As... (.dwg)"** or **"Export to DWG"**, the application first calls `DXFWriter` to write out the full drawing with annotations to a temporary DXF file.
- The app then calls `DWGConverter.convertToDWG(url:)` on the temporary DXF file.
- The resulting `.dwg` binary is saved to the user-selected destination.

#### Step 3: Graceful Fallbacks & User Messaging
- If neither ODA File Converter nor LibreDWG is found, display a descriptive alert pointing the user to download the ODA File Converter (similar to the warning currently shown for reading).
- Offer the option to fall back to exporting as standard `.dxf` (which works natively and instantly).

---

## 4. Summary Matrix

| Metric | Option A: ODA SDK | Option B: CLI Bridge (Recommended) | Option C: Custom Swift Writer |
| :--- | :--- | :--- | :--- |
| **Fidelity / Quality** | Excellent | Excellent (Leverages ODA engine) | Extremely Poor / Untrusted |
| **Implementation Effort** | Very High (ObjC++ bridging) | Low (Leverages existing `DWGConverter`) | Extremely High (Multiple years) |
| **Licensing Cost** | \$2,000–\$5,000+/year | Free (\$0) | Free (\$0) |
| **App Bundle Size** | Large (+30-50MB C++ dylibs) | Negligible (0MB) | Negligible (0MB) |
| **Dependencies** | Hard embedded dependency | Loose external dependency | None |
