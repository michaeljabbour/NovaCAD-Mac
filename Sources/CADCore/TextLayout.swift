import Foundation
import CoreGraphics
import CoreText

/// Shared text metrics for rendering, fitting and selection. Measurements use
/// the same Helvetica cap-height convention as the drawing renderer.
public enum TextLayout {
    private final class Cache: @unchecked Sendable {
        let font = CTFontCreateWithName("Helvetica" as CFString, 100, nil)
        let widths = NSCache<NSString, NSNumber>()
        init() { widths.countLimit = 4096 }
    }
    private static let cache = Cache()

    public static func width(_ text: String, height: CGFloat) -> CGFloat {
        if let cached = cache.widths.object(forKey: text as NSString) {
            return CGFloat(cached.doubleValue) * height
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): cache.font]))
        let normalized = CTLineGetTypographicBounds(line, nil, nil, nil) / Double(CTFontGetCapHeight(cache.font))
        cache.widths.setObject(NSNumber(value: normalized), forKey: text as NSString)
        return CGFloat(normalized) * height
    }

    public static func wrap(_ text: String, height: CGFloat, width: CGFloat) -> String {
        guard height > 0, width > 0, height.isFinite, width.isFinite else { return text }
        let available = Double(width / height * CTFontGetCapHeight(cache.font))
        return text.components(separatedBy: "\n").flatMap { paragraph -> [String] in
            guard !paragraph.isEmpty else { return [""] }
            let source = paragraph as NSString
            let typesetter = CTTypesetterCreateWithAttributedString(NSAttributedString(string: paragraph,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): cache.font]))
            var result: [String] = [], offset = 0
            while offset < source.length {
                var length = CTTypesetterSuggestLineBreak(typesetter, offset, available)
                if length == 0 { length = max(1, CTTypesetterSuggestClusterBreak(typesetter, offset, available)) }
                result.append(source.substring(with: NSRange(location: offset, length: length))
                    .trimmingCharacters(in: .whitespaces))
                offset += length
            }
            return result
        }.joined(separator: "\n")
    }
}

public extension TextItem {
    var localBounds: CGRect {
        let lines = text.components(separatedBy: "\n")
        let width = (lines.map { TextLayout.width($0, height: height) }.max() ?? 0) * max(widthFactor, 0.1)
        let totalHeight = height + CGFloat(max(0, lines.count - 1)) * height * 5 / 3
        var x: CGFloat = hAlign == 1 ? -width / 2 : hAlign == 2 ? -width : 0
        if mirroredX { x = -x - width }
        let y: CGFloat = vAlign == 3 ? -totalHeight : vAlign == 2 ? -totalHeight / 2
            : vAlign == 1 ? 0 : -(totalHeight - height)
        return CGRect(x: x, y: y, width: width, height: totalHeight)
    }

    var worldBounds: CGRect {
        localBounds.applying(CGAffineTransform(translationX: position.x, y: position.y)
            .rotated(by: rotationDegrees * .pi / 180))
    }
}
