// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NovaCAD",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "NovaCAD", targets: ["DWGViewer"]),
        .library(name: "CADCore", targets: ["CADCore"]),
    ],
    targets: [
        .target(
            name: "CADCore",
            path: "Sources/CADCore",
            exclude: ["LICENSE-NOTICE.md"]
        ),
        .executableTarget(
            name: "DWGViewer",
            dependencies: [
                "CADCore",
            ],
            path: "Sources/DWGViewer",
            // No `resources:` declaration — see `PGPFile.defaultContents`'s
            // doc comment for why: this was the ONLY runtime-needed resource
            // in this target, and SwiftPM's resource-bundle mechanism for an
            // executable is fundamentally incompatible with a validly-signed
            // `.app` (its `Bundle.module` accessor requires the bundle to
            // sit at the app's TOP LEVEL, a location `codesign --deep`
            // refuses to seal — see Scripts/build_app.sh's own history on
            // this). `acad.pgp`'s content is now embedded directly as a
            // Swift string literal instead; `exclude:` keeps the on-disk
            // file (retained purely as a human-readable reference/diff
            // target — see `PGPFile.defaultContents`) from tripping
            // SwiftPM's "unhandled file" build warning.
            exclude: ["Resources/acad.pgp"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "DWGViewerTests",
            dependencies: [
                "DWGViewer",
                "CADCore",
            ],
            path: "Tests/DWGViewerTests"
        ),
    ]
)
