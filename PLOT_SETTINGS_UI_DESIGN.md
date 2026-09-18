# Technical Proposal & Interface Blueprint: Plot Settings UI Design

## 1. Overview & Goals
The goal of this design is to expose comprehensive Plot and Print Settings in the NovaCAD user interface. This enables users to configure drawings for high-fidelity physical plotting or digital export (PDF, raster formats). 

The design maintains NovaCAD's professional, native macOS layout paradigm, seamlessly integrating with SwiftUI, Swift/Mac systems, and the underlying `CADCore` engine.

Key capability targets:
- **Paper Sizes:** ISO (A0–A4), ANSI (A–E), Arch (A–E), and custom sizes.
- **Orientations:** Portrait vs. Landscape.
- **Plot Styles (Pen tables):** Monochrome, Grayscale, Color (by ACI/RGB).
- **Scale and Margins:** Scale-to-fit vs. custom plot scales, print margins.
- **Export Formats:** High-fidelity PDF, Vector SVG, or Raster PNG/JPEG.
- **Live Print Preview:** Integrated vector preview utilizing the existing `CGRenderCore` rendering pipeline.

---

## 2. Technical Architecture & State Model

### 2.1 State Representation (`PlotSettings`)
To track plot configurations per document, a unified `PlotSettings` model is introduced. This model resides within `DocumentSession` (ensuring per-tab state storage):

```swift
import Foundation
import CoreGraphics

public struct PlotSettings: Equatable, Codable {
    public enum PaperSize: String, CaseIterable, Codable {
        case isoA0 = "ISO A0 (841 x 1189 mm)"
        case isoA1 = "ISO A1 (594 x 841 mm)"
        case isoA2 = "ISO A2 (420 x 594 mm)"
        case isoA3 = "ISO A3 (297 x 420 mm)"
        case isoA4 = "ISO A4 (210 x 297 mm)"
        case ansiA = "ANSI A (8.5 x 11 in)"
        case ansiB = "ANSI B (11 x 17 in)"
        case ansiC = "ANSI C (17 x 22 in)"
        case ansiD = "ANSI D (22 x 34 in)"
        case ansiE = "ANSI E (34 x 44 in)"
        case archA = "Arch A (9 x 12 in)"
        case archB = "Arch B (12 x 18 in)"
        case archC = "Arch C (18 x 24 in)"
        case archD = "Arch D (24 x 36 in)"
        case archE = "Arch E (36 x 48 in)"
        case custom = "Custom Size"
        
        public var dimensionsInches: CGSize {
            switch self {
            case .isoA0: return CGSize(width: 33.11, height: 46.81)
            case .isoA1: return CGSize(width: 23.39, height: 33.11)
            case .isoA2: return CGSize(width: 16.54, height: 23.39)
            case .isoA3: return CGSize(width: 11.69, height: 16.54)
            case .isoA4: return CGSize(width: 8.27, height: 11.69)
            case .ansiA: return CGSize(width: 8.5, height: 11.0)
            case .ansiB: return CGSize(width: 11.0, height: 17.0)
            case .ansiC: return CGSize(width: 17.0, height: 22.0)
            case .ansiD: return CGSize(width: 22.0, height: 34.0)
            case .ansiE: return CGSize(width: 34.0, height: 44.0)
            case .archA: return CGSize(width: 9.0, height: 12.0)
            case .archB: return CGSize(width: 12.0, height: 18.0)
            case .archC: return CGSize(width: 18.0, height: 24.0)
            case .archD: return CGSize(width: 24.0, height: 36.0)
            case .archE: return CGSize(width: 36.0, height: 48.0)
            case .custom: return CGSize(width: 8.5, height: 11.0)
            }
        }
    }

    public enum Orientation: String, CaseIterable, Codable {
        case portrait = "Portrait"
        case landscape = "Landscape"
    }

    public enum PlotStyleTable: String, CaseIterable, Codable {
        case monochrome = "monochrome.ctb"
        case grayscale = "grayscale.ctb"
        case acadColor = "acad.ctb"
        case none = "None"
    }

    public enum PlotScale: Equatable, Codable {
        case fit
        case custom(drawingUnits: Double, paperUnits: Double) // e.g. 1 Unit = 10mm
    }
    
    public enum ExportFormat: String, CaseIterable, Codable {
        case pdf = "PDF"
        case svg = "SVG"
        case png = "PNG"
        case jpeg = "JPEG"
    }

    public var paperSize: PaperSize = .ansiB
    public var customWidthInches: Double = 11.0
    public var customHeightInches: Double = 17.0
    public var orientation: Orientation = .landscape
    public var styleTable: PlotStyleTable = .acadColor
    public var scale: PlotScale = .fit
    public var marginLeft: Double = 0.25
    public var marginRight: Double = 0.25
    public var marginTop: Double = 0.25
    public var marginBottom: Double = 0.25
    public var exportFormat: ExportFormat = .pdf
    public var resolutionDPI: Double = 300.0 // Relevant for raster export (PNG/JPEG)
    
    public var computedPaperSize: CGSize {
        if paperSize == .custom {
            return CGSize(width: customWidthInches, height: customHeightInches)
        }
        let dims = paperSize.dimensionsInches
        return orientation == .landscape 
            ? CGSize(width: max(dims.width, dims.height), height: min(dims.width, dims.height))
            : CGSize(width: min(dims.width, dims.height), height: max(dims.width, dims.height))
    }
}
```

