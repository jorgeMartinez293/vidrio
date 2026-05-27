import AppKit

/// Platform-stable, Codable representation of a color as sRGB components.
struct RGBAColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Reads sRGB components from an NSColor (converting color space if needed).
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        self.red = Double(c.redComponent)
        self.green = Double(c.greenComponent)
        self.blue = Double(c.blueComponent)
        self.alpha = Double(c.alphaComponent)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    func withAlpha(_ newAlpha: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: newAlpha)
    }

    static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let black = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
}
