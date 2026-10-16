import Testing
import CoreGraphics
@testable import Vidrio

struct GridLayoutTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func layout(count: Int, focusedIndex: Int = 0, spacing: CGFloat = 8) -> GridLayout.Result {
        GridLayout.compute(
            columns: GridLayout.columns(forCount: count), focusedIndex: focusedIndex,
            bounds: bounds, spacing: spacing
        )
    }

    @Test func testSinglePaneFillsBounds() {
        let layout = layout(count: 1)
        #expect(layout.frames.count == 1)
        #expect(abs(layout.frames[0].width - (bounds.width - 16)) < 0.5)
        #expect(abs(layout.frames[0].height - (bounds.height - 16)) < 0.5)
    }

    @Test func testPanesFillColumnsWithoutMovingExistingOnes() {
        // 3 -> [0 2] [1]: the third pane goes under the first, the right
        // column stays full height. 5 opens a third column instead of
        // reshuffling, and 7 goes under the leftmost column again.
        #expect(GridLayout.columns(forCount: 1) == [[0]])
        #expect(GridLayout.columns(forCount: 2) == [[0], [1]])
        #expect(GridLayout.columns(forCount: 3) == [[0, 2], [1]])
        #expect(GridLayout.columns(forCount: 4) == [[0, 2], [1, 3]])
        #expect(GridLayout.columns(forCount: 5) == [[0, 2], [1, 3], [4]])
        #expect(GridLayout.columns(forCount: 6) == [[0, 2], [1, 3], [4, 5]])
        #expect(GridLayout.columns(forCount: 7) == [[0, 2, 6], [1, 3], [4, 5]])
        #expect(GridLayout.columns(forCount: 9) == [[0, 2, 6], [1, 3, 7], [4, 5, 8]])
        #expect(GridLayout.columns(forCount: 10) == [[0, 2, 6], [1, 3, 7], [4, 5, 8], [9]])
    }

    @Test func testShortColumnPaneSpansFullHeight() {
        let layout = layout(count: 3, focusedIndex: 0)
        // Pane 1 is alone in the right column, so it reaches from top to bottom.
        #expect(abs(layout.frames[1].height - (bounds.height - 16)) < 0.5)
        #expect(layout.frames[2].maxY < layout.frames[0].minY)
        #expect(abs(layout.frames[2].minX - layout.frames[0].minX) < 0.5)
    }

    @Test func testRemovingKeepsOtherPanesInPlace() {
        // [0 2] [1 3] [4]: closing pane 1 leaves pane 3 (now 2) alone in the
        // middle column; closing pane 4 drops its now-empty column.
        let columns = GridLayout.columns(forCount: 5)
        #expect(GridLayout.removing(1, from: columns) == [[0, 1], [2], [3]])
        #expect(GridLayout.removing(4, from: columns) == [[0, 2], [1, 3]])
    }

    @Test func testNewPaneFillsGapLeftByClosedOne() {
        // [0 1] [2] after a close: the next pane evens out the short column.
        let columns = GridLayout.appending(3, to: [[0, 1], [2]])
        #expect(columns == [[0, 1], [2, 3]])
    }

    @Test func testEveryPaneGetsExactlyOneFrame() {
        let layout = layout(count: 7, focusedIndex: 3)
        #expect(layout.frames.count == 7)
        #expect(layout.frames.allSatisfy { $0.width > 0 && $0.height > 0 })
    }

    @Test func testFocusedPaneIsStrictlyLargerThanAnUnfocusedOne() {
        let layout = layout(count: 4, focusedIndex: 0)
        let focused = layout.frames[0]
        // Index 3 sits in the other column of the 2x2 grid, so it never
        // inherits the focused column's or cell's extra weight.
        let opposite = layout.frames[3]
        #expect(focused.width > opposite.width)
        #expect(focused.height > opposite.height)
    }

    @Test func testEveryColumnTilesTheFullHeight() {
        // Each column's pane heights (plus spacing) reconstruct the full
        // height, whether or not it holds the focused pane.
        for count in 1...10 {
            let layout = layout(count: count, focusedIndex: count / 2)
            for column in layout.indexAt {
                let totalHeight = column.reduce(0.0) { $0 + layout.frames[$1].height }
                    + 8 * CGFloat(column.count + 1)
                #expect(abs(totalHeight - bounds.height) < 0.5, "count \(count) height mismatch")
            }
        }
    }

    @Test func testAdjacencyNavigationInSquareGrid() {
        // 2x2 grid: [0 1]
        //           [2 3]
        let layout = layout(count: 4)
        #expect(GridLayout.move(from: 0, direction: .right, layout: layout) == 1)
        #expect(GridLayout.move(from: 0, direction: .down, layout: layout) == 2)
        #expect(GridLayout.move(from: 3, direction: .up, layout: layout) == 1)
        #expect(GridLayout.move(from: 3, direction: .left, layout: layout) == 2)
    }

    @Test func testNavigationClampsAtEdges() {
        let layout = layout(count: 4)
        #expect(GridLayout.move(from: 0, direction: .up, layout: layout) == 0)
        #expect(GridLayout.move(from: 0, direction: .left, layout: layout) == 0)
        #expect(GridLayout.move(from: 3, direction: .down, layout: layout) == 3)
        #expect(GridLayout.move(from: 3, direction: .right, layout: layout) == 3)
    }

    @Test func testSidewaysNavigationPicksVerticallyClosestPane() {
        // 3 panes: [0] [1]
        //          [2] [ ]
        // Both left panes reach the full-height pane 1; from it, moving left
        // lands on whichever left pane is closest to its vertical center.
        let focusedTop = layout(count: 3, focusedIndex: 1)
        #expect(GridLayout.move(from: 0, direction: .right, layout: focusedTop) == 1)
        #expect(GridLayout.move(from: 2, direction: .right, layout: focusedTop) == 1)
        #expect(GridLayout.move(from: 1, direction: .left, layout: focusedTop) == 0)

        // 7 panes: [0] [1] [4]
        //          [2] [3] [5]
        //          [6]
        // From the bottom-left pane, right lands on the lower middle pane.
        let seven = layout(count: 7, focusedIndex: 6)
        #expect(GridLayout.move(from: 6, direction: .right, layout: seven) == 3)
        #expect(GridLayout.move(from: 6, direction: .up, layout: seven) == 2)
        #expect(GridLayout.move(from: 6, direction: .down, layout: seven) == 6)
    }

    @Test func testEmptyGridIsSafe() {
        let layout = layout(count: 0)
        #expect(layout.frames.isEmpty)
        #expect(GridLayout.move(from: 0, direction: .up, layout: layout) == 0)
    }
}
