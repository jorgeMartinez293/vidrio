import Foundation

/// Loads and persists `TerminalSettings` to UserDefaults as JSON. Single source
/// of truth read by AppDelegate at window-creation time.
@MainActor
final class SettingsStore {
    static let shared = SettingsStore(userDefaults: .standard)
    static let storageKey = "com.jorge.LiquidTerminal.settings"

    private let userDefaults: UserDefaults

    /// Current settings. Mutate then call `save()` to persist.
    var current: TerminalSettings

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(TerminalSettings.self, from: data) {
            self.current = decoded
        } else {
            self.current = .defaults
        }
    }

    /// Clamps and persists `current`.
    func save() {
        current = current.clamped()
        if let data = try? JSONEncoder().encode(current) {
            userDefaults.set(data, forKey: Self.storageKey)
        }
    }

    func resetToDefaults() {
        current = .defaults
        save()
    }
}