### 2.2 Integration with existing systems
- **`DocumentSession` extension:**
  ```swift
  @Published public var plotSettings = PlotSettings()
  ```
- **`CGRenderCore` Enhancement:** 
  The rendering core will accept an optional `PlotSettings` parameter. When rendering for a plot or plot preview, line widths, line colors (e.g. forced to pure black for `.monochrome` style), and scaling parameters will adapt to this structural model.

---

## 3. UI Layout & Wireframe Design

To offer a smooth user experience, Plot Settings are displayed in a native Mac modal sheet presented when the user selects "Plot / Export" from the ribbon or main menu.

### 3.1 Sheet Layout Architecture

The modal window is structured as a two-column layout:
```
+-------------------------------------------------------------------------+
|  Plot & Export Setup                                                    |
+------------------------------------------------------+------------------+
|                                                      |                  |
|  [ Settings Column (Left) ]                          | [ Live Preview ] |
|                                                      | (Right)          |
|  +-- Paper & Format -------------------------------+ |                  |
|  | Size:      [ ANSI B (11 x 17 in)            [v] ] | |--------------| |
|  | Orient:    ( ) Portrait   (*) Landscape         | | |            | | |
|  +-------------------------------------------------+ | |  Drawing    | | |
|                                                      | |  Preview    | | |
|  +-- Plot Scale -----------------------------------+ | |  Area       | | |
|  | [x] Scale to Fit                                | | |            | | |
|  | Custom:    [ 1.0 ] Paper Inch = [ 10.0 ] Units  | | |------------| | |
|  +-------------------------------------------------+ |                  |
|                                                      | Paper: 11" x 17" |
|  +-- Margins (inches) -----------------------------+ | Scale: 1" = 10U  |
|  | Left: [0.25]  Right: [0.25]  Top: [0.25]  Bot: [0.25]                |
|  +-------------------------------------------------+ |                  |
|                                                      |                  |
|  +-- Style & Format -------------------------------+ |                  |
|  | Style:     [ monochrome.ctb                 [v] ] |                  |
|  | Format:    [ PDF                            [v] ] |                  |
|  | DPI:       [ 300                            [v] ] |                  |
|  +-------------------------------------------------+ |                  |
|                                                      |                  |
|                                                      |                  |
|  [Cancel]                                    [ Plot / Export ]          |
+------------------------------------------------------+------------------+
```

### 3.2 SwiftUI Component Blueprint (`PlotSettingsView`)

