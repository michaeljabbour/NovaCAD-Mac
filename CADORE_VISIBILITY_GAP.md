# CADCore Public API Visibility Audit

current_status = [~]

CADCore's `Package.swift` declares a `.library` target, and all the expected
types exist in the source files — but **some members are still `internal`**.
Each item's status is marked:

  [X] = fully public and working
  [~] = partially public (type is public but some members are internal)
  [ ] = still internal and needs work

## Every type that must be `public` in CADCore

### DXFModel.swift

[X] `ResolvedColor`
[X] `DXFLayer` (+ its member-initialiser, which is implicit)
[X] `DXFLinetype` (+ init)
[X] `XrefInfo` (+ init)
[X] `EntityKind` (+ `label`)
[X] `EntityRef`
[X] `PrimitiveStore`
[X] `InsertInstance` (+ init)
[X] `StrokeStore` (class) + `StrokeStore.Run` + `StrokeStore.Arc` (+ their inits)
[X] `RenderGroup` (+ init)
[X] `TextItem`
[X] `ParseStats`
[X] `DXFDocument` (class)
[~] `DXFDocument` members: `appendGroup`, `appendInsert`, `setInsert`,
    `modelGroups`, `paperGroups`, `modelBounds`, `paperBounds`, `modelFitBounds`,
    `paperFitBounds`, `inserts`, `modelInsertCount`, `unitsLabel`, `insUnits`,
    `blockStamps`, `stampableBlockNames`, `stats`, `sourceDXFURL`, `layers`,
    `linetypes`, `xrefs` — DXFDocument is a class type so stored properties
    are NOT implicitly public. Individual members need `public` annotation.
[X] `VisibilityState` (+ all properties + `isVisible`/`isSelectable`)

### DXFParser.swift

[X] `DXFParser` (struct — to reach its `parse`/`scanRaw`)
[X] `DXFParser.parse(url:progress:)`
[X] `DXFParser.scanRaw(url:progress:)` — confirmed public in CADCore
[X] `appendBulgeArc(from:to:bulge:into:)` — marked public, sufficient

### PackageLoader.swift

[X] `PackageLoadError`
[X] `PackageLoader` (enum type itself)
[ ] `PackageLoader.load(url:progress:)` — still internal, not in grep
[ ] `PackageLoader.canonicalKey(_:)` — still internal
[ ] `PackageLoader.drawingIndex(in:recursive:)` — still internal
[ ] `PackageLoader.findMainDrawing(in:hint:)` — still internal
[-] `PackageLoader.extractZip(_:to:)` — safe to keep internal (not called outside CADCore)
[ ] `PackageLoader.maxXrefFiles`, `maxDepth`, `maxMergedEntities` — still internal

### DWGConverter.swift

[X] `DWGConversionError`
[X] `DWGConverter` (struct type itself)
[ ] `DWGConverter.locateConverter()` — still internal
[ ] `DWGConverter.locateLibreDWG()` — still internal
[ ] `DWGConverter.anyConverterAvailable` — still internal
[ ] `DWGConverter.convertToDXF(url:)` (single-file, non-cached) — still internal
[ ] `DWGConverter.convertFolder(_:)` (non-cached) — still internal
[ ] `DWGConverter.convertFolderCached(_:bucket:)` — still internal
[ ] `DWGConverter.convertToDXFCached(url:bucket:)` — still internal
[ ] `DWGConverter.runConverterHidden(...)` (NovaCAD touches this) — still internal

### DWGCache.swift

[X] `DWGCache` (enum type itself)
[ ] `DWGCache.isEnabled` — still internal
[ ] `DWGCache.bucket(forPackage:)` — still internal
[ ] `DWGCache.currentConverterId()` — still internal
[ ] `DWGCache.loadManifest(in:)` — still internal
[ ] `DWGCache.saveManifest(_:in:)` — still internal
[ ] `DWGCache.isFresh(source:relativeKey:bucket:manifest:converter:)` — still internal
[ ] `DWGCache.stat(_:)` — still internal
[ ] `DWGCache.Entry` (nested struct) — still internal
[ ] `DWGCache.sha256Hex(_:)` — still internal
[ ] `DWGCache.Manifest` (typealias) — still internal
[ ] `DWGCache.clearBucket` — still internal

