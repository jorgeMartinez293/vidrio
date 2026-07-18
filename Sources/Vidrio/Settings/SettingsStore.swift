import Foundation

/// Loads and persists `TerminalSettings` as JSON in `~/.config/vidrio/settings.json`.
/// Single source of truth read by AppDelegate at window-creation time.
///
/// File-backed (not UserDefaults) so other apps — e.g. vaho's themes mode — can
/// snapshot and restore the settings; changes apply to the next window opened,
/// same as changes made in the app's own settings panel.
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    /// UserDefaults key used when the app was named LiquidTerminal. Read once to
    /// migrate old installs, never written again.
    static let legacyStorageKey = "com.jorge.LiquidTerminal.settings"

    nonisolated static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/vidrio/settings.json")

    private let fileURL: URL

    /// Current settings. Mutate then call `save()` to persist.
    var current: TerminalSettings

    init(fileURL: URL = SettingsStore.defaultFileURL, legacyDefaults: UserDefaults? = .standard) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(TerminalSettings.self, from: data) {
            self.current = decoded
        } else if let data = legacyDefaults?.data(forKey: Self.legacyStorageKey),
                  let decoded = try? JSONDecoder().decode(TerminalSettings.self, from: data) {
            // Old LiquidTerminal install: adopt its settings and write them to the
            // new location so the migration only happens once.
            self.current = decoded
            save()
        } else {
            self.current = .defaults
            // Persist immediately, even with untouched defaults: vaho's themes mode
            // detects vidrio as "installed" by checking whether this file exists, so
            // without an eager write, a vidrio that's never had a setting changed is
            // invisible to it (and never gets captured into a theme).
            save()
        }
    }

    /// Clamps and persists `current`.
    func save() {
        current = current.clamped()
        guard let data = try? JSONEncoder().encode(current) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL)
    }

    func resetToDefaults() {
        current = .defaults
        save()
    }
}
