# Terminal Settings Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native macOS Settings window (app menu, `⌘,`) that configures how new terminal windows open — size (cols×rows), background color + opacity, blur material, font, text/cursor color, corner radius — with a reset-to-defaults button; defaults equal current hardcoded behavior.

**Architecture:** A pure `Codable` settings model (`TerminalSettings`) with range clamping, persisted to `UserDefaults` via a `@MainActor` `SettingsStore` singleton. A pure `WindowSizeCalculator` derives window pixel size from cols×rows using the same font-metric formula SwiftTerm uses internally. A SwiftUI grouped `Form` (`SettingsView`) hosted in an `NSWindow` (`SettingsWindowController`) edits the store. `AppDelegate.createNewWindow` reads the store at creation time and injects settings into `TerminalViewController`, which applies them. Settings affect new windows only.

**Tech Stack:** Swift 6.2, AppKit/Cocoa, SwiftUI (macOS 13 grouped form), SwiftTerm (vendored), XCTest, SwiftPM.

---

## File Structure

**New:**
- `Sources/LiquidTerminal/Settings/RGBAColor.swift` — Codable color value ↔ `NSColor`/SwiftUI `Color`.
- `Sources/LiquidTerminal/Settings/BlurMaterial.swift` — enum ↔ `NSVisualEffectView.Material` (+ `none`), display names.
- `Sources/LiquidTerminal/Settings/TerminalSettings.swift` — the settings struct, defaults, clamping.
- `Sources/LiquidTerminal/Settings/WindowSizeCalculator.swift` — pure cols×rows → pixel size.
- `Sources/LiquidTerminal/Settings/SettingsStore.swift` — UserDefaults persistence singleton.
- `Sources/LiquidTerminal/Settings/SettingsViewModel.swift` — `ObservableObject` wrapping the store.
- `Sources/LiquidTerminal/Settings/SettingsView.swift` — SwiftUI grouped form.
- `Sources/LiquidTerminal/Settings/SettingsWindowController.swift` — hosts `SettingsView` in an `NSWindow`.
- `Tests/LiquidTerminalTests/TerminalSettingsTests.swift`
- `Tests/LiquidTerminalTests/WindowSizeCalculatorTests.swift`
- `Tests/LiquidTerminalTests/SettingsStoreTests.swift`

**Modified:**
- `Package.swift` — add test target.
- `Sources/LiquidTerminal/TerminalViewController.swift` — accept + apply `TerminalSettings`.
- `Sources/LiquidTerminal/AppDelegate.swift` — Settings menu item, `createNewWindow` reads store.

---

## Task 1: Package test target

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add a test target depending on the executable target**

Replace the `targets:` array in `Package.swift` with:

```swift
    targets: [
        .executableTarget(
            name: "LiquidTerminal",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .testTarget(
            name: "LiquidTerminalTests",
            dependencies: ["LiquidTerminal"]
        ),
    ]
```

- [ ] **Step 2: Create an empty test directory placeholder so the target resolves**

Create `Tests/LiquidTerminalTests/Placeholder.swift`:

```swift
import XCTest

final class PlaceholderTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 3: Build and run tests to confirm the target wiring**

Run: `swift test`
Expected: PASS (1 test, `testPlaceholder`). Confirms `@testable import LiquidTerminal` of an executable target works.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Tests/LiquidTerminalTests/Placeholder.swift
git commit -m "Add LiquidTerminalTests target"
```

---

## Task 2: RGBAColor value type

**Files:**
- Create: `Sources/LiquidTerminal/Settings/RGBAColor.swift`
- Test: `Tests/LiquidTerminalTests/TerminalSettingsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/LiquidTerminalTests/TerminalSettingsTests.swift`:

```swift
import XCTest
import AppKit
@testable import LiquidTerminal

final class RGBAColorTests: XCTestCase {
    func testRoundTripThroughNSColor() {
        let original = RGBAColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)
        let back = RGBAColor(original.nsColor)
        XCTAssertEqual(back.red, 0.2, accuracy: 0.001)
        XCTAssertEqual(back.green, 0.4, accuracy: 0.001)
        XCTAssertEqual(back.blue, 0.6, accuracy: 0.001)
        XCTAssertEqual(back.alpha, 0.8, accuracy: 0.001)
    }

    func testCodableRoundTrip() throws {
        let original = RGBAColor(red: 1, green: 0, blue: 0.5, alpha: 1)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RGBAColor.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testWithAlphaOverridesAlpha() {
        let c = RGBAColor.white.withAlpha(0.3)
        XCTAssertEqual(c.alpha, 0.3, accuracy: 0.001)
        XCTAssertEqual(c.red, 1, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RGBAColorTests`
