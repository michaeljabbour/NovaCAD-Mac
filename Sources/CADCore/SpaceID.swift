import Foundation

/// Model space vs. paper (layout) space — a drawing has one model space and
/// zero or more paper-space layouts. Extracted into CADCore (from NovaCAD's
/// EntityStore) because `DXFDocument` addresses its render groups/inserts by
/// space; the enum is a pure geometry-model concept, not an editing concern.
public enum SpaceID: Hashable, Sendable {
    case model
    case paper
}