### GeometryBuilder.swift

[X] `GeometryBuilder` (enum type itself)
[ ] `GeometryBuilder.build(from:parseSeconds:progress:)` — still internal
[X] (The return type is `DXFDocument` which already has the class itself public)

### ACIPalette.swift

[X] `ACIPalette`
[X] `ACIPalette.rgb(forACI:)`
[ ] `ACIPalette.nearestACI(forRGB:)` — still internal

### UnitFormat.swift

[X] `UnitSystem`
[X] `LengthStyle`
[X] `MeasureFormat` (struct type itself)
[ ] `MeasureFormat` computed properties: `length`, `area`, `angle`, etc. — still internal

### MTextParser.swift

[X] `MTextParser`
[X] `MTextParser.plainText(from:)`
[ ] `MTextParser.plainSingleLineText(from:)` — still internal

### SplineEvaluator.swift

[X] `SplineEvaluator` (enum type itself)
[ ] `SplineEvaluator.tessellate(controlPoints:knots:weights:degree:samples:)` — still internal

### Geometry/Curve.swift

[X] `AABB`
[X] `LineSeg`
[X] `Circle2`
[X] `CircArc`
[X] `EllipseArc`
[X] `NURBS`
[X] `bulgeToArc(from:to:bulge:)`
[X] `arcToBulge(_:)`
[X] `BulgePolyline`
[X] `Curve2`
[~] Extension `Curve2` methods: `paramDomain`, `evaluate`, `derivative`,
    `tangent`, `isPeriodic`, `canExtend`, `bbox`, `reversed`, `length`,
    `pointAtLength`, `split(at:)`, `closestPoint(to:tol:)` — type is public,
    but `Curve2` is an enum with associated values; its extension methods
    inherit public visibility if the enum is public and the methods are not
    explicitly `private`/`internal`. Verify individual method annotations.

### Geometry/Intersect.swift

[X] `CurveHit`
[X] `Intersect.curves(_:_:tol:extendA:extendB:)`
[~] `Intersect.polylineHits(_:with:tol:)` — type `Intersect` is public but
    verify individual static method annotation

### Geometry/Offset.swift

[X] `OffsetSide`
[X] `Offset` (all static members: `segment`, `arc`, `circle`, `ellipse`, `spline`,
    `polyline`)

### Geometry/SplineFit.swift

[X] `SplineFit` (enum)
[~] `SplineFit.interpolate(fitPoints:closed:)` — type is public, verify
    method annotation

### Geometry/CurveBridge.swift

[X] `Vec2.init(_: CGPoint)` (extension)
[X] `Vec2.cgPoint` (computed var)
[X] `CurveRef`

## Total: ~150+ individual symbols need the `public` keyword (original estimate)

## Actual remaining gap (post-audit)

- **PackageLoader.swift**: ~5 static methods/properties still internal
- **DWGConverter.swift**: ~9 methods still internal
- **DWGCache.swift**: ~12 members still internal
- **GeometryBuilder.swift**: 1 method still internal
- **ACIPalette.swift**: 1 method still internal
- **UnitFormat.swift**: ~3 MeasureFormat members still internal
- **MTextParser.swift**: 1 method still internal
- **SplineEvaluator.swift**: 1 method still internal
- **DXFModel.swift**: DXFDocument (class) members need public annotation
- **Geometry/Curve.swift**: Verify extension methods inherit public
- **Geometry/Intersect.swift**: Verify polylineHits annotation
- **Geometry/SplineFit.swift**: Verify interpolate annotation

**Total remaining: ~35 individual symbols** still need the `public` keyword
(not 150+ as originally estimated — most types themselves are already public).