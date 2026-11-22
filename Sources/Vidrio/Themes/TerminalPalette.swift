import Foundation
import SwiftTerm

/// The 16 ANSI colors as `#RRGGBB`: black to white, then their bright versions.
enum TerminalPalette {
    /// SwiftTerm's own default palette.
    static let standard = [
        "#000000", "#C23621", "#25BC24", "#ADAD27", "#492EE1", "#D338D3", "#33BBC8", "#CBCCCD",
        "#818383", "#FC391F", "#31E722", "#EAEC23", "#5833FF", "#F935F8", "#14F0F0", "#E9EBEB",
    ]

    /// A palette built around a sprite's color, so each pane matches its greeter.
    /// Red, green and yellow only lean toward the sprite: errors must still look like errors.
    /// Blue, magenta and cyan, which carry no such meaning, follow it closely.
    static func matching(accent: SpriteColor) -> [String] {
        let weights: [Double] = [0.15, 0.15, 0.15, 0.15, 0.7, 0.6, 0.6, 0.2]
        return standard.compactMap(SpriteColor.init(hex:)).enumerated().map { index, color in
            blend(color, accent, weight: weights[index % 8]).hex
        }
    }

    static func swiftTermColors(_ palette: [String]) -> [SwiftTerm.Color]? {
        let colors = palette.compactMap(SpriteColor.init(hex:)).map {
            SwiftTerm.Color(
                red: UInt16($0.red) * 257, green: UInt16($0.green) * 257, blue: UInt16($0.blue) * 257
            )
        }
        return colors.count == 16 ? colors : nil
    }

    private static func blend(_ a: SpriteColor, _ b: SpriteColor, weight: Double) -> SpriteColor {
        func mix(_ x: UInt8, _ y: UInt8) -> UInt8 {
            UInt8((Double(x) * (1 - weight) + Double(y) * weight).rounded())
        }
        return SpriteColor(red: mix(a.red, b.red), green: mix(a.green, b.green), blue: mix(a.blue, b.blue))
    }
}
