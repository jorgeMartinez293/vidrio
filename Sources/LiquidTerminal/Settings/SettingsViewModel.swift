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
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        var unique = Array(Set(names)).sorted()
        if !unique.contains(store.current.fontName) {
            unique.insert(store.current.fontName, at: 0)
        }
        self.monospaceFonts = unique
    }

    func reset() {
        store.resetToDefaults()
        settings = store.current
    }

    /// SwiftUI Color binding backed by an RGBAColor keypath.
    func colorBinding(_ keyPath: WritableKeyPath<TerminalSettings, RGBAColor>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: self.settings[keyPath: keyPath].nsColor) },
            set: { self.settings[keyPath: keyPath] = RGBAColor(NSColor($0)) }
        )
    }
}
