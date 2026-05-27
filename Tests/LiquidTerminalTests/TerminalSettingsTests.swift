import Testing
import AppKit
@testable import LiquidTerminal

// MARK: - BlurMaterial Tests

struct BlurMaterialTests {
    @Test func testNoneHasNilMaterial() {
        #expect(BlurMaterial.none.material == nil)
    }

    @Test func testHudWindowMapsToMaterial() {
        #expect(BlurMaterial.hudWindow.material == .hudWindow)
    }

    @Test func testAllCasesHaveDisplayNames() {
        for material in BlurMaterial.allCases {
            #expect(!material.displayName.isEmpty)
        }
    }

    @Test func testCodableRoundTrip() throws {
        for material in BlurMaterial.allCases {
            let data = try JSONEncoder().encode(material)
            let decoded = try JSONDecoder().decode(BlurMaterial.self, from: data)
            #expect(decoded == material)
        }
    }
}

// MARK: - RGBAColor Tests

struct RGBAColorTests {
    @Test func testRoundTripThroughNSColor() {
        let original = RGBAColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)
        let back = RGBAColor(original.nsColor)
        #expect(abs(back.red - 0.2) < 0.001)
        #expect(abs(back.green - 0.4) < 0.001)
        #expect(abs(back.blue - 0.6) < 0.001)
        #expect(abs(back.alpha - 0.8) < 0.001)
    }

    @Test func testCodableRoundTrip() throws {
        let original = RGBAColor(red: 1, green: 0, blue: 0.5, alpha: 1)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RGBAColor.self, from: data)
        #expect(decoded == original)
    }

    @Test func testWithAlphaOverridesAlpha() {
        let c = RGBAColor.white.withAlpha(0.3)
        #expect(abs(c.alpha - 0.3) < 0.001)
        #expect(abs(c.red - 1) < 0.001)
    }
}

// MARK: - TerminalSettings Tests

struct TerminalSettingsTests {
    @Test func testDefaultsAreReasonable() {
        let d = TerminalSettings.defaults
        #expect(d.blurMaterial == .hudWindow)
        #expect(!d.backgroundColorEnabled)
        #expect(abs(d.opacity - 1.0) < 0.001)
        #expect(d.fontName == "SF Mono")
        #expect(abs(d.fontSize - 14) < 0.001)
        #expect(d.textColor == .white)
        #expect(d.cursorColor == .white)
        #expect(abs(d.cornerRadius - 16) < 0.001)
        #expect(d.cols >= 20 && d.cols <= 400)
        #expect(d.rows >= 5 && d.rows <= 200)
    }

    @Test func testCodableRoundTrip() throws {
        let original = TerminalSettings.defaults
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test func testClampingOnDecode() throws {
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
        #expect(decoded.cols == 400)
        #expect(decoded.rows == 5)
        #expect(abs(decoded.opacity - 1.0) < 0.001)
        #expect(abs(decoded.fontSize - 48) < 0.001)
        #expect(abs(decoded.cornerRadius - 0) < 0.001)
    }

    @Test func testClampedMethodEnforcesBounds() {
        var s = TerminalSettings.defaults
        s.cols = 1
        s.opacity = -3
        let c = s.clamped()
        #expect(c.cols == 20)
        #expect(abs(c.opacity - 0) < 0.001)
    }
}
