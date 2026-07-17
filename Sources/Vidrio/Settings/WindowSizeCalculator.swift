import AppKit
import CoreText

/// Computes terminal window pixel size from a cols×rows grid, mirroring the
/// font-metric formula SwiftTerm uses internally (CTFont ascent/descent/leading
/// for height, "W" glyph advancement for width). Pure and deterministic.
enum WindowSizeCalculator {
    /// Leading (10) + trailing (10) insets between terminal view and window edges.
    static let horizontalInset: CGFloat = 20
    /// Top (50, for the transparent titlebar) + bottom (10) insets.
    static let verticalInset: CGFloat = 60

    static func cellSize(for font: NSFont) -> CGSize {
        let ctFont = font as CTFont
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        let height = ceil(ascent + descent + leading)
        let glyph = font.glyph(withName: "W")
        let width = font.advancement(forGlyph: glyph).width
        return CGSize(width: max(1, width), height: max(1, height))
    }

    static func windowSize(cols: Int, rows: Int, font: NSFont) -> CGSize {
        let cell = cellSize(for: font)
        return CGSize(
            width: cell.width * CGFloat(cols) + horizontalInset,
            height: cell.height * CGFloat(rows) + verticalInset
        )
    }
}
