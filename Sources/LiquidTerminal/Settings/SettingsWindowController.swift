import Cocoa
import SwiftUI

/// Hosts the SwiftUI `SettingsView` in a standard titled window. Single instance.
@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init() {
        let viewModel = SettingsViewModel()
        let hosting = NSHostingController(rootView: SettingsView(viewModel: viewModel))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Ajustes"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }
}
