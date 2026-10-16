import CoreGraphics

/// Pure geometry for tiling N panes into columns, like a tiling window
/// manager: each column splits its own height evenly between the panes it
/// holds, so a column with fewer panes keeps them taller instead of an odd
/// pane out stretching across the whole width. New panes are placed so that
/// existing panes never move (see `appending`), and the focused pane's
/// column is widened and the pane itself made taller within that column so
/// it reads as "the big one".
enum GridLayout {
    struct Result {
        /// Pane frames, indexed the same as the input pane list, in
        /// `bounds`'s coordinate space (AppKit: origin bottom-left).
        let frames: [CGRect]
        /// Pane index -> column (0 = leftmost column).
        let columnOf: [Int]
        /// Pane index -> position within its column (0 = top).
        let rowOf: [Int]
        /// [column][row] -> pane index, leftmost column first, each column
        /// top to bottom. Columns may hold different numbers of panes.
        let indexAt: [[Int]]
    }

    enum Direction {
        case up, down, left, right
    }

    // MARK: - Placement

    /// The column a newly added pane goes into, given how many panes each
    /// existing column holds. Returns `columnCounts.count` when the pane
    /// should open a new column on the right.
    ///
    /// The grid keeps `ceil(sqrt(n))` columns, as square as the pane count
    /// allows: a new column opens only once there are fewer than that;
    /// otherwise the pane goes under the column with the fewest panes
    /// (leftmost on a tie). Either way nothing already placed moves.
    static func columnForNewPane(columnCounts: [Int]) -> Int {
        let newCount = columnCounts.reduce(0, +) + 1
        let targetColumns = Int(ceil(sqrt(Double(newCount))))
        guard columnCounts.count >= targetColumns,
              let fewest = columnCounts.min(),
              let column = columnCounts.firstIndex(of: fewest) else {
            return columnCounts.count
        }
        return column
    }

    /// `columns` with pane `index` placed per `columnForNewPane`, at the
    /// bottom of its column.
    static func appending(_ index: Int, to columns: [[Int]]) -> [[Int]] {
        var columns = columns
        let column = columnForNewPane(columnCounts: columns.map(\.count))
        if column == columns.count {
            columns.append([index])
        } else {
            columns[column].append(index)
        }
        return columns
    }

    /// `columns` with pane `index` taken out — the panes around it keep
    /// their places, an emptied column disappears — and every higher pane
    /// index shifted down by one to match the pane list it was removed from.
    static func removing(_ index: Int, from columns: [[Int]]) -> [[Int]] {
        columns
            .map { column in
                column.filter { $0 != index }.map { $0 > index ? $0 - 1 : $0 }
            }
            .filter { !$0.isEmpty }
    }

    /// The columns panes `0..<count` end up in when added one at a time.
    static func columns(forCount count: Int) -> [[Int]] {
        (0..<max(count, 0)).reduce(into: [[Int]]()) { columns, index in
            columns = appending(index, to: columns)
        }
    }

    // MARK: - Geometry

    /// - Parameters:
    ///   - columns: pane indices per column, leftmost first, each top to
    ///     bottom; together they must cover `0..<paneCount` exactly once.
    ///   - focusWeight: how many times wider the focused pane's column is
    ///     versus a normal one, and how many times taller the focused pane
    ///     is versus the other panes in its column.
    static func compute(
        columns: [[Int]],
        focusedIndex: Int,
        bounds: CGRect,
        spacing: CGFloat = 8,
        focusWeight: CGFloat = 1.7
    ) -> Result {
        let columns = columns.filter { !$0.isEmpty }
        let count = columns.reduce(0) { $0 + $1.count }
        guard count > 0 else {
            return Result(frames: [], columnOf: [], rowOf: [], indexAt: [])
        }
        let focusedIndex = max(0, min(focusedIndex, count - 1))

        var columnOf = [Int](repeating: 0, count: count)
        var rowOf = [Int](repeating: 0, count: count)
        for (c, column) in columns.enumerated() {
            for (r, idx) in column.enumerated() {
                columnOf[idx] = c
                rowOf[idx] = r
            }
        }
        let focusedColumn = columnOf[focusedIndex]

        var columnWeights = [CGFloat](repeating: 1, count: columns.count)
        columnWeights[focusedColumn] = focusWeight
        let totalColumnWeight = columnWeights.reduce(0, +)
        let availableWidth = max(bounds.width - spacing * CGFloat(columns.count + 1), 0)

        // Each column divides the full height between its own panes, so
        // columns of different lengths still all reach top and bottom.
        var frames = [CGRect](repeating: .zero, count: count)
        var x = bounds.minX + spacing
        for (c, column) in columns.enumerated() {
            let width = columnWeights[c] / totalColumnWeight * availableWidth
            var rowWeights = [CGFloat](repeating: 1, count: column.count)
            if c == focusedColumn {
                rowWeights[rowOf[focusedIndex]] = focusWeight
            }
            let totalRowWeight = rowWeights.reduce(0, +)
            let availableHeight = max(bounds.height - spacing * CGFloat(column.count + 1), 0)

            var y = bounds.maxY - spacing
            for (r, idx) in column.enumerated() {
                let height = rowWeights[r] / totalRowWeight * availableHeight
                frames[idx] = CGRect(x: x, y: y - height, width: width, height: height)
                y -= height + spacing
            }
            x += width + spacing
        }

        return Result(frames: frames, columnOf: columnOf, rowOf: rowOf, indexAt: columns)
    }

    /// The pane index that should gain focus moving `direction` from
    /// `index`, or `index` unchanged if there's nowhere to go that way.
    /// Up/down stay within the column; left/right land on the pane in the
    /// neighboring column whose vertical center is closest (upper one on a
    /// tie), since columns' rows don't line up.
    static func move(from index: Int, direction: Direction, layout: Result) -> Int {
        guard layout.columnOf.indices.contains(index) else { return index }
        let column = layout.columnOf[index]
        let row = layout.rowOf[index]

        switch direction {
        case .up:
            guard row > 0 else { return index }
            return layout.indexAt[column][row - 1]
        case .down:
            guard row + 1 < layout.indexAt[column].count else { return index }
            return layout.indexAt[column][row + 1]
        case .left, .right:
            let target = column + (direction == .left ? -1 : 1)
            guard layout.indexAt.indices.contains(target) else { return index }
            let midY = layout.frames[index].midY
            // `indexAt` lists each column top first, so `min(by:)` keeps the
            // upper pane when two are equally close.
            return layout.indexAt[target].min { a, b in
                abs(layout.frames[a].midY - midY) < abs(layout.frames[b].midY - midY)
            } ?? index
        }
    }
}
