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
