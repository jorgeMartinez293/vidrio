import Foundation

/// All user-configurable terminal appearance/launch settings. Value type;
/// clamped to valid ranges on decode and via `clamped()`.
struct TerminalSettings: Codable, Equatable {
    var cols: Int
    var rows: Int
    var blurMaterial: BlurMaterial
    var backgroundColorEnabled: Bool
    var backgroundColor: RGBAColor
    var opacity: Double
    var fontName: String
    var fontSize: Double
    var textColor: RGBAColor
    var cursorColor: RGBAColor
    var cornerRadius: Double

    // Valid ranges.
    static let colsRange = 20...400
    static let rowsRange = 5...200
    static let opacityRange = 0.0...1.0
    static let fontSizeRange = 8.0...48.0
    static let cornerRadiusRange = 0.0...40.0

    /// Defaults reproduce the app's current hardcoded behavior.
    /// cols/rows ≈ the old 800×600 window with SF Mono 14 (see WindowSizeCalculator
    /// tests for the size assertion).
    static let defaults = TerminalSettings(
        cols: 92,
        rows: 31,
        blurMaterial: .hudWindow,
        backgroundColorEnabled: false,
        backgroundColor: .black,
        opacity: 1.0,
        fontName: "SF Mono",
        fontSize: 14,
        textColor: .white,
        cursorColor: .white,
        cornerRadius: 16
    )

    init(
        cols: Int, rows: Int, blurMaterial: BlurMaterial,
        backgroundColorEnabled: Bool, backgroundColor: RGBAColor, opacity: Double,
        fontName: String, fontSize: Double,
        textColor: RGBAColor, cursorColor: RGBAColor, cornerRadius: Double
    ) {
        self.cols = cols
        self.rows = rows
        self.blurMaterial = blurMaterial
        self.backgroundColorEnabled = backgroundColorEnabled
        self.backgroundColor = backgroundColor
        self.opacity = opacity
        self.fontName = fontName
        self.fontSize = fontSize
        self.textColor = textColor
        self.cursorColor = cursorColor
        self.cornerRadius = cornerRadius
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.cols = try c.decode(Int.self, forKey: .cols)
        self.rows = try c.decode(Int.self, forKey: .rows)
        self.blurMaterial = try c.decode(BlurMaterial.self, forKey: .blurMaterial)
        self.backgroundColorEnabled = try c.decode(Bool.self, forKey: .backgroundColorEnabled)
        self.backgroundColor = try c.decode(RGBAColor.self, forKey: .backgroundColor)
        self.opacity = try c.decode(Double.self, forKey: .opacity)
        self.fontName = try c.decode(String.self, forKey: .fontName)
        self.fontSize = try c.decode(Double.self, forKey: .fontSize)
        self.textColor = try c.decode(RGBAColor.self, forKey: .textColor)
        self.cursorColor = try c.decode(RGBAColor.self, forKey: .cursorColor)
        self.cornerRadius = try c.decode(Double.self, forKey: .cornerRadius)
        self = self.clamped()
    }

    /// Returns a copy with every numeric field forced into its valid range.
    func clamped() -> TerminalSettings {
        var s = self
        s.cols = min(max(cols, Self.colsRange.lowerBound), Self.colsRange.upperBound)
        s.rows = min(max(rows, Self.rowsRange.lowerBound), Self.rowsRange.upperBound)
        s.opacity = min(max(opacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
        s.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        s.cornerRadius = min(max(cornerRadius, Self.cornerRadiusRange.lowerBound), Self.cornerRadiusRange.upperBound)
        return s
    }
}
