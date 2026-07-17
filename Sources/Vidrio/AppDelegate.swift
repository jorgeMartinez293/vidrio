import Cocoa
import Sparkle

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Sparkle auto-updates: checks the appcast on the vidrio-releases repo's gh-pages.
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                                 updaterDelegate: nil,
                                                                 userDriverDelegate: nil)
    
    // Keep strong references to windows to prevent deallocation
    var windows: Set<NSWindow> = []
    // Monotonically increasing counter for window cascade offset
    private var windowCount = 0
    // Set to true when Launch Services hands us files at startup so we don't
    // also create an empty default window.
    private var didReceiveOpenFiles = false
    private lazy var settingsWindowController = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Application did finish launching")

        setupMenu()
        if !didReceiveOpenFiles {
            createNewWindow()
        }

        // async activation
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // Called by Launch Services when the app is opened with one or more files
    // (e.g. `open -a vidrio foo.sh` or double-clicking a script). Each
    // file is executed in its own window via `/bin/bash <path>`.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        didReceiveOpenFiles = true
        for path in filenames {
            createNewWindow(scriptPath: path)
        }
        sender.reply(toOpenOrPrint: .success)
    }
    
    func setupMenu() {
        let menu = NSMenu()
        
        // App Menu
        let appMenuItem = NSMenuItem()
        menu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Ajustes…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(settingsItem)
        let updateItem = NSMenuItem(title: "Buscar actualizaciones…",
                                    action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                    keyEquivalent: "")
        updateItem.target = updaterController
        appMenu.addItem(updateItem)
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        
        // File Menu
        let fileMenuItem = NSMenuItem()
        menu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        
        let newWindowItem = NSMenuItem(title: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(newWindowItem)
        
        let closeWindowItem = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(closeWindowItem)
        
        fileMenuItem.submenu = fileMenu
        
        // Edit Menu
        let editMenuItem = NSMenuItem()
        menu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        
        editMenu.addItem(withTitle: "Undo", action: Selector("undo:"), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector("redo:"), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        
        editMenuItem.submenu = editMenu
        
        NSApp.mainMenu = menu
    }
    
    @objc func newWindow(_ sender: Any?) {
        createNewWindow()
    }

    @objc func openSettings(_ sender: Any?) {
        settingsWindowController.showWindow(nil)
        settingsWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func createNewWindow(scriptPath: String? = nil) {
        let settings = SettingsStore.shared.current
        let font = NSFont(name: settings.fontName, size: CGFloat(settings.fontSize))
            ?? .monospacedSystemFont(ofSize: CGFloat(settings.fontSize), weight: .regular)

        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 800, height: 600)
        let windowSize = WindowSizeCalculator.windowSize(cols: settings.cols, rows: settings.rows, font: font)

        // Offset new windows with an ever-increasing counter so windows
        // don't overlap even after previous ones have been closed
        let offset = CGFloat(windowCount * 20)
        windowCount += 1

        let initialX = (screenSize.width - windowSize.width) / 2
        let initialY = (screenSize.height - windowSize.height) / 2

        let rect = NSRect(
            x: initialX + offset,
            y: initialY - offset, // Move down-right
            width: windowSize.width,
            height: windowSize.height
        )

        let newWindow = TransparentWindow(contentRect: rect)
        newWindow.delegate = self // Track closing

        let viewController = TerminalViewController()
        viewController.settings = settings
        viewController.scriptPath = scriptPath
        newWindow.contentViewController = viewController

        // Add to our set to keep alive
        windows.insert(newWindow)

        newWindow.makeKeyAndOrderFront(nil)
    }
    
    // MARK: - Window Close Handling
    //
    // CRITICAL: We NEVER let NSWindow.close() run. Its internal CA layer
    // teardown triggers a use-after-free crash in SwiftTerm's notification
    // observers (which use [unowned self]). Instead, we intercept the close
    // request, hide the window, and release it on a delay.
    
    func windowShouldClose(_ window: NSWindow) -> Bool {
        dismissWindow(window)
        return false // Prevent NSWindow.close() from running
    }
    
    /// Hides and releases a window without going through NSWindow.close().
    func dismissWindow(_ window: NSWindow) {
        // Clean up terminal process
        if let termVC = window.contentViewController as? TerminalViewController {
            termVC.cleanup()
        }
        
        // Remove delegate to prevent further callbacks
        window.delegate = nil
        
        // Hide the window immediately
        window.orderOut(nil)
        
        // Release after a delay so CA can finish any pending transactions
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.windows.remove(window)
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running like standard Terminal, or close?
        // User said "open several times", maybe implies standard app behavior.
        // Let's return false so Cmd+N works even if all windows closed (if app is running).
        return false
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            createNewWindow()
        }
        return true
    }
}
