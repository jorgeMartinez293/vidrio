import Testing
import AppKit
@testable import LiquidTerminal

struct WindowSizeCalculatorTests {
    private func testFont() -> NSFont {
        NSFont(name: "Menlo", size: 14) ?? .monospacedSystemFont(ofSize: 14, weight: .regular)
    }

    @Test func testCellSizeIsPositive() {
        let cell = WindowSizeCalculator.cellSize(for: testFont())
        #expect(cell.width > 0)
        #expect(cell.height > 0)
    }

    @Test func testWindowSizeMatchesFormula() {
        let font = testFont()
        let cell = WindowSizeCalculator.cellSize(for: font)
        let size = WindowSizeCalculator.windowSize(cols: 80, rows: 24, font: font)
        #expect(abs(size.width - (cell.width * 80 + WindowSizeCalculator.horizontalInset)) < 0.5)
        #expect(abs(size.height - (cell.height * 24 + WindowSizeCalculator.verticalInset)) < 0.5)
    }

    @Test func testWindowSizeGrowsWithColsAndRows() {
        let font = testFont()
        let base = WindowSizeCalculator.windowSize(cols: 40, rows: 20, font: font)
        let wider = WindowSizeCalculator.windowSize(cols: 80, rows: 20, font: font)
        let taller = WindowSizeCalculator.windowSize(cols: 40, rows: 40, font: font)
        #expect(wider.width > base.width)
        #expect(wider.height == base.height)
        #expect(taller.height > base.height)
        #expect(taller.width == base.width)
    }

    @Test func testDefaultSettingsProduceReasonableWindow() {
        let d = TerminalSettings.defaults
        let font = NSFont(name: d.fontName, size: d.fontSize)
            ?? .monospacedSystemFont(ofSize: d.fontSize, weight: .regular)
        let size = WindowSizeCalculator.windowSize(cols: d.cols, rows: d.rows, font: font)
        // Should land near the old 800×600 window.
        #expect((700.0...900.0).contains(size.width), "width was \(size.width)")
        #expect((520.0...680.0).contains(size.height), "height was \(size.height)")
    }
}
