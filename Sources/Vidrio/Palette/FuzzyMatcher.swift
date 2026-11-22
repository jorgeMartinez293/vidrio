/// Scores how well a typed query matches a text, allowing skipped characters: `npn` finds
/// "New Pane". Nil means no match; higher is better.
enum FuzzyMatcher {
    static func score(query: String, in text: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let original = Array(text)
        let haystack = original.map { $0.lowercased().first ?? $0 }

        var total = 0
        var position = 0
        var previousMatch: Int?
        for character in needle {
            guard let found = haystack[position...].firstIndex(of: character) else { return nil }
            var points = 1
            if found == 0 {
                points += 10
            } else if !original[found - 1].isLetter && !original[found - 1].isNumber {
                points += 8
            } else if original[found].isUppercase && original[found - 1].isLowercase {
                points += 6
            }
            if let previousMatch {
                points += found == previousMatch + 1 ? 5 : -min(found - previousMatch - 1, 3)
            }
            total += points
            previousMatch = found
            position = found + 1
        }
        return total
    }
}
