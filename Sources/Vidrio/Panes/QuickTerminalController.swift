import Cocoa

/// A glass terminal that drops from the top of the screen on a global shortcut, over any
/// app and on any Space, and slides away when it loses focus.
@MainActor
final class QuickTerminalController {
    private static let heightFraction: CGFloat = 0.45
    private static let slideDuration: TimeInterval = 0.16

    private let makeWindow: (NSRect) -> TransparentWindow
    private(set) var window: TransparentWindow?
    private var resignObserver: NSObjectProtocol?
    /// App that was in front before the terminal appeared, to hand focus back to.
    private var previousApp: NSRunningApplication?

    init(makeWindow: @escaping (NSRect) -> TransparentWindow) {
        self.makeWindow = makeWindow
    }

    func toggle() {
        if let window, window.isVisible, window.isKeyWindow {
            hide(restoringFocus: true)
        } else {
            show()
        }
    }

    private func targetFrame(on screen: NSScreen) -> NSRect {
        let area = screen.visibleFrame
        let height = (area.height * Self.heightFraction).rounded()
        return NSRect(x: area.minX, y: area.maxY - height, width: area.width, height: height)
    }

    private func show() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost != .current { previousApp = frontmost }

        let target = targetFrame(on: screen)
        let window = self.window ?? create(frame: target)
        var start = target
        start.origin.y = screen.frame.maxY
        window.setFrame(start, display: false)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(target, display: true)
        }
    }

    private func create(frame: NSRect) -> TransparentWindow {
        let window = makeWindow(frame)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.attachedSheet == nil else { return }
                self.hide(restoringFocus: false)
            }
        }
        self.window = window
        return window
    }

    private func hide(restoringFocus: Bool) {
        guard let window, window.isVisible else { return }
        var end = window.frame
        end.origin.y = window.screen?.frame.maxY ?? end.maxY
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(end, display: true)
        }, completionHandler: { [weak window] in
            MainActor.assumeIsolated { window?.orderOut(nil) }
        })
        if restoringFocus {
            previousApp?.activate()
        }
    }

    /// Its last pane closed: the next toggle starts a fresh terminal.
    func windowWasDismissed(_ dismissed: NSWindow) {
        guard dismissed === window else { return }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        window = nil
    }
}
