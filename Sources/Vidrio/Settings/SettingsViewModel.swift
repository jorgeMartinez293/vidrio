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

    /// SwiftUI Color binding backed by an RGBAColor keypath.
    func colorBinding(_ keyPath: WritableKeyPath<TerminalSettings, RGBAColor>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: self.settings[keyPath: keyPath].nsColor) },
            set: { self.settings[keyPath: keyPath] = RGBAColor(NSColor($0)) }
        )
    }
}