The implementation utilizes modern SwiftUI control styling conforming to macOS-native guidelines:

```swift
import SwiftUI
import CADCore

struct PlotSettingsView: View {
    @ObservedObject var session: DocumentSession
    @Binding var isPresented: Bool
    
    @State private var settings: PlotSettings = PlotSettings()
    
    var body: some View {
        HStack(spacing: 0) {
            // Left Column: Settings Panel
            VStack(alignment: .leading, spacing: 16) {
                Text("Plot & Export Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Section: Paper & Format
                        GroupBox(label: Label("Paper & Layout", systemImage: "doc.text")) {
                            VStack(alignment: .leading, spacing: 8) {
                                Picker("Paper Size", selection: $settings.paperSize) {
                                    ForEach(PlotSettings.PaperSize.allCases, id: \.self) { size in
                                        Text(size.rawValue).tag(size)
                                    }
                                }
                                
                                if settings.paperSize == .custom {
                                    HStack {
                                        TextField("Width", value: $settings.customWidthInches, format: .number)
                                            .textFieldStyle(.roundedBorder)
                                        Text("x")
                                        TextField("Height", value: $settings.customHeightInches, format: .number)
                                            .textFieldStyle(.roundedBorder)
                                        Text("inches")
                                    }
                                }
                                
                                Picker("Orientation", selection: $settings.orientation) {
                                    ForEach(PlotSettings.Orientation.allCases, id: \.self) { orient in
                                        Text(orient.rawValue).tag(orient)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                            .padding(8)
                        }
                        
                        // Section: Scale & Margins
                        GroupBox(label: Label("Plot Scale & Margins", systemImage: "arrow.up.and.down.and.arrow.left.and.right")) {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle("Fit to Paper Boundaries", isOn: Binding(
                                    get: { settings.scale == .fit },
                                    set: { isFit in settings.scale = isFit ? .fit : .custom(drawingUnits: 1.0, paperUnits: 1.0) }
                                ))
                                
                                if case .custom(let drawingUnits, let paperUnits) = settings.scale {
                                    HStack {
                                        TextField("Paper Inches", value: Binding(
                                            get: { paperUnits },
                                            set: { settings.scale = .custom(drawingUnits: drawingUnits, paperUnits: $0) }
                                        ), format: .number)
                                        .frame(width: 50)
                                        
                                        Text("Inch =")
                                        
                                        TextField("Drawing Units", value: Binding(
                                            get: { drawingUnits },
                                            set: { settings.scale = .custom(drawingUnits: $0, paperUnits: paperUnits) }
                                        ), format: .number)
                                        .frame(width: 60)
                                        
                                        Text("Units")
                                    }
                                }
                                
                                Divider().padding(.vertical, 4)
                                
                                Text("Margins (Inches)").font(.caption).foregroundColor(.secondary)
                                HStack(spacing: 8) {
                                    VStack {
                                        Text("L").font(.caption2)
                                        TextField("Left", value: $settings.marginLeft, format: .number).frame(width: 40)
                                    }
                                    VStack {
                                        Text("R").font(.caption2)
                                        TextField("Right", value: $settings.marginRight, format: .number).frame(width: 40)
                                    }
                                    VStack {
                                        Text("T").font(.caption2)
                                        TextField("Top", value: $settings.marginTop, format: .number).frame(width: 40)
                                    }
                                    VStack {
                                        Text("B").font(.caption2)
                                        TextField("Bottom", value: $settings.marginBottom, format: .number).frame(width: 40)
                                    }
                                }
                            }
                            .padding(8)
                        }
                        
                        // Section: Plot Styles & Export Options
                        GroupBox(label: Label("Styles & Rendering", systemImage: "paintbrush")) {
                            VStack(alignment: .leading, spacing: 8) {
                                Picker("Plot Style (CTB)", selection: $settings.styleTable) {
                                    ForEach(PlotSettings.PlotStyleTable.allCases, id: \.self) { style in
                                        Text(style.rawValue).tag(style)
                                    }
                                }
                                
                                Picker("Output Format", selection: $settings.exportFormat) {
                                    ForEach(PlotSettings.ExportFormat.allCases, id: \.self) { format in
                                        Text(format.rawValue).tag(format)
                                    }
                                }
                                
                                if settings.exportFormat == .png || settings.exportFormat == .jpeg {
                                    Picker("Resolution (DPI)", selection: $settings.resolutionDPI) {
                                        Text("72 DPI (Draft)").tag(72.0)
                                        Text("150 DPI (Standard)").tag(150.0)
                                        Text("300 DPI (High-Res/Print)").tag(300.0)
                                        Text("600 DPI (Ultra-Detail)").tag(600.0)
                                    }
                                }
                            }
                            .padding(8)
                        }
                    }
                }
                
                // Footer buttons
                HStack {
                    Button("Cancel", role: .cancel) {
                        isPresented = false
                    }
                    .keyboardShortcut(.cancelAction)
                    
                    Spacer()
                    
                    Button("Export / Plot") {
                        executePlot()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 320)
            .padding()
            
            Divider()
            
            // Right Column: Rendered Preview & Stats
            VStack(spacing: 12) {
                Text("Print Preview")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                // Interactive Vector Canvas Preview Container
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white)
                        .shadow(radius: 4)
                        
                    if let doc = session.document {
                        PlotPreviewCanvas(document: doc, settings: settings)
                            .padding(16)
                    } else {
                        Text("No drawing loaded")
                            .foregroundColor(.gray)
                    }
                }
                .aspectRatio(settings.computedPaperSize.width / settings.computedPaperSize.height, contentMode: .fit)
                .frame(minWidth: 350, minHeight: 250)
                
                // Informational labels below the canvas
                VStack(spacing: 4) {
                    Text("Target Dimensions: \(String(format: "%.2f", settings.computedPaperSize.width))\" x \(String(format: "%.2f", settings.computedPaperSize.height))\"")
                    if case .fit = settings.scale {
                        Text("Scale: Scale-to-Fit")
                    } else if case .custom(let du, let pu) = settings.scale {
                        Text("Scale: \(String(format: "%.3f", pu))\" = \(String(format: "%.3f", du)) Units")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 780, height: 580)
        .onAppear {
            // Clone configuration from document session if previously configured
            self.settings = session.plotSettings
        }
    }
    
    private func executePlot() {
        // Persist local selection to global session
        session.plotSettings = settings
        
        // Dispatch export trigger to drawing controllers / filesystems
        isPresented = false
    }
}
```

