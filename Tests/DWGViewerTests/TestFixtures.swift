import Foundation

/// Locates hand-authored fixture DXFs in `Tests/Fixtures/`. Not declared as a
/// SwiftPM resource (that mechanism can't reference paths outside a target's
/// own directory) — resolved directly from the source file's location instead,
/// which works whether tests run via `swift test` or Xcode.
enum TestFixtures {
    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/DWGViewerTests/
            .deletingLastPathComponent()   // Tests/
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }
}
