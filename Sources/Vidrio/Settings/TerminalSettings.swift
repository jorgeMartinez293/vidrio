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
    /// Brightness multiplier for dim/faint text (SGR 2), e.g. the version/model line of CLI tools.
    var dimFactor: Double
    /// Replaces the fixed grays (153 and 136) that Claude Code uses for its version/model/effort
    /// line, path and borders. `nil` keeps them as sent.
    var secondaryTextColor: RGBAColor?
    /// Held while dragging a pane, rearranges the grid (new rows and
    /// columns); held while dragging a window by its top strip, merges it
    /// into another window.
    var rearrangeModifier: DragModifier
    /// Held while dragging a pane, swaps it with the pane it's dropped on.
    /// Always differs from `rearrangeModifier`.
    var swapModifier: DragModifier

    // Valid ranges.
    static let colsRange = 20...400
    static let rowsRange = 5...200
    static let opacityRange = 0.0...1.0
    static let fontSizeRange = 8.0...48.0
    static let dimFactorRange = 0.0...1.0

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
        dimFactor: 0.5,
        secondaryTextColor: nil,
        rearrangeModifier: .command,
        swapModifier: .option
    )

    init(
        cols: Int, rows: Int, blurMaterial: BlurMaterial,
        backgroundColorEnabled: Bool, backgroundColor: RGBAColor, opacity: Double,
        fontName: String, fontSize: Double,
        textColor: RGBAColor, cursorColor: RGBAColor,
        dimFactor: Double = TerminalSettings.defaults.dimFactor,
        secondaryTextColor: RGBAColor? = nil,
        rearrangeModifier: DragModifier = .command,
        swapModifier: DragModifier = .option
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
        self.dimFactor = dimFactor
        self.secondaryTextColor = secondaryTextColor
        self.rearrangeModifier = rearrangeModifier
        self.swapModifier = swapModifier
    }

    /// Decodes missing fields to their default value (via `decodeIfPresent`) so
    /// that adding a new setting in a future version doesn't reset every
    /// existing user's stored settings on upgrade. Clamps after decoding.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaults
        self.cols = try c.decodeIfPresent(Int.self, forKey: .cols) ?? d.cols
        self.rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? d.rows
        self.blurMaterial = try c.decodeIfPresent(BlurMaterial.self, forKey: .blurMaterial) ?? d.blurMaterial
        self.backgroundColorEnabled = try c.decodeIfPresent(Bool.self, forKey: .backgroundColorEnabled) ?? d.backgroundColorEnabled
        self.backgroundColor = try c.decodeIfPresent(RGBAColor.self, forKey: .backgroundColor) ?? d.backgroundColor
        self.opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        self.fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? d.fontName
        self.fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        self.textColor = try c.decodeIfPresent(RGBAColor.self, forKey: .textColor) ?? d.textColor
        self.cursorColor = try c.decodeIfPresent(RGBAColor.self, forKey: .cursorColor) ?? d.cursorColor
        self.dimFactor = try c.decodeIfPresent(Double.self, forKey: .dimFactor) ?? d.dimFactor
        self.secondaryTextColor = try c.decodeIfPresent(RGBAColor.self, forKey: .secondaryTextColor)
        self.rearrangeModifier = try c.decodeIfPresent(DragModifier.self, forKey: .rearrangeModifier) ?? d.rearrangeModifier
        self.swapModifier = try c.decodeIfPresent(DragModifier.self, forKey: .swapModifier) ?? d.swapModifier
        self = self.clamped()
    }

    /// Returns a copy with every numeric field forced into its valid range,
    /// and the two drag modifiers told apart.
    func clamped() -> TerminalSettings {
        var s = self
        s.cols = min(max(cols, Self.colsRange.lowerBound), Self.colsRange.upperBound)
        s.rows = min(max(rows, Self.rowsRange.lowerBound), Self.rowsRange.upperBound)
        s.opacity = min(max(opacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
        s.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        s.dimFactor = min(max(dimFactor, Self.dimFactorRange.lowerBound), Self.dimFactorRange.upperBound)
        if s.swapModifier == s.rearrangeModifier {
            s.swapModifier = s.rearrangeModifier == .option ? .command : .option
        }
        return s
    }
}