---

## 4. UI Entry Points & Ribbon Integration

### 4.1 Ribbon Addition
The "Plot / Export" interface will be triggered directly from the main control interfaces:
1. **Ribbon View (`RibbonView.swift`):** Introduce a prominent "Plot" button under the "File" or "Output" group using `systemImage: "printer"`.
2. **Main Menu / Commands Menu:** Add "Plot..." (with standard Mac hotkey `⌘P`) pointing directly to this state sheet trigger.
3. **Command Line / PGP Command:** Standard command alias mapping:
   - `PLOT` or `PRINT` command targets opening the print view model sheet.

---

## 5. Live Print Preview Pipeline (`PlotPreviewCanvas`)

To guarantee accurate vector representations of colors and lineweights, we instantiate a dedicated, non-interactive `PlotPreviewCanvas` view using CoreGraphics.

```swift
struct PlotPreviewCanvas: NSViewRepresentable {
    let document: DXFDocument
    let settings: PlotSettings
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // Render preview bounds to fit view width/height.
        // Applies PlotSettings.styleTable color transformations dynamically.
    }
}
```
During updates, color-maps (`.monochrome` translates all non-background entities to `CGColor.black`, `.grayscale` translates custom rgb to gray scale luminosity) are applied transparently prior to dispatching commands to `CGRenderCore`.