Expected: FAIL (compile error: `cannot find 'RGBAColor' in scope`).

- [ ] **Step 3: Write minimal implementation**

Create `Sources/LiquidTerminal/Settings/RGBAColor.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RGBAColorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiquidTerminal/Settings/RGBAColor.swift Tests/LiquidTerminalTests/TerminalSettingsTests.swift
git commit -m "Add RGBAColor value type"
```

---

## Task 3: BlurMaterial enum

**Files:**
- Create: `Sources/LiquidTerminal/Settings/BlurMaterial.swift`
- Test: `Tests/LiquidTerminalTests/TerminalSettingsTests.swift` (append)

- [ ] **Step 1: Write the failing test**

Append to `Tests/LiquidTerminalTests/TerminalSettingsTests.swift`:

```swift
final class BlurMaterialTests: XCTestCase {
    func testNoneHasNilMaterial() {
        XCTAssertNil(BlurMaterial.none.material)
    }

    func testHudWindowMapsToMaterial() {
        XCTAssertEqual(BlurMaterial.hudWindow.material, .hudWindow)
    }

    func testAllCasesHaveDisplayNames() {
        for material in BlurMaterial.allCases {
            XCTAssertFalse(material.displayName.isEmpty)
        }
    }

    func testCodableRoundTrip() throws {
        for material in BlurMaterial.allCases {
            let data = try JSONEncoder().encode(material)
            let decoded = try JSONDecoder().decode(BlurMaterial.self, from: data)
            XCTAssertEqual(decoded, material)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BlurMaterialTests`
Expected: FAIL (compile error: `cannot find 'BlurMaterial' in scope`).

- [ ] **Step 3: Write minimal implementation**

Create `Sources/LiquidTerminal/Settings/BlurMaterial.swift`:

```swift
import AppKit

/// User-selectable blur presets. Each maps to an NSVisualEffectView material,
/// except `.none` which means "no blur" (the visual effect view is hidden).
enum BlurMaterial: String, Codable, CaseIterable {
    case hudWindow
    case popover
    case sidebar
    case fullScreenUI
    case underWindowBackground
    case menu
    case none

    /// nil when blur should be disabled.
    var material: NSVisualEffectView.Material? {
        switch self {
        case .hudWindow: return .hudWindow
        case .popover: return .popover
        case .sidebar: return .sidebar
        case .fullScreenUI: return .fullScreenUI
        case .underWindowBackground: return .underWindowBackground
        case .menu: return .menu
        case .none: return nil
        }
    }

    var displayName: String {
        switch self {
        case .hudWindow: return "HUD"
        case .popover: return "Popover"
        case .sidebar: return "Barra lateral"
        case .fullScreenUI: return "Pantalla completa"
        case .underWindowBackground: return "Bajo ventana"
        case .menu: return "Menú"
        case .none: return "Ninguno"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BlurMaterialTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiquidTerminal/Settings/BlurMaterial.swift Tests/LiquidTerminalTests/TerminalSettingsTests.swift
git commit -m "Add BlurMaterial enum"
```

---

## Task 4: TerminalSettings struct with clamping

**Files:**
- Create: `Sources/LiquidTerminal/Settings/TerminalSettings.swift`
- Test: `Tests/LiquidTerminalTests/TerminalSettingsTests.swift` (append)

- [ ] **Step 1: Write the failing test**

Append to `Tests/LiquidTerminalTests/TerminalSettingsTests.swift`:

