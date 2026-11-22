import SwiftUI

/// Bridges `SettingsStore` to SwiftUI. Every mutation persists immediately
/// (System-Settings style: no Save button).
@MainActor
final class SettingsViewModel: ObservableObject {
    private let store: SettingsStore

    @Published var settings: TerminalSettings {
        didSet {
            store.current = settings
            store.save()
            // Reflect any clamping the store applied.
            if store.current != settings { settings = store.current }
        }
    }

    /// Monospace font family names available on this system.
    let monospaceFonts: [String]

    init(store: SettingsStore = .shared) {
        self.store = store
        self.settings = store.current
        // Use font *family* names (e.g. "SF Mono", "Menlo") rather than
        // PostScript names ("SFMono-Regular"), so the list matches the stored
        // default and resolves cleanly via NSFont(name:size:).
        let manager = NSFontManager.shared
        let monoFamilies = manager.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return manager.traits(of: font).contains(.fixedPitchFontMask)
        }
        var unique = monoFamilies.sorted()
        if !unique.contains(store.current.fontName) {
            unique.insert(store.current.fontName, at: 0)
        }
        self.monospaceFonts = unique
        self.hooksInstalled = (try? AgentHooks.isInstalled(in: AgentHooks.readSettings(at: AgentHooks.claudeSettingsFile))) ?? false
        // Other writers (the clipboard prompt, vaho's themes) change the store directly;
        // without this, the next edit here would save a stale copy over their change.
        reloadObserver = NotificationCenter.default.addObserver(
            forName: Self.storeDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings != self.store.current else { return }
                self.settings = self.store.current
            }
        }
    }

    static let storeDidChange = Notification.Name("VidrioSettingsStoreDidChange")
    /// Never removed: the settings window, and so this model, lives as long as the app.
    private var reloadObserver: NSObjectProtocol?

    // MARK: - Ring

    var ringColorEnabled: Binding<Bool> {
        Binding(
            get: { self.settings.ringColor != nil },
            set: { self.settings.ringColor = $0 ? RGBAColor(NSColor.systemBlue) : nil }
        )
    }

    var ringColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: (self.settings.ringColor ?? RGBAColor(NSColor.systemBlue)).nsColor) },
            set: { self.settings.ringColor = RGBAColor(NSColor($0)) }
        )
    }

    // MARK: - Agent hooks

    @Published private var hooksInstalled: Bool
    @Published private(set) var hooksError: String?

    var agentHooksEnabled: Binding<Bool> {
        Binding(
            get: { self.hooksInstalled },
            set: { enabled in
                do {
                    if enabled {
                        try AgentHooks.install()
                    } else {
                        try AgentHooks.uninstall()
                    }
                    self.hooksInstalled = enabled
                    self.hooksError = nil
                } catch {
                    self.hooksError = error.localizedDescription
                }
            }
        )
    }

    // MARK: - Shortcuts

    /// Text of an action's shortcut. Matching the default removes the override, so
    /// future changes to defaults still reach this action.
    func shortcutBinding(for action: ShortcutAction) -> Binding<String> {
        Binding(
            get: { self.settings.shortcuts[action.rawValue] ?? action.defaultBinding },
            set: { newValue in
                self.settings.shortcuts[action.rawValue] = newValue == action.defaultBinding ? nil : newValue
            }
        )
    }

    func reset() {
        // Assigning settings triggers didSet, which writes through to the store
        // exactly once. (Avoids the double UserDefaults write of also calling
        // store.resetToDefaults() here.)
        settings = .defaults
    }

    /// Whether the optional secondary-text override is active. Enabling seeds a dark,
    /// readable default so the change is visible immediately.
    var secondaryTextEnabled: Binding<Bool> {
        Binding(
            get: { self.settings.secondaryTextColor != nil },
            set: {
                self.settings.secondaryTextColor = $0
                    ? RGBAColor(red: 0.2, green: 0.2, blue: 0.14, alpha: 1) : nil
            }
        )
    }

    var secondaryTextBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: (self.settings.secondaryTextColor ?? .white).nsColor) },
            set: { self.settings.secondaryTextColor = RGBAColor(NSColor($0)) }
        )
    }

    /// Picking a drag modifier the other one already uses trades the two,
    /// so they never end up the same key.
    var rearrangeModifier: Binding<DragModifier> {
        Binding(
            get: { self.settings.rearrangeModifier },
            set: { newValue in
                var s = self.settings
                if newValue == s.swapModifier { s.swapModifier = s.rearrangeModifier }
                s.rearrangeModifier = newValue
                self.settings = s
            }
        )
    }

    var swapModifier: Binding<DragModifier> {
        Binding(
            get: { self.settings.swapModifier },
            set: { newValue in
                var s = self.settings
                if newValue == s.rearrangeModifier { s.rearrangeModifier = s.swapModifier }
                s.swapModifier = newValue
                self.settings = s
            }
        )
    }

    /// SwiftUI Color binding backed by an RGBAColor keypath.
    func colorBinding(_ keyPath: WritableKeyPath<TerminalSettings, RGBAColor>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: self.settings[keyPath: keyPath].nsColor) },
            set: { self.settings[keyPath: keyPath] = RGBAColor(NSColor($0)) }
        )
    }
}
