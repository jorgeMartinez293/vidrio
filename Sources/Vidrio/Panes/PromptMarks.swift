/// Where each shell prompt started, as absolute rows that stay valid while the scrollback
/// trims old lines. Filled from OSC 133 marks emitted by the zsh shim.
struct PromptMarks: Equatable {
    private(set) var rows: [Int] = []

    mutating func add(_ row: Int) {
        // A redrawn prompt reports a row at or above earlier ones: those marks are stale.
        rows.removeAll { $0 >= row }
        rows.append(row)
    }

    mutating func prune(below firstRow: Int) {
        rows.removeAll { $0 < firstRow }
    }

    mutating func clear() {
        rows.removeAll()
    }

    func previous(before row: Int) -> Int? {
        rows.last { $0 < row }
    }

    func next(after row: Int) -> Int? {
        rows.first { $0 > row }
    }
}