```swift
final class TerminalSettingsTests: XCTestCase {
    func testDefaultsAreReasonable() {
        let d = TerminalSettings.defaults
        XCTAssertEqual(d.blurMaterial, .hudWindow)
        XCTAssertFalse(d.backgroundColorEnabled)
        XCTAssertEqual(d.opacity, 1.0, accuracy: 0.001)
        XCTAssertEqual(d.fontName, "SF Mono")
        XCTAssertEqual(d.fontSize, 14, accuracy: 0.001)
        XCTAssertEqual(d.textColor, .white)
        XCTAssertEqual(d.cursorColor, .white)
        XCTAssertEqual(d.cornerRadius, 16, accuracy: 0.001)
        XCTAssertTrue(d.cols >= 20 && d.cols <= 400)
        XCTAssertTrue(d.rows >= 5 && d.rows <= 200)
    }

    func testCodableRoundTrip() throws {
        let original = TerminalSettings.defaults
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testClampingOnDecode() throws {
        // Build JSON with out-of-range values and confirm decode clamps them.
        let json = """
        {
          "cols": 5000, "rows": 0,
          "blurMaterial": "hudWindow",
          "backgroundColorEnabled": true,
          "backgroundColor": {"red":0,"green":0,"blue":0,"alpha":1},
          "opacity": 5.0,
          "fontName": "SF Mono", "fontSize": 999,
          "textColor": {"red":1,"green":1,"blue":1,"alpha":1},
          "cursorColor": {"red":1,"green":1,"blue":1,"alpha":1},
          "cornerRadius": -10
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(decoded.cols, 400)
        XCTAssertEqual(decoded.rows, 5)
        XCTAssertEqual(decoded.opacity, 1.0, accuracy: 0.001)
        XCTAssertEqual(decoded.fontSize, 48, accuracy: 0.001)
        XCTAssertEqual(decoded.cornerRadius, 0, accuracy: 0.001)
    }

    func testClampedMethodEnforcesBounds() {
        var s = TerminalSettings.defaults
        s.cols = 1
        s.opacity = -3
        let c = s.clamped()
        XCTAssertEqual(c.cols, 20)
        XCTAssertEqual(c.opacity, 0, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TerminalSettingsTests`
Expected: FAIL (compile error: `cannot find 'TerminalSettings' in scope`).

- [ ] **Step 3: Write minimal implementation**

Create `Sources/LiquidTerminal/Settings/TerminalSettings.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TerminalSettingsTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiquidTerminal/Settings/TerminalSettings.swift Tests/LiquidTerminalTests/TerminalSettingsTests.swift
git commit -m "Add TerminalSettings model with clamping"
```

---

## Task 5: WindowSizeCalculator

**Files:**
- Create: `Sources/LiquidTerminal/Settings/WindowSizeCalculator.swift`
- Test: `Tests/LiquidTerminalTests/WindowSizeCalculatorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/LiquidTerminalTests/WindowSizeCalculatorTests.swift`:

```swift
import XCTest
import AppKit
@testable import LiquidTerminal

final class WindowSizeCalculatorTests: XCTestCase {
    private func testFont() -> NSFont {
        NSFont(name: "Menlo", size: 14) ?? .monospacedSystemFont(ofSize: 14, weight: .regular)
    }

    func testCellSizeIsPositive() {
        let cell = WindowSizeCalculator.cellSize(for: testFont())
        XCTAssertGreaterThan(cell.width, 0)
        XCTAssertGreaterThan(cell.height, 0)
    }

    func testWindowSizeMatchesFormula() {
        let font = testFont()
        let cell = WindowSizeCalculator.cellSize(for: font)
        let size = WindowSizeCalculator.windowSize(cols: 80, rows: 24, font: font)
        XCTAssertEqual(size.width, cell.width * 80 + WindowSizeCalculator.horizontalInset, accuracy: 0.5)
        XCTAssertEqual(size.height, cell.height * 24 + WindowSizeCalculator.verticalInset, accuracy: 0.5)
    }

    func testDefaultSettingsProduceReasonableWindow() {
        let d = TerminalSettings.defaults
        let font = NSFont(name: d.fontName, size: d.fontSize)
            ?? .monospacedSystemFont(ofSize: d.fontSize, weight: .regular)
        let size = WindowSizeCalculator.windowSize(cols: d.cols, rows: d.rows, font: font)
        // Should land near the old 800×600 window.
        XCTAssertTrue((700...900).contains(size.width), "width was \(size.width)")
        XCTAssertTrue((520...680).contains(size.height), "height was \(size.height)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WindowSizeCalculatorTests`
