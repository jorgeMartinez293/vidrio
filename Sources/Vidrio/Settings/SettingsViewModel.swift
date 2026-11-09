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
