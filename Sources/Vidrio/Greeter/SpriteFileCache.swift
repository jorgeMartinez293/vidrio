import Foundation

/// Thread-safe, in-memory memo of values derived from a sprite file, keyed by the file's
/// path plus its modification date and size so an edited or replaced sprite is recomputed.
/// Every new window renders the same sprite, so without this each one would re-read and
/// re-decode it.
final class SpriteFileCache<Value>: @unchecked Sendable {
    private struct Key: Hashable {
        let path: String
        let modified: Date?
        let size: Int?
        let variant: String
    }

    private let lock = NSLock()
    private var values: [Key: Value] = [:]

    /// Returns the cached value for `url` (and `variant`, for callers that derive more than
    /// one value per file), computing and storing it on a miss. A nil result isn't cached.
    func value(for url: URL, variant: String = "", compute: () -> Value?) -> Value? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = Key(
            path: url.standardizedFileURL.path,
            modified: attributes?[.modificationDate] as? Date,
            size: (attributes?[.size] as? NSNumber)?.intValue,
            variant: variant
        )
        lock.lock()
        let cached = values[key]
        lock.unlock()
        if let cached { return cached }

        guard let value = compute() else { return nil }
        lock.lock()
        // Drop stale entries for this file (older versions) so edits don't accumulate.
        values = values.filter { $0.key.path != key.path || $0.key.variant != key.variant }
        values[key] = value
        lock.unlock()
        return value
    }
}
