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

    @Test func testAppendingRangeMatchesAddingOneAtATime() {
        // Merging a 3-pane window into a 2-pane one must tile exactly as if
        // the three had been opened there one after another.
        let merged = GridLayout.appending(2..<5, to: GridLayout.columns(forCount: 2))
        #expect(merged == GridLayout.columns(forCount: 5))
        #expect(GridLayout.appending(3..<3, to: [[0, 2], [1]]) == [[0, 2], [1]])
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

    @Test func testMergingPlacesIncomingColumnsOnEitherSideOrFills() {
        // Target [0 2] [1], incoming window shaped [a b] [c] -> 3, 4, 5.
        let target = GridLayout.columns(forCount: 3)
        #expect(GridLayout.merging(
            incomingColumnCounts: [2, 1], startingAt: 3, into: target, placement: .left
        ) == [[3, 4], [5], [0, 2], [1]])
        #expect(GridLayout.merging(
            incomingColumnCounts: [2, 1], startingAt: 3, into: target, placement: .right
        ) == [[0, 2], [1], [3, 4], [5]])
        #expect(GridLayout.merging(
            incomingColumnCounts: [2, 1], startingAt: 3, into: target, placement: .fill
        ) == GridLayout.columns(forCount: 6))
    }

    @Test func testSwappingTradesTwoPanesAndKeepsColumnShapes() {
        let columns = GridLayout.columns(forCount: 5) // [0 2] [1 3] [4]
        #expect(GridLayout.swapping(0, 4, in: columns) == [[4, 2], [1, 3], [0]])
        #expect(GridLayout.swapping(3, 1, in: columns) == [[0, 2], [3, 1], [4]])
        #expect(GridLayout.swapping(2, 2, in: columns) == columns)
    }

    private func dropTarget(
        _ point: CGPoint, columns: [[Int]], focusedIndex: Int, moving: Int?
    ) -> GridLayout.DropTarget? {
        let layout = GridLayout.compute(columns: columns, focusedIndex: focusedIndex, bounds: bounds)
        return GridLayout.dropTarget(at: point, in: layout, moving: moving)
    }

    /// The columns after dropping `moving` at `point`, nil if it stays put.
    private func drop(_ moving: Int, at point: CGPoint, in columns: [[Int]]) -> [[Int]]? {
        guard let target = dropTarget(point, columns: columns, focusedIndex: moving, moving: moving) else {
            return nil
        }
        let result = GridLayout.placing(moving, at: target, in: columns)
        return result == columns ? nil : result
    }

    @Test func testSideOfASingleColumnOpensANewColumnAtAnyHeight() {
        // Three panes stacked: the middle one dragged to either side, at
        // the height of any of them, becomes a column of its own.
        let stacked = [[0, 1, 2]]
        for y in [100.0, 400, 700] {
            #expect(drop(1, at: CGPoint(x: 100, y: y), in: stacked) == [[1], [0, 2]])
            #expect(drop(1, at: CGPoint(x: 900, y: y), in: stacked) == [[0, 2], [1]])
        }
        // Two panes stacked: either one can leave for a new column.
        #expect(drop(0, at: CGPoint(x: 100, y: 700), in: [[0, 1]]) == [[0], [1]])
        #expect(drop(1, at: CGPoint(x: 900, y: 100), in: [[0, 1]]) == [[0], [1]])
    }

    @Test func testMiddleOfAColumnPicksTheRowByHalves() {
        let stacked = [[0, 1, 2]]
        // Its own slot keeps it home.
        #expect(drop(1, at: CGPoint(x: 500, y: 400), in: stacked) == nil)
        // Upper half of the top pane: above it; lower half: right where it was.
        #expect(drop(1, at: CGPoint(x: 500, y: 750), in: stacked) == [[1, 0, 2]])
        #expect(drop(1, at: CGPoint(x: 500, y: 600), in: stacked) == nil)
        // Lower half of the bottom pane: below it.
        #expect(drop(1, at: CGPoint(x: 500, y: 50), in: stacked) == [[0, 2, 1]])
    }

    @Test func testTwoColumnsStackIntoOne() {
        // [0] [1], pane 0 dragged over the middle of pane 1's column.
        let sideBySide = [[0], [1]]
        #expect(drop(0, at: CGPoint(x: 800, y: 600), in: sideBySide) == [[0, 1]])
        #expect(drop(0, at: CGPoint(x: 800, y: 200), in: sideBySide) == [[1, 0]])
        // Right side of the right column: the two trade sides.
        #expect(drop(0, at: CGPoint(x: 980, y: 400), in: sideBySide) == [[1], [0]])
        // Left side of the right column is where it already is.
        #expect(drop(0, at: CGPoint(x: 650, y: 400), in: sideBySide) == nil)
    }

    @Test func testNewColumnBetweenTwoColumns() {
        let columns = GridLayout.columns(forCount: 5) // [0 2] [1 3] [4]
        let layout = GridLayout.compute(columns: columns, focusedIndex: 4, bounds: bounds)
        let boundary = (layout.frames[0].maxX + layout.frames[1].minX) / 2
        // Either side of the gap between the first two columns, and the gap
        // itself, open a column there.
        for x in [boundary - 20, boundary, boundary + 20] {
            #expect(drop(4, at: CGPoint(x: x, y: 400), in: columns) == [[0, 2], [4], [1, 3]])
        }
    }

    @Test func testStartingZoneIsRawUntilNormalized() {
        // A pane alone in its column, hovered at its own side, maps to a
        // new column that is the grid as it was.
        let columns = [[0], [1]]
        let target = dropTarget(CGPoint(x: 20, y: 400), columns: columns, focusedIndex: 0, moving: 0)
        #expect(target == .newColumn(at: 0))
        #expect(GridLayout.placing(0, at: .newColumn(at: 0), in: columns) == columns)
    }

    @Test func testPlacingIncomingPaneAndMergingAtTarget() {
        // A pane from another window over a single-pane grid.
        let single = [[0]]
        let above = dropTarget(CGPoint(x: 500, y: 600), columns: single, focusedIndex: 0, moving: nil)
        #expect(above == .row(column: 0, at: 0))
        #expect(GridLayout.merging(
            incomingColumnCounts: [1], startingAt: 1, into: single, placement: .at(above!)
        ) == [[1, 0]])
        let right = dropTarget(CGPoint(x: 950, y: 400), columns: single, focusedIndex: 0, moving: nil)
        #expect(right == .newColumn(at: 1))
        #expect(GridLayout.merging(
            incomingColumnCounts: [1], startingAt: 1, into: single, placement: .at(right!)
        ) == [[0], [1]])
        // Several incoming panes keep their columns at a boundary, or stack
        // in order at a row.
        #expect(GridLayout.merging(
            incomingColumnCounts: [1, 1], startingAt: 2, into: [[0], [1]], placement: .at(.newColumn(at: 1))
        ) == [[0], [2], [3], [1]])
        #expect(GridLayout.merging(
            incomingColumnCounts: [2], startingAt: 2, into: [[0, 1]], placement: .at(.row(column: 0, at: 1))
        ) == [[0, 2, 3, 1]])
        // `placing` adds an index that wasn't in the grid yet.
        #expect(GridLayout.placing(2, at: .row(column: 1, at: 1), in: [[0], [1]]) == [[0], [1, 2]])
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
