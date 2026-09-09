import Cocoa
import SwiftUI

/// Hosts the SwiftUI `SimpleGreeterView` in its own plain window. Single instance.
@MainActor
final class GreeterWindowController: NSWindowController {
    convenience init() {
        let hosting = NSHostingController(rootView: SimpleGreeterView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Greeter"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 860, height: 520))
        window.center()
        self.init(window: window)
    }
}
