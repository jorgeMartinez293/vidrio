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
    private lazy var greeterWindowController = GreeterWindowController()
    /// Watches ~/.config so already-open windows can react live when vaho pushes a theme —
    /// a plain file write to settings.json with no other signal. A Greeter sprite/color
    /// choice deliberately does NOT re-render already-open windows: the greeting only shows
    /// once, when a shell starts, so saving a new sprite mid-session doesn't interrupt it.
    private var configWatcher: ConfigWatcher?

    private var workspaces = WorkspaceList()
    private lazy var palette = CommandPaletteController()
    private lazy var quickTerminal = QuickTerminalController { [unowned self] frame in
        self.makeGridWindow(frame: frame, workspaceID: nil, allowsDrags: false)
    }
    private lazy var quickTerminalHotKey = GlobalHotKey { [weak self] in
        self?.quickTerminal.toggle()
    }
    private var registeredQuickShortcut: String?
    private var chordMatcher = ChordMatcher<ShortcutAction>(bindings: [])
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Application did finish launching")

        setupMenu()
        removeLegacySerenoShellIntegration()
        AttentionCenter.shared.start()
        // Reports from panes of a previous run can't match any pane now.
        try? FileManager.default.removeItem(at: AgentHooks.stateDirectory)
        if !didReceiveOpenFiles {
            createNewWindow()
        }
        startConfigWatcher()
        applyRuntimeShortcuts()

        // async activation
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Idempotent: no-ops once the block is gone.
    private func removeLegacySerenoShellIntegration() {
        LegacySerenoCleanup.run(
            on: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        )
    }

    // MARK: - Config

    /// Exact suffix only — NOT a directory-prefix check.
    private static let vidrioSettingsSuffix = ".config/vidrio/settings.json"

    private func startConfigWatcher() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config").path
        configWatcher = ConfigWatcher(path: configDir) { [weak self] changedPaths in
            MainActor.assumeIsolated { self?.handleConfigChange(changedPaths) }
        }
        configWatcher?.start()
    }

    private func handleConfigChange(_ paths: [String]) {
        AttentionCenter.shared.applyAgentStateFiles(at: paths)
        guard paths.contains(where: { $0.hasSuffix(Self.vidrioSettingsSuffix) }) else { return }
        SettingsStore.shared.reload()
        NotificationCenter.default.post(name: SettingsViewModel.storeDidChange, object: nil)
        setupMenu()
        applyRuntimeShortcuts()
        let settings = SettingsStore.shared.current
        for window in windows {
            (window.contentViewController as? TerminalHosting)?.applySettings(settings)
        }
    }

    // Called by Launch Services when the app is opened with one or more files
    // (e.g. `open -a vidrio foo.sh` or double-clicking a script). Each
    // file is executed in its own window.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        didReceiveOpenFiles = true
        for path in filenames {
            createNewWindow(scriptPath: path)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    // MARK: - Menu

    /// Built from `ShortcutAction`, so a changed shortcut only needs a rebuild.
    func setupMenu() {
        let overrides = SettingsStore.shared.current.shortcuts
        let menu = NSMenu()

        func item(_ action: ShortcutAction) -> NSMenuItem {
            let item = NSMenuItem(title: action.title, action: action.selector, keyEquivalent: "")
            // A two-step chord can't be a menu key equivalent; the key monitor handles it.
            if let binding = action.binding(overrides: overrides), !binding.isChord {
                item.keyEquivalent = binding.steps[0].keyEquivalent
                item.keyEquivalentModifierMask = binding.steps[0].modifierMask
            }
            if let number = action.paneNumber { item.tag = number }
            return item
        }

        /// A top-level menu from actions, with nil as a separator.
        func addMenu(_ title: String, _ actions: [ShortcutAction?]) -> NSMenu {
            let holder = NSMenuItem()
            menu.addItem(holder)
            let submenu = NSMenu(title: title)
            for action in actions {
                submenu.addItem(action.map(item) ?? .separator())
            }
            holder.submenu = submenu
            return submenu
        }

        // App Menu
        let appMenuItem = NSMenuItem()
        menu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(item(.settings))
        appMenu.addItem(NSMenuItem(title: "Greeter…", action: #selector(openGreeter(_:)), keyEquivalent: ""))
        let updateItem = NSMenuItem(title: "Check for Updates…",
                                    action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                    keyEquivalent: "")
        updateItem.target = updaterController
        appMenu.addItem(updateItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit vidrio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        // Routed through the responder chain: a grid window's GridViewController
        // closes just the focused pane; anywhere else it falls back to
        // closeFocusedTerminal(_:) below, which closes the key window.
        _ = addMenu("File", [.newWindow, .newPane, nil, .closePane])

        let editMenu = addMenu("Edit", [])
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        for action in [ShortcutAction.find, .findNext, .findPrevious] {
            editMenu.addItem(item(action))
        }

        let viewMenu = addMenu("View", [
            .commandPalette, nil, .clearTerminal, .previousPrompt, .nextPrompt, nil,
            .increaseFont, .decreaseFont, .resetFont, nil, .toggleFullScreen,
        ])
        // ⌘+ needs Shift on layouts where + shares a key with =, so ⌘= works too.
        if ShortcutAction.increaseFont.binding(overrides: overrides)?.text == "cmd+plus" {
            let alternate = NSMenuItem(
                title: ShortcutAction.increaseFont.title,
                action: ShortcutAction.increaseFont.selector, keyEquivalent: "="
            )
            alternate.isHidden = true
            alternate.allowsKeyEquivalentWhenHidden = true
            viewMenu.addItem(alternate)
        }

        // Each action is only implemented by GridViewController, so AppKit's
        // automatic responder-chain validation disables them in a plain
        // (non-grid) window instead of doing nothing silently.
        _ = addMenu("Pane", [
            .zoomPane, .jumpToUnread, nil,
            .focusUp, .focusDown, .focusLeft, .focusRight, nil,
            .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5,
            .focusPane6, .focusPane7, .focusPane8, .focusPane9,
        ])

        _ = addMenu("Workspaces", [
            .workspaceSwitcher, nil, .newWorkspace, .renameWorkspace, nil, .nextWorkspace, .previousWorkspace,
        ])

        let windowMenu = addMenu("Window", [.minimizeWindow])
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = menu
    }

    /// Chords and the global hotkey, which menus can't express.
    private func applyRuntimeShortcuts() {
        let settings = SettingsStore.shared.current
        chordMatcher = ChordMatcher(bindings: ShortcutAction.allCases.compactMap { action in
            action.binding(overrides: settings.shortcuts).map { (action, $0) }
        })
        if chordMatcher.isEmpty {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        } else if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Local monitors always run on the main thread.
                nonisolated(unsafe) let mainThreadEvent = event
                let consumed = MainActor.assumeIsolated { self?.handleChordKey(mainThreadEvent) == true }
                return consumed ? nil : event
            }
        }

        let wanted = settings.quickTerminalEnabled ? settings.quickTerminalShortcut : nil
        guard wanted != registeredQuickShortcut else { return }
        registeredQuickShortcut = wanted
        if let wanted, let combo = KeyCombo(wanted) {
            quickTerminalHotKey.register(combo)
        } else {
            quickTerminalHotKey.unregister()
        }
    }

    /// Returns true if the key belonged to a chord and must not reach the terminal.
    private func handleChordKey(_ event: NSEvent) -> Bool {
        guard NSApp.keyWindow is TransparentWindow, let combo = KeyCombo(event: event) else { return false }
        switch chordMatcher.handle(combo) {
        case .ignored:
            return false
        case .pending, .cancelled:
            return true
        case .fired(let action):
            NSApp.sendAction(action.selector, to: nil, from: paneNumberSender(for: action))
            return true
        }
    }

    /// `focusPaneByNumber` reads the number from its sender's tag.
    private func paneNumberSender(for action: ShortcutAction) -> NSMenuItem? {
        guard let number = action.paneNumber else { return nil }
        let sender = NSMenuItem()
        sender.tag = number
        return sender
    }

    // MARK: - Commands

    @objc func newWindow(_ sender: Any?) {
        createNewWindow()
    }

    @objc func openSettings(_ sender: Any?) {
        settingsWindowController.showWindow(nil)
        settingsWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openGreeter(_ sender: Any?) {
        greeterWindowController.showWindow(nil)
        greeterWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func jumpToLatestUnread(_ sender: Any?) {
        AttentionCenter.shared.jumpToLatestUnread()
    }

    @objc func showCommandPalette(_ sender: Any?) {
        let overrides = SettingsStore.shared.current.shortcuts
        let commands = ShortcutAction.allCases
            .filter { $0 != .commandPalette && $0.paneNumber == nil }
            .map { action in
                PaletteItem(
                    title: action.title.replacingOccurrences(of: "…", with: ""),
                    shortcut: action.binding(overrides: overrides)?.symbol ?? ""
                ) {
                    NSApp.sendAction(action.selector, to: nil, from: nil)
                }
            }
        let panes = allPanes().map { pane in
            PaletteItem(title: "Go to \(pane.displayTitle)", subtitle: Self.location(of: pane)) { [weak self, weak pane] in
                if let pane { self?.reveal(pane) }
            }
        }
        let switches = workspaces.workspaces.filter { $0.id != workspaces.activeID }.map { workspace in
            PaletteItem(title: "Switch to \(workspace.name)", subtitle: "Workspace") { [weak self] in
                self?.activateWorkspace(workspace.id)
            }
        }
        palette.show(items: commands + panes + switches, placeholder: "Type a command or pane…", over: NSApp.keyWindow)
    }

    private static func location(of pane: TerminalViewController) -> String {
        guard let directory = pane.currentDirectory else { return "" }
        let path = (directory as NSString).abbreviatingWithTildeInPath
        return PaneInfo.gitBranch(forDirectory: directory).map { "\(path)  ⎇ \($0)" } ?? path
    }

    // MARK: - Workspaces

    private var terminalWindows: [TransparentWindow] {
        windows.compactMap { $0 as? TransparentWindow }
            .filter { $0.delegate != nil && $0 !== quickTerminal.window }
    }

    private func windows(in workspace: UUID) -> [TransparentWindow] {
        terminalWindows.filter { $0.workspaceID == workspace }
    }

    private func grids(in workspace: UUID) -> [GridViewController] {
        windows(in: workspace).compactMap { $0.contentViewController as? GridViewController }
    }

    private func allPanes() -> [TerminalViewController] {
        terminalWindows
            .compactMap { $0.contentViewController as? GridViewController }
            .flatMap(\.paneControllers)
    }

    @objc func showWorkspaceSwitcher(_ sender: Any?) {
        palette.show(
            items: workspaceItems(ports: [:]), placeholder: "Switch workspace…", over: NSApp.keyWindow,
            selecting: workspaces.workspaces.firstIndex { $0.id == workspaces.activeID } ?? 0
        )

        // Listening ports need `lsof`, so they fill in once it answers.
        let shells = Set(allPanes().compactMap(\.shellPID))
        Task.detached(priority: .userInitiated) {
            let ports = PaneInfo.listeningPorts(forShells: shells)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.palette.update(items: self.workspaceItems(ports: ports))
            }
        }
    }

    private func workspaceItems(ports: [pid_t: [Int]]) -> [PaletteItem] {
        var items = workspaces.workspaces.map { workspace -> PaletteItem in
            let panes = grids(in: workspace.id).flatMap(\.paneControllers)
            var details = ["\(panes.count) \(panes.count == 1 ? "pane" : "panes")"]
            if let first = panes.first { details.append(Self.location(of: first)) }
            let open = Set(panes.compactMap(\.shellPID).flatMap { ports[$0] ?? [] }).sorted()
            if !open.isEmpty { details.append(open.map { ":\($0)" }.joined(separator: " ")) }
            let isActive = workspace.id == workspaces.activeID
            return PaletteItem(
                title: workspace.name, subtitle: details.joined(separator: "  ·  "),
                shortcut: isActive ? "Current" : ""
            ) { [weak self] in
                self?.activateWorkspace(workspace.id)
            }
        }
        items.append(PaletteItem(title: "New Workspace") { [weak self] in
            self?.newWorkspace(nil)
        })
        return items
    }

    @objc func newWorkspace(_ sender: Any?) {
        guard let name = askForName(title: "New Workspace", initial: "Workspace \(workspaces.workspaces.count + 1)")
        else { return }
        let workspace = workspaces.add(name: name)
        activateWorkspace(workspace.id)
    }

    @objc func renameWorkspace(_ sender: Any?) {
        let active = workspaces.active
        guard let name = askForName(title: "Rename Workspace", initial: active.name) else { return }
        workspaces.rename(active.id, to: name)
    }

    @objc func selectNextWorkspace(_ sender: Any?) {
        activateWorkspace(workspaces.neighbor(offset: 1).id)
    }

    @objc func selectPreviousWorkspace(_ sender: Any?) {
        activateWorkspace(workspaces.neighbor(offset: -1).id)
    }

    private func askForName(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// Hides the current workspace's windows and shows the target's. A new workspace opens
    /// its first window where the current one was, so switching feels like staying put.
    private func activateWorkspace(_ id: UUID) {
        guard id != workspaces.activeID else {
            windows(in: id).first?.makeKeyAndOrderFront(nil)
            return
        }
        let previous = windows(in: workspaces.activeID)
        let anchor = (NSApp.keyWindow as? TransparentWindow)?.frame ?? previous.first?.frame
        for window in previous where window.isVisible {
            window.orderOut(nil)
        }
        workspaces.activate(id)
        showActiveWorkspace(anchor: anchor)
    }

    private func showActiveWorkspace(anchor: NSRect? = nil) {
        let target = windows(in: workspaces.activeID).filter { !$0.isMiniaturized }
        if target.isEmpty {
            createNewWindow(frame: anchor)
        } else {
            target.forEach { $0.orderFront(nil) }
            target.last?.makeKeyAndOrderFront(nil)
        }
    }

    /// Brings a pane forward from anywhere: another workspace, window or app.
    func reveal(_ pane: TerminalViewController) {
        guard let window = pane.view.window else { return }
        if let workspace = (window as? TransparentWindow)?.workspaceID, workspace != workspaces.activeID {
            activateWorkspace(workspace)
        }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        (window.contentViewController as? GridViewController)?.focus(pane)
    }

    // MARK: - Windows

    /// A grid window at `frame`, not yet shown.
    private func makeGridWindow(frame: NSRect, workspaceID: UUID?, allowsDrags: Bool) -> TransparentWindow {
        let window = TransparentWindow(contentRect: frame)
        window.delegate = self // Track closing
        window.workspaceID = workspaceID
        // Every interactive window is a grid that starts with a single pane —
        // visually identical to a single terminal, but it can grow into a
        // tiled multi-session grid.
        let grid = GridViewController()
        grid.settings = SettingsStore.shared.current
        window.contentViewController = grid
        // Setting the content view controller sizes the window to its
        // placeholder view; put it back.
        window.setFrame(frame, display: false)
        if allowsDrags { enableGridDrags(on: window) }
        windows.insert(window) // Add to our set to keep alive
        return window
    }

    func createNewWindow(scriptPath: String? = nil, frame: NSRect? = nil) {
        let settings = SettingsStore.shared.current
        let rect = frame ?? nextWindowFrame()

        if let scriptPath {
            // A one-off script window isn't a session to tile — it runs the
            // file and is expected to close on its own, so it keeps the
            // original plain single-terminal controller.
            let newWindow = TransparentWindow(contentRect: rect)
            newWindow.delegate = self
            newWindow.workspaceID = workspaces.activeID
            let viewController = TerminalViewController()
            viewController.settings = settings
            viewController.scriptPath = scriptPath
            newWindow.contentViewController = viewController
            newWindow.setFrame(rect, display: false)
            windows.insert(newWindow)
            newWindow.makeKeyAndOrderFront(nil)
            return
        }
        makeGridWindow(frame: rect, workspaceID: workspaces.activeID, allowsDrags: true)
            .makeKeyAndOrderFront(nil)
    }

    private func nextWindowFrame() -> NSRect {
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 800, height: 600)
        let windowSize = defaultWindowSize()

        // Offset new windows with an ever-increasing counter so windows
        // don't overlap even after previous ones have been closed
        let offset = CGFloat(windowCount * 20)
        windowCount += 1

        return NSRect(
            x: (screenSize.width - windowSize.width) / 2 + offset,
            y: (screenSize.height - windowSize.height) / 2 - offset, // Move down-right
            width: windowSize.width,
            height: windowSize.height
        )
    }

    /// Window size that fits the settings' columns × rows in the settings'
    /// font.
    private func defaultWindowSize() -> CGSize {
        let settings = SettingsStore.shared.current
        let font = NSFont(name: settings.fontName, size: CGFloat(settings.fontSize))
            ?? .monospacedSystemFont(ofSize: CGFloat(settings.fontSize), weight: .regular)
        return WindowSizeCalculator.windowSize(cols: settings.cols, rows: settings.rows, font: font)
    }

    /// Opens a default-sized grid window around a pane torn off another
    /// window, live shell included, instead of starting a new shell. The
    /// window's top-left corner goes where the pane was dropped
    /// (`droppedFrame`, screen coordinates), kept on screen. Returns the
    /// window's frame.
    @discardableResult
    func createWindow(adopting pane: TerminalViewController, droppedAt droppedFrame: NSRect) -> NSRect {
        let size = defaultWindowSize()
        var frame = NSRect(
            x: droppedFrame.minX, y: droppedFrame.maxY - size.height,
            width: size.width, height: size.height
        )
        let topLeft = NSPoint(x: droppedFrame.minX, y: droppedFrame.maxY)
        let screen = NSScreen.screens.first { $0.frame.contains(topLeft) }
            ?? NSScreen.screens.first { $0.frame.intersects(droppedFrame) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // Right and bottom edges first, so a window larger than the
            // screen still keeps its top-left corner (and titlebar) visible.
            frame.origin.x = max(min(frame.minX, visible.maxX - frame.width), visible.minX)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }

        let newWindow = makeGridWindow(frame: frame, workspaceID: workspaces.activeID, allowsDrags: true)
        (newWindow.contentViewController as? GridViewController)?.initialPane = pane
        newWindow.makeKeyAndOrderFront(nil)
        return frame
    }

    /// ⌘-drag by the top strip onto another window merges this window's
    /// panes into it; ⌘-dragging a pane out of it moves that pane into the
    /// window it's dropped on, or into a window of its own.
    private func enableGridDrags(on window: TransparentWindow) {
        window.makeMergeSession = { [weak self] window in
            guard let self else { return nil }
            return WindowMergeSession(
                source: window,
                candidates: { [weak self] in self?.orderedTerminalWindows() ?? [] },
                dismiss: { [weak self] in self?.dismissWindow($0) }
            )
        }
        window.makePaneTearOff = { [weak self] window, grid, mouse in
            guard self != nil else { return nil }
            return PaneTearOffSession(
                sourceWindow: window,
                sourceGrid: grid,
                at: mouse,
                candidates: { [weak self] in self?.orderedTerminalWindows() ?? [] },
                openWindow: { [weak self] pane, droppedFrame in
                    self?.createWindow(adopting: pane, droppedAt: droppedFrame) ?? droppedFrame
                }
            )
        }
    }

    /// This app's visible terminal windows, front to back: what a drag can drop onto.
    private func orderedTerminalWindows() -> [NSWindow] {
        let candidates = Set(terminalWindows.map { $0 as NSWindow })
        return NSApp.orderedWindows.filter { candidates.contains($0) && $0.isVisible }
    }

    /// Fallback for ⌘W outside a grid window (e.g. a script-launched
    /// window). GridViewController implements the same selector to close
    /// just the focused pane instead; AppKit's responder chain always tries
    /// the key window's view controller before falling back to the app
    /// delegate, so this only fires when that implementation isn't there.
    @objc func closeFocusedTerminal(_ sender: Any?) {
        NSApp.keyWindow?.performClose(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        ((notification.object as? NSWindow)?.contentViewController as? GridViewController)?.markFocusedPaneRead()
    }

    // MARK: - Window Close Handling
    //
    // CRITICAL: We NEVER let NSWindow.close() run. Its internal CA layer
    // teardown triggers a use-after-free crash in SwiftTerm's notification
    // observers (which use [unowned self]). Instead, we intercept the close
    // request, hide the window, and release it on a delay.

    func windowShouldClose(_ window: NSWindow) -> Bool {
        let busy = (window.contentViewController as? TerminalHosting)?.busyProcessNames ?? []
        if let sheet = window.attachedSheet {
            // A question is already up. If its program has since ended there
            // is nothing left to ask about.
            if busy.isEmpty {
                window.endSheet(sheet, returnCode: .cancel)
                dismissWindow(window)
            }
        } else if busy.isEmpty {
            dismissWindow(window)
        } else {
            CloseConfirmation.present(.window, processNames: busy, on: window) { [weak self, weak window] confirmed in
                // The delegate is cleared once a window has been dismissed.
                guard confirmed, let self, let window, window.delegate != nil else { return }
                self.dismissWindow(window)
            }
        }
        return false // Prevent NSWindow.close() from running
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = windows.flatMap { ($0.contentViewController as? TerminalHosting)?.busyProcessNames ?? [] }
        guard !busy.isEmpty else { return .terminateNow }
        return CloseConfirmation.confirm(.app, processNames: busy) ? .terminateNow : .terminateCancel
    }

    /// Hides and releases a window without going through NSWindow.close().
    func dismissWindow(_ window: NSWindow) {
        // Clean up terminal process(es)
        if let host = window.contentViewController as? TerminalHosting {
            host.cleanup()
        }

        // Remove delegate to prevent further callbacks
        window.delegate = nil

        // Hide the window immediately
        window.orderOut(nil)

        // Release after a delay so CA can finish any pending transactions
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.windows.remove(window)
        }

        if window === quickTerminal.window {
            quickTerminal.windowWasDismissed(window)
        } else if let workspace = (window as? TransparentWindow)?.workspaceID {
            removeWorkspaceIfEmpty(workspace)
        }
    }

    /// A workspace lives as long as it has windows, unless it's the only one left.
    private func removeWorkspaceIfEmpty(_ id: UUID) {
        guard windows(in: id).isEmpty, workspaces.workspaces.count > 1 else { return }
        let wasActive = id == workspaces.activeID
        workspaces.remove(id)
        if wasActive {
            showActiveWorkspace()
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
            showActiveWorkspace()
        }
        return true
    }
}