Expected: FAIL (compile error: `cannot find 'WindowSizeCalculator' in scope`).

- [ ] **Step 3: Write minimal implementation**

Create `Sources/LiquidTerminal/Settings/WindowSizeCalculator.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WindowSizeCalculatorTests`
Expected: PASS (3 tests). If `testDefaultSettingsProduceReasonableWindow` fails because the size is off, adjust `TerminalSettings.defaults` `cols`/`rows` so the default window lands near 800×600, then re-run.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiquidTerminal/Settings/WindowSizeCalculator.swift Tests/LiquidTerminalTests/WindowSizeCalculatorTests.swift
git commit -m "Add WindowSizeCalculator"
```

---

## Task 6: SettingsStore (UserDefaults persistence)

**Files:**
- Create: `Sources/LiquidTerminal/Settings/SettingsStore.swift`
- Test: `Tests/LiquidTerminalTests/SettingsStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/LiquidTerminalTests/SettingsStoreTests.swift`:

```swift
import XCTest
@testable import LiquidTerminal

@MainActor
final class SettingsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testFreshStoreReturnsDefaults() {
        let store = SettingsStore(userDefaults: makeDefaults())
        XCTAssertEqual(store.current, .defaults)
    }

    func testSavePersistsAcrossInstances() {
        let defaults = makeDefaults()
        let store = SettingsStore(userDefaults: defaults)
        store.current.cols = 123
        store.save()

        let reopened = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(reopened.current.cols, 123)
    }

    func testCorruptDataFallsBackToDefaults() {
        let defaults = makeDefaults()
        defaults.set("not json".data(using: .utf8), forKey: SettingsStore.storageKey)
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(store.current, .defaults)
    }

    func testResetToDefaults() {
        let store = SettingsStore(userDefaults: makeDefaults())
        store.current.cols = 200
        store.save()
        store.resetToDefaults()
        XCTAssertEqual(store.current, .defaults)
    }

    func testSaveClampsBeforePersisting() {
        let defaults = makeDefaults()
        let store = SettingsStore(userDefaults: defaults)
        store.current.cols = 99999
        store.save()
        let reopened = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(reopened.current.cols, TerminalSettings.colsRange.upperBound)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SettingsStoreTests`
Expected: FAIL (compile error: `cannot find 'SettingsStore' in scope`).

- [ ] **Step 3: Write minimal implementation**

Create `Sources/LiquidTerminal/Settings/SettingsStore.swift`:

```swift
import Foundation

/// Loads and persists `TerminalSettings` to UserDefaults as JSON. Single source
/// of truth read by AppDelegate at window-creation time.
@MainActor
final class SettingsStore {
    static let shared = SettingsStore(userDefaults: .standard)
    static let storageKey = "com.jorge.LiquidTerminal.settings"

    private let userDefaults: UserDefaults

    /// Current settings. Mutate then call `save()` to persist.
    var current: TerminalSettings

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(TerminalSettings.self, from: data) {
            self.current = decoded
        } else {
            self.current = .defaults
        }
    }

    /// Clamps and persists `current`.
    func save() {
        current = current.clamped()
        if let data = try? JSONEncoder().encode(current) {
            userDefaults.set(data, forKey: Self.storageKey)
        }
    }

    func resetToDefaults() {
        current = .defaults
        save()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SettingsStoreTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS (all tests from Tasks 1–6).

- [ ] **Step 6: Commit**

```bash
git add Sources/LiquidTerminal/Settings/SettingsStore.swift Tests/LiquidTerminalTests/SettingsStoreTests.swift
git commit -m "Add SettingsStore for UserDefaults persistence"
```

---

## Task 7: Apply settings in TerminalViewController

**Files:**
- Modify: `Sources/LiquidTerminal/TerminalViewController.swift`

No automated test — GUI. Verified by build + manual launch in Task 10.

- [ ] **Step 1: Add a settings property**

In `TerminalViewController`, add below `var scriptPath: String?` (line ~35):

```swift
    /// Appearance/launch settings applied at setup. Injected by AppDelegate
    /// before the view loads; defaults reproduce the original hardcoded look.
    var settings: TerminalSettings = .defaults
```

- [ ] **Step 2: Add a stored reference for the background color overlay**

In `TerminalViewController`, add below the `terminalView` declaration (line ~27):

```swift
    /// Solid color layer between the blur and the terminal text. Empty (clear)
    /// when `settings.backgroundColorEnabled` is false, preserving pure blur.
    private var backgroundOverlay: NSView!
```

- [ ] **Step 3: Rewrite the visual-effect + overlay + terminal styling in `setupTerminal()`**

In `setupTerminal()`, replace the block from `// Setup Visual Effect View for Blur` through the terminal-view styling (the lines creating `visualEffectView`, its constraints, creating `terminalView`, its stylization including `cornerRadius = 16.0`, `nativeBackgroundColor`, `nativeForegroundColor`, font, and `caretColor`, and the `view.addSubview(terminalView)` + its constraints) — i.e. lines ~99–148 — with:

```swift
        let radius = CGFloat(settings.cornerRadius)

        // Setup Visual Effect View for Blur (hidden when material is "none")
        let visualEffectView = NSVisualEffectView(frame: view.bounds)
        if let material = settings.blurMaterial.material {
            visualEffectView.material = material
            visualEffectView.isHidden = false
        } else {
            visualEffectView.isHidden = true
        }
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = radius
        visualEffectView.layer?.masksToBounds = true

        view.addSubview(visualEffectView)

        NSLayoutConstraint.activate([
            visualEffectView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            visualEffectView.topAnchor.constraint(equalTo: view.topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Background color overlay: sits on top of the blur, under the text.
        backgroundOverlay = NSView(frame: view.bounds)
        backgroundOverlay.translatesAutoresizingMaskIntoConstraints = false
        backgroundOverlay.wantsLayer = true
        backgroundOverlay.layer?.cornerRadius = radius
        backgroundOverlay.layer?.masksToBounds = true
        if settings.backgroundColorEnabled {
            backgroundOverlay.layer?.backgroundColor =
                settings.backgroundColor.withAlpha(settings.opacity).nsColor.cgColor
        } else {
            backgroundOverlay.layer?.backgroundColor = NSColor.clear.cgColor
        }

        view.addSubview(backgroundOverlay)

        NSLayoutConstraint.activate([
            backgroundOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        terminalView = LiquidTerminalView(frame: view.bounds)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.processDelegate = self
        terminalView.scrollerEnabled = false

        // Stylization
        terminalView.wantsLayer = true
        terminalView.layer?.backgroundColor = NSColor.clear.cgColor
        terminalView.layer?.cornerRadius = radius
        terminalView.layer?.masksToBounds = true
        terminalView.nativeBackgroundColor = .clear
        terminalView.nativeForegroundColor = settings.textColor.nsColor

        // Font configuration
        if let font = NSFont(name: settings.fontName, size: CGFloat(settings.fontSize)) {
            terminalView.font = font
        } else {
            terminalView.font = NSFont.monospacedSystemFont(ofSize: CGFloat(settings.fontSize), weight: .regular)
        }

        // Cursor color
        terminalView.caretColor = settings.cursorColor.nsColor

        view.addSubview(terminalView)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.topAnchor, constant: 50), // Increased top margin
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10)
        ])
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiquidTerminal/TerminalViewController.swift
git commit -m "Apply TerminalSettings in TerminalViewController"
```

---

## Task 8: Wire AppDelegate.createNewWindow to settings

**Files:**
- Modify: `Sources/LiquidTerminal/AppDelegate.swift:85-115`

No automated test — GUI. Verified in Task 10.

- [ ] **Step 1: Read settings and compute size in `createNewWindow`**

In `createNewWindow(scriptPath:)`, replace the body from `let screenSize = ...` through the `windowSize` definition (lines ~86–87) with:

```swift
        let settings = SettingsStore.shared.current
        let font = NSFont(name: settings.fontName, size: CGFloat(settings.fontSize))
            ?? .monospacedSystemFont(ofSize: CGFloat(settings.fontSize), weight: .regular)

        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 800, height: 600)
        let windowSize = WindowSizeCalculator.windowSize(cols: settings.cols, rows: settings.rows, font: font)
```

- [ ] **Step 2: Inject settings into the view controller**

In the same method, after `let viewController = TerminalViewController()` (line ~107), add:

```swift
        viewController.settings = settings
```

so the block reads:

```swift
        let viewController = TerminalViewController()
        viewController.settings = settings
        viewController.scriptPath = scriptPath
        newWindow.contentViewController = viewController
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Manual check that settings drive new windows (no UI yet)**

Run:
```bash
defaults write com.jorge.LiquidTerminal com.jorge.LiquidTerminal.settings -data "$(printf '%s' '{"cols":40,"rows":10,"blurMaterial":"none","backgroundColorEnabled":true,"backgroundColor":{"red":0.1,"green":0.0,"blue":0.2,"alpha":1},"opacity":1.0,"fontName":"SF Mono","fontSize":18,"textColor":{"red":0,"green":1,"blue":0,"alpha":1},"cursorColor":{"red":0,"green":1,"blue":0,"alpha":1},"cornerRadius":4}' | xxd -p | tr -d '\n')"
swift run LiquidTerminal
```
Expected: a small window (~40×10 cells), no blur, solid dark-purple background, green 18pt text, slightly rounded corners. Close it, then clear the test value:
```bash
defaults delete com.jorge.LiquidTerminal com.jorge.LiquidTerminal.settings
```

- [ ] **Step 5: Commit**

```bash
git add Sources/LiquidTerminal/AppDelegate.swift
git commit -m "Read TerminalSettings when creating windows"
```

---

## Task 9: SettingsViewModel + SettingsView (SwiftUI)

**Files:**
- Create: `Sources/LiquidTerminal/Settings/SettingsViewModel.swift`
- Create: `Sources/LiquidTerminal/Settings/SettingsView.swift`

No automated test — GUI. Verified in Task 10.

- [ ] **Step 1: Create the view model**

Create `Sources/LiquidTerminal/Settings/SettingsViewModel.swift`:

```swift
import SwiftUI

/// Bridges `SettingsStore` to SwiftUI. Every mutation persists immediately
/// (System-Settings style: no Save button).
@MainActor
final class SettingsViewModel: ObservableObject {
    private let store: SettingsStore

    @Published var settings: TerminalSettings {
        didSet {
            store.current = settings
            store.save()
            // Reflect any clamping the store applied.
            if store.current != settings { settings = store.current }
        }
    }

    /// Monospace font family names available on this system.
    let monospaceFonts: [String]

    init(store: SettingsStore = .shared) {
        self.store = store
        self.settings = store.current
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        var unique = Array(Set(names)).sorted()
        if !unique.contains(store.current.fontName) {
            unique.insert(store.current.fontName, at: 0)
        }
        self.monospaceFonts = unique
    }

    func reset() {
        store.resetToDefaults()
        settings = store.current
    }

    /// SwiftUI Color binding backed by an RGBAColor keypath.
    func colorBinding(_ keyPath: WritableKeyPath<TerminalSettings, RGBAColor>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: self.settings[keyPath: keyPath].nsColor) },
            set: { self.settings[keyPath: keyPath] = RGBAColor(NSColor($0)) }
        )
    }
}
```

- [ ] **Step 2: Create the view**

Create `Sources/LiquidTerminal/Settings/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    private var s: Binding<TerminalSettings> { $viewModel.settings }

    var body: some View {
        Form {
            Section("Tamaño (al abrir)") {
                Stepper(value: s.cols, in: TerminalSettings.colsRange) {
                    LabeledContent("Columnas", value: "\(viewModel.settings.cols)")
                }
                Stepper(value: s.rows, in: TerminalSettings.rowsRange) {
                    LabeledContent("Filas", value: "\(viewModel.settings.rows)")
                }
            }

            Section("Fondo") {
                Picker("Desenfoque", selection: s.blurMaterial) {
                    ForEach(BlurMaterial.allCases, id: \.self) { material in
                        Text(material.displayName).tag(material)
                    }
                }
                Toggle("Color de fondo", isOn: s.backgroundColorEnabled)
                if viewModel.settings.backgroundColorEnabled {
                    ColorPicker("Color", selection: viewModel.colorBinding(\.backgroundColor))
                }
                VStack(alignment: .leading) {
                    Text("Opacidad: \(Int(viewModel.settings.opacity * 100))%")
                    Slider(value: s.opacity, in: TerminalSettings.opacityRange)
                }
            }

            Section("Texto") {
                Picker("Fuente", selection: s.fontName) {
                    ForEach(viewModel.monospaceFonts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Stepper(value: s.fontSize, in: TerminalSettings.fontSizeRange, step: 1) {
                    LabeledContent("Tamaño", value: "\(Int(viewModel.settings.fontSize)) pt")
                }
                ColorPicker("Color del texto", selection: viewModel.colorBinding(\.textColor))
                ColorPicker("Color del cursor", selection: viewModel.colorBinding(\.cursorColor))
            }

            Section("Ventana") {
                VStack(alignment: .leading) {
                    Text("Radio de esquinas: \(Int(viewModel.settings.cornerRadius)) pt")
                    Slider(value: s.cornerRadius, in: TerminalSettings.cornerRadiusRange)
                }
            }

            Section {
                Button("Restaurar valores por defecto") {
                    viewModel.reset()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 560)
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/LiquidTerminal/Settings/SettingsViewModel.swift Sources/LiquidTerminal/Settings/SettingsView.swift
git commit -m "Add SwiftUI settings view and view model"
```

---

## Task 10: SettingsWindowController + menu item

**Files:**
- Create: `Sources/LiquidTerminal/Settings/SettingsWindowController.swift`
- Modify: `Sources/LiquidTerminal/AppDelegate.swift` (`setupMenu`, add `openSettings`, add stored controller)

No automated test — GUI. Verified by the manual steps below.

- [ ] **Step 1: Create the window controller**

Create `Sources/LiquidTerminal/Settings/SettingsWindowController.swift`:

```swift
import Cocoa
import SwiftUI

/// Hosts the SwiftUI `SettingsView` in a standard titled window. Single instance.
@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init() {
        let viewModel = SettingsViewModel()
        let hosting = NSHostingController(rootView: SettingsView(viewModel: viewModel))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Ajustes"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }
}
```

- [ ] **Step 2: Add a lazy controller and action to AppDelegate**

In `AppDelegate`, add a stored property below `private var didReceiveOpenFiles = false` (line ~12):

```swift
    private lazy var settingsWindowController = SettingsWindowController()
```

And add this method below `newWindow(_:)` (line ~83):

```swift
    @objc func openSettings(_ sender: Any?) {
        settingsWindowController.showWindow(nil)
        settingsWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
```

- [ ] **Step 3: Add the menu item to the app menu**

In `setupMenu()`, replace the app-menu block (lines ~42–48, from `// App Menu` through `appMenuItem.submenu = appMenu`) with:

```swift
        // App Menu
        let appMenuItem = NSMenuItem()
        menu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Ajustes…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 5: Manual end-to-end verification**

Run: `swift run LiquidTerminal`
Verify:
1. App menu (next to Apple) shows "Ajustes…"; `⌘,` opens the settings window.
2. Window is a native grouped form with sections Tamaño / Fondo / Texto / Ventana and a reset button.
3. Change cols/rows, font size, text color, blur preset, enable background color + opacity. Open a new terminal (`⌘N`) → it reflects the new settings. Already-open windows are unchanged (expected).
4. Toggle blur to "Ninguno" with background color disabled → new window is fully transparent.
5. Click "Restaurar valores por defecto" → controls return to defaults; a new window matches the original look (~800×600, HUD blur, transparent, white SF Mono 14).
6. Quit and relaunch → settings persisted.

- [ ] **Step 6: Commit**

```bash
git add Sources/LiquidTerminal/Settings/SettingsWindowController.swift Sources/LiquidTerminal/AppDelegate.swift
git commit -m "Add settings window and app-menu item"
```

---

## Task 11: Final verification

- [ ] **Step 1: Full test suite**

Run: `swift test`
Expected: PASS (all tests, Tasks 1–6).

- [ ] **Step 2: Release build sanity**

Run: `swift build -c release`
Expected: builds with no errors.

- [ ] **Step 3: Confirm no stray test value remains**

Run: `defaults read com.jorge.LiquidTerminal 2>/dev/null || echo "no domain (clean)"`
Expected: either no domain, or only a real settings payload from manual testing — no leftover 40×10 test config.
