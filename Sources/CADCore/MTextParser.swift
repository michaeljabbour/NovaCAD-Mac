//
//  MTextParser.swift
//  DWGViewer
//
//  Converts AutoCAD MTEXT/TEXT raw strings (DXF group codes 1/3) into plain
//  displayable text. MTEXT embeds inline formatting codes such as
//  `\fArial|b0;` (font), `\H2.5x;` (height), `\P` (paragraph break),
//  `{...}` grouping braces, `\S...;` stacked fractions, `\U+XXXX` unicode
//  escapes, `^I`/`^J` control pairs, and the legacy `%%c`/`%%d`/`%%p`
//  symbol codes shared with single-line TEXT/ATTRIB entities.
//
//  This parser strips all formatting and yields only the visible text.
//  Parsing is a single linear scan with a brace-depth counter — the MTEXT
//  format is not regular (codes nest and have context-dependent
//  terminators), so no regular expressions are used.
//

import Foundation

public enum MTextParser {

    /// Converts a raw MTEXT string (DXF group 1/3 content) to plain text.
    /// Newlines in the result are "\n". Formatting codes are stripped.
    public static func plainText(from raw: String) -> String {
        let chars = Array(raw)
        var out = String()
        out.reserveCapacity(chars.count)
        var i = 0
        var braceDepth = 0

        while i < chars.count {
            let c = chars[i]
            switch c {
            case "{":
                // Group start: track depth, emit nothing.
                braceDepth += 1
                i += 1
            case "}":
                // Group end: track depth, emit nothing.
                if braceDepth > 0 { braceDepth -= 1 }
                i += 1
            case "\\":
                i = consumeBackslashCode(chars, at: i, into: &out)
            case "^":
                // Caret control pairs: ^I = tab, ^J = newline, others dropped.
                if i + 1 < chars.count {
                    let next = chars[i + 1]
                    if next == "I" {
                        out.append("\t")
                    } else if next == "J" {
                        out.append("\n")
                    }
                    i += 2
                } else {
                    out.append(c) // trailing caret: keep literal
                    i += 1
                }
            case "%":
                if let (emitted, consumed) = percentCode(chars, at: i) {
                    out.append(emitted)
                    i += consumed
                } else {
                    out.append(c)
                    i += 1
                }
            default:
                out.append(c)
                i += 1
            }
        }
        return out
    }

    /// Converts a raw single-line TEXT/ATTRIB string: handles only %%-codes.
    public static func plainSingleLineText(from raw: String) -> String {
        let chars = Array(raw)
        var out = String()
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if chars[i] == "%", let (emitted, consumed) = percentCode(chars, at: i) {
                out.append(emitted)
                i += consumed
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    // MARK: - Private helpers

    /// Handles a backslash escape starting at `i` (where `chars[i] == "\\"`).
    /// Appends any resulting text to `out` and returns the index of the
    /// first character after the consumed code.
    private static func consumeBackslashCode(
        _ chars: [Character], at i: Int, into out: inout String
    ) -> Int {
        guard i + 1 < chars.count else {
            out.append("\\") // trailing backslash: keep literal
            return i + 1
        }
        let code = chars[i + 1]
        switch code {
        case "\\", "{", "}":
            // Escaped literal backslash / brace.
            out.append(code)
            return i + 2
        case "P":
            // Paragraph break (uppercase only; lowercase \p is a property code).
            out.append("\n")
            return i + 2
        case "~":
            // Non-breaking space: emit a regular space.
            out.append(" ")
            return i + 2
        case "O", "o", "L", "l", "K", "k":
            // Bare overline / underline / strikethrough toggles: no argument.
            return i + 2
        case "f", "F", "H", "W", "C", "c", "T", "Q", "A", "p":
            // Codes whose argument runs up to and including the next ';'
            // (font, height, width, color, tracking, oblique, alignment,
            // paragraph properties). If no ';' is found, consume to end.
            var j = i + 2
            while j < chars.count && chars[j] != ";" { j += 1 }
            return min(j + 1, chars.count)
        case "S":
            return consumeStackedText(chars, at: i, into: &out)
        case "U":
            return consumeUnicodeEscape(chars, at: i, into: &out)
        default:
            // Unknown escape: drop the backslash, keep the character.
            out.append(code)
            return i + 2
        }
    }

    /// Handles stacked text `\Snumer^denom;` (also `/` or `#` separators),
    /// emitting "numer/denom". A `^` followed by a space (tolerance stack)
    /// also becomes "/" with the space dropped.
    private static func consumeStackedText(
        _ chars: [Character], at i: Int, into out: inout String
    ) -> Int {
        var j = i + 2 // skip "\S"
        while j < chars.count && chars[j] != ";" {
            let c = chars[j]
            if c == "^" || c == "#" {
                out.append("/")
                // "^ " tolerance stack: skip the space after the caret.
                if c == "^", j + 1 < chars.count, chars[j + 1] == " " {
                    j += 1
                }
            } else {
                out.append(c)
            }
            j += 1
        }
        return min(j + 1, chars.count) // consume the ';' too
    }

    /// Handles `\U+XXXX` (exactly four hex digits), emitting the
    /// corresponding unicode scalar. Malformed sequences are kept literally.
    private static func consumeUnicodeEscape(
        _ chars: [Character], at i: Int, into out: inout String
    ) -> Int {
        let hexStart = i + 3 // after "\U+"
        if i + 2 < chars.count, chars[i + 2] == "+", hexStart + 4 <= chars.count {
            let hex = String(chars[hexStart..<hexStart + 4])
            if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                out.append(Character(scalar))
                return hexStart + 4
            }
        }
        out.append(contentsOf: "\\U") // malformed: keep literal
        return i + 2
    }

    /// Decodes a %%-code at `i` (where `chars[i] == "%"`). Returns the text
    /// to emit and the number of characters consumed, or nil if the input
    /// at `i` is not a recognized %%-code.
    private static func percentCode(_ chars: [Character], at i: Int) -> (String, Int)? {
        guard i + 2 < chars.count, chars[i + 1] == "%" else { return nil }
        let c = chars[i + 2]
        switch c {
        case "c", "C": return ("\u{00D8}", 3) // Ø diameter symbol
        case "d", "D": return ("\u{00B0}", 3) // ° degree symbol
        case "p", "P": return ("\u{00B1}", 3) // ± plus/minus symbol
        case "u", "U", "o", "O": return ("", 3) // underline/overline toggles
        case "%": return ("%", 3) // literal percent
        default:
            // %%nnn: three-digit character code (ASCII / Latin-1).
            if isASCIIDigit(c), i + 4 < chars.count,
               isASCIIDigit(chars[i + 3]), isASCIIDigit(chars[i + 4]) {
                let value = c.wholeNumberValue! * 100
                    + chars[i + 3].wholeNumberValue! * 10
                    + chars[i + 4].wholeNumberValue!
                if value <= 255 {
                    return (String(Character(Unicode.Scalar(UInt8(value)))), 5)
                }
            }
            return nil
        }
    }

    private static func isASCIIDigit(_ c: Character) -> Bool {
        c.isASCII && c >= "0" && c <= "9"
    }
}
