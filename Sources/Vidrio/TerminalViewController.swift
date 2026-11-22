import Cocoa
import SwiftTerm

// MARK: - VidrioTerminalView

/// Subclass of LocalProcessTerminalView that fixes a display issue when running
/// full-screen TUI apps (claude, vim, htop, etc.):
///
/// When the alternate screen buffer is activated/deactivated (e.g. entering or
/// exiting vim), `bufferActivated()` snaps the view to the correct scroll
/// position. Without this a stale `yDisp` can leave the view showing the wrong
/// portion of the buffer.
///
/// It also restricts trackpad scrolling to two fingers: it tracks the fingers
/// on the trackpad and drops scroll events made with three or more.
fileprivate class VidrioTerminalView: LocalProcessTerminalView {

    private var scrollFilter = TwoFingerScrollFilter()

    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        // Ensure the view is scrolled to the bottom of the new buffer after
        // any buffer switch so current content is always visible.
        scroll(toPosition: 1.0)
    }

    /// Typing returns to the live screen. Programs that draw by moving the cursor never
    /// bring the view back themselves, so a TUI launched while scrolled up would otherwise
    /// render out of sight. Replies the terminal sends on its own aren't key events and
    /// leave the view where the user put it.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if NSApp.currentEvent?.type == .keyDown {
            scroll(toPosition: 1.0)
        }
        super.send(source: source, data: data)
    }

    override func paste(_ sender: Any) {
        scroll(toPosition: 1.0)
        super.paste(sender)
    }

    /// Called with the viewport position whenever it moves. SwiftTerm doesn't forward this
    /// to `LocalProcessTerminalViewDelegate`, so it has to be picked up here.
    var onScrolled: ((Double) -> Void)?

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        onScrolled?(position)
    }

    override func scrollWheel(with event: NSEvent) {
        guard scrollFilter.shouldDeliver(phase: event.phase, momentumPhase: event.momentumPhase) else { return }
        super.scrollWheel(with: event)
    }

    override func touchesBegan(with event: NSEvent) {
        updateTouchCount(with: event)
        super.touchesBegan(with: event)
    }

    override func touchesMoved(with event: NSEvent) {
        updateTouchCount(with: event)
        super.touchesMoved(with: event)
    }

    override func touchesEnded(with event: NSEvent) {
        updateTouchCount(with: event)
        super.touchesEnded(with: event)
    }

    override func touchesCancelled(with event: NSEvent) {
        updateTouchCount(with: event)
        super.touchesCancelled(with: event)
    }

    private func updateTouchCount(with event: NSEvent) {
        scrollFilter.touchesChanged(count: event.touches(matching: .touching, in: self).count)
    }
}

// MARK: - TerminalViewController

class TerminalViewController: NSViewController, LocalProcessTerminalViewDelegate {

    fileprivate var terminalView: VidrioTerminalView!
    /// Solid color layer between the blur and the terminal text. Empty (clear)
    /// when `settings.backgroundColorEnabled` is false, preserving pure blur.
    private var backgroundOverlay: NSView!
    private var backdropView: BackdropView!
    var isClosing = false
    private var processStarted = false
    private var processExited = false
    private var didTerminateProcess = false
    private var scrollIndicator: ScrollIndicatorView!
    /// Exported to the shell as `VIDRIO_PANE_ID`, so agent hooks can report to this pane.
    let paneID = UUID().uuidString
    /// Directory the shell starts in. Nil means the home directory.
    var initialDirectory: String?
    /// Called when the unread mark, agent state or ring color changes.
    var onStatusChange: (() -> Void)?
    var hasUnreadActivity = false { didSet { onStatusChange?() } }
    var agentState: AgentState? { didSet { onStatusChange?() } }
    private var linkHighlight: LinkHighlightView?
    private var paneTitle: String?
    private var eventProxy: TerminalEventProxy?
    private var findBar: FindBarView?
    private var promptMarks = PromptMarks()
    /// Last known index of the oldest line still in the scrollback.
    private var knownFirstRow = 0
    private var lastColumnCount = 0
    private var fontOffset: Double = 0
    private var kittyNotifications = KittyNotificationAssembler()
    private var isAskingAboutClipboard = false
    /// The ANSI palette currently installed, if the greeter's replaced the default one.
    private var installedPalette: [String]?
    private var shellExecutable: String = "/bin/zsh"
    private var shellEnvironment: [String] = []
    /// If set, the terminal launches `/bin/bash <scriptPath>` instead of an
    /// interactive shell. Used when vidrio is opened with a file
    /// (Launch Services `application(_:openFiles:)`).
    var scriptPath: String?
    /// Appearance/launch settings applied at setup. Injected by AppDelegate
    /// before the view loads; defaults reproduce the original hardcoded look.
    var settings: TerminalSettings = .defaults
    /// Greeter config and sprite for this shell, resolved once in `setupTerminal()` so the
    /// prompt color and the greeting always come from the same sprite — with no fixed
    /// selection the sprite is picked at random, and resolving twice could pick two.
    private var greeterConfig = GreeterConfig()
    private var greeterSprite: URL?
    /// The color of this pane's greeter bullets and prompt.
    private var greeterAccent: SpriteColor?

    /// Called when the shell process exits. When set (hosted as a pane in
    /// `GridViewController`), the host decides what to do with the pane
    /// instead of this controller closing the whole window. When nil, falls
    /// back to the original standalone-window behavior.
    var onProcessExit: (() -> Void)?
    /// Whether shell OSC title updates (`setTerminalTitle`) are written to
    /// the containing window's title. A grid with several panes only wants
    /// its currently-focused pane driving the title.
    var forwardsTitleToWindow: Bool = true

    /// Content corner radius and edge insets. Defaults reproduce the app's
    /// original single-window look (28pt radius, 50pt top inset to clear the
    /// window's traffic lights). A host tiling several panes shrinks these
    /// since only the grid as a whole — not each pane — needs to clear the
    /// buttons. Live-updatable: changing these after the view has loaded
    /// immediately re-applies them.
    var cornerRadius: CGFloat = 28 { didSet { updateChrome() } }
    var topInset: CGFloat = 50 { didSet { updateChrome() } }
    var sideInset: CGFloat = 10 { didSet { updateChrome() } }
    var bottomInset: CGFloat = 10 { didSet { updateChrome() } }

    /// Whether this controller draws its own blur. A host that already
    /// puts one behind the whole pane (`GridViewController`'s cells) turns
    /// it off: Liquid Glass stacked on glass would darken the pane twice.
    var showsBackdrop: Bool = true { didSet { applyBackdrop() } }

    private func applyBackdrop() {
        guard let backdropView else { return }
        backdropView.apply(showsBackdrop ? settings.blurMaterial : .none)
    }

    private var terminalTopConstraint: NSLayoutConstraint!
    private var terminalLeadingConstraint: NSLayoutConstraint!
    private var terminalTrailingConstraint: NSLayoutConstraint!
    private var terminalBottomConstraint: NSLayoutConstraint!

    /// Only the bottom corners are rounded. The top edge is clipped by the
    /// window's title bar, which is already a straight cut — rounding the
    /// top corners here as well just carves an extra curve out of content
    /// that sits right under that straight bar.
    private static let bottomCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

    private func updateChrome() {
        guard isViewLoaded, terminalTopConstraint != nil else { return }
        backdropView.cornerRadius = cornerRadius
        backgroundOverlay.layer?.cornerRadius = cornerRadius
        terminalView.layer?.cornerRadius = cornerRadius
        backdropView.maskedCorners = Self.bottomCorners
        backgroundOverlay.layer?.maskedCorners = Self.bottomCorners
        terminalView.layer?.maskedCorners = Self.bottomCorners
        terminalTopConstraint.constant = topInset
        terminalLeadingConstraint.constant = sideInset
        terminalTrailingConstraint.constant = -sideInset
        terminalBottomConstraint.constant = -bottomInset
    }

    /// Makes this pane's terminal the window's first responder. Used by
    /// `GridViewController` to move keyboard focus between panes.
    func focusTerminal() {
        view.window?.makeFirstResponder(terminalView)
    }

    /// Whether `responder` is this pane's terminal — used by
    /// `GridViewController` to tell which pane the user clicked into via
    /// `TransparentWindow.onFirstResponderChange`.
    func owns(_ responder: NSResponder?) -> Bool {
        responder === terminalView
    }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.view.wantsLayer = true
        self.view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        print("TerminalViewController loaded view")
        setupTerminal()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Start the shell process only after the first layout pass so the
        // terminal view has its final dimensions and the PTY is initialized
        // with the correct rows/cols count.
        guard !processStarted else { return }
        processStarted = true
        if let scriptPath {
            // The window closes by itself when this succeeds; on failure it
            // stays open so the error can be read (see `processTerminated`).
            let launch = ScriptLaunch.resolve(path: scriptPath)
            terminalView.startProcess(
                executable: launch.executable,
                args: launch.args,
                environment: shellEnvironment
            )
        } else {
            terminalView.startProcess(
                executable: shellExecutable,
                args: [],
                environment: shellEnvironment,
                execName: ShellLaunch.loginArgv0(forShell: shellExecutable),
                currentDirectory: startingDirectory
            )
            refreshSerenoGreeter()
        }
    }

    /// `initialDirectory` if it still exists: the pane it came from may have deleted it.
    private var startingDirectory: String? {
        guard let initialDirectory else { return nil }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: initialDirectory, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? initialDirectory : nil
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(terminalView)
    }

    /// Safely tears down the terminal process and delegate references.
    /// IMPORTANT: Do NOT remove views from the hierarchy here. SwiftTerm's
    /// TerminalView registers notification observers with [unowned self].
    /// Removing the view from its superview can trigger resign-main notifications
    /// that access the unowned reference during CA layer teardown, causing a
    /// use-after-free crash in NSConcretePointerArray during CA transaction commit.
    /// The views will be safely deallocated when the window itself is released.
    func cleanup() {
        guard !isClosing else { return }
        isClosing = true
        AttentionCenter.shared.unregister(self)
        linkHighlight?.clear()

        // Prevent any further delegate callbacks
        terminalView?.processDelegate = nil

        terminateProcessOnce()
    }

    /// `terminate()` signals the stored pid, so it must not run again once that pid has been
    /// reaped: the system could have reused it for an unrelated process by then.
    private func terminateProcessOnce() {
        guard !didTerminateProcess else { return }
        didTerminateProcess = true
        terminalView?.terminate()
    }

    /// The program that closing this terminal would interrupt: whatever holds the terminal's
    /// foreground, or the script itself. Nil at an idle shell prompt.
    var busyProcessName: String? {
        guard processStarted, !processExited, !isClosing,
              let process = terminalView?.process, process.running else { return nil }
        if let scriptPath {
            return URL(fileURLWithPath: scriptPath).lastPathComponent
        }
        let foreground = tcgetpgrp(process.childfd)
        guard foreground > 0, foreground != process.shellPid else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(foreground, &buffer, UInt32(buffer.count)) > 0 else { return "A program" }
        return String(cString: buffer)
    }

    var busyProcessNames: [String] { busyProcessName.map { [$0] } ?? [] }

    func terminal(atWindowPoint point: NSPoint) -> TerminalViewController? { self }

    // MARK: - Pane facts

    /// The shell's current directory.
    var currentDirectory: String? {
        guard !processExited, let pid = terminalView?.process.shellPid, pid > 0 else {
            return initialDirectory
        }
        return PaneInfo.workingDirectory(pid: pid) ?? initialDirectory
    }

    var shellPID: pid_t? {
        guard !processExited, let pid = terminalView?.process.shellPid, pid > 0 else { return nil }
        return pid
    }

    /// What to call this pane in lists and notifications.
    var displayTitle: String {
        if let paneTitle, !paneTitle.isEmpty { return paneTitle }
        if let directory = currentDirectory {
            return directory == NSHomeDirectory() ? "~" : (directory as NSString).lastPathComponent
        }
        return "vidrio"
    }

    /// Whether the user is looking at this pane right now.
    var isFrontmostPane: Bool {
        guard NSApp.isActive, let window = view.window, window.isKeyWindow else { return false }
        return (window.contentViewController as? GridViewController)?.isFocused(self) ?? true
    }

    // MARK: - Terminal requests

    private func installEventProxy() {
        let proxy = TerminalEventProxy(view: terminalView)
        proxy.onOpenLink = { link in
            guard LinkPolicy.allowsURL(link), let url = URL(string: link) else { return }
            NSWorkspace.shared.open(url)
        }
        proxy.onClipboardWrite = { [weak self] content in self?.handleClipboardWrite(content) }
        proxy.onBell = { [weak self] in
            guard let self else { return }
            AttentionCenter.shared.ring(self)
        }
        proxy.onContentChanged = { [weak self] in self?.refreshLinkHighlight() }
        eventProxy = proxy
        terminalView.terminalDelegate = proxy
    }

    private func registerOSCHandlers() {
        let terminal: Terminal = terminalView.terminal
        func onText(_ code: Int, _ handle: @escaping @MainActor (TerminalViewController, String) -> Void) {
            terminal.registerOscHandler(code: code) { [weak self] data in
                let text = String(decoding: data, as: UTF8.self)
                Task { @MainActor [weak self] in
                    if let self { handle(self, text) }
                }
            }
        }
        onText(9) { pane, text in pane.receive(TerminalNotificationParser.parseOSC9(text)) }
        onText(777) { pane, text in pane.receive(TerminalNotificationParser.parseOSC777(text)) }
        onText(99) { pane, text in pane.receive(pane.kittyNotifications.feed(text)) }
        onText(Self.agentStateOSCCode) { pane, text in
            guard let report = AgentStateReport.parse(text) else { return }
            AttentionCenter.shared.apply(report, to: pane)
        }
        // Read synchronously: the mark is only right for where the cursor is at this moment.
        terminal.registerOscHandler(code: 133) { [weak self] data in
            guard data.first == UInt8(ascii: "A"), Thread.isMainThread else { return }
            MainActor.assumeIsolated { self?.recordPrompt() }
        }
    }

    /// OSC any tool can use to set the pane's status dot: `working`, `waiting`, `done`,
    /// `error`, or `ended` to clear it.
    private static let agentStateOSCCode = 7771

    private func receive(_ message: TerminalMessage?) {
        guard let message else { return }
        AttentionCenter.shared.notify(self, message: message)
    }

    private func handleClipboardWrite(_ content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        switch SettingsStore.shared.current.clipboardAccess {
        case .allow: Self.copyToClipboard(text)
        case .deny: break
        case .ask: askBeforeCopying(text)
        }
    }

    private static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func askBeforeCopying(_ text: String) {
        guard !isAskingAboutClipboard, let window = view.window, window.attachedSheet == nil else { return }
        isAskingAboutClipboard = true
        let alert = NSAlert()
        alert.messageText = "Allow this program to change the clipboard?"
        let preview = text.prefix(200)
        alert.informativeText = preview + (text.count > preview.count ? "…" : "")
        alert.addButton(withTitle: "Don't Allow")
        alert.addButton(withTitle: "Allow")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Always allow"
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            MainActor.assumeIsolated {
                self?.isAskingAboutClipboard = false
                guard response == .alertSecondButtonReturn else { return }
                Self.copyToClipboard(text)
                if alert?.suppressionButton?.state == .on {
                    SettingsStore.shared.current.clipboardAccess = .allow
                    SettingsStore.shared.save()
                }
            }
        }
    }

    // MARK: - Links

    /// A link on screen. `cells` counts visible cells left to right, top to bottom.
    private struct LinkHit {
        let link: DetectedLink
        let isHyperlink: Bool
        let cells: Range<Int>
    }

    /// `getOptimalFrameSize` counts the scroller's width even while it's disabled.
    private var cellSize: CGSize? {
        guard let terminal = terminalView.terminal, terminal.cols > 0, terminal.rows > 0 else { return nil }
        let optimal = terminalView.getOptimalFrameSize()
        let scrollerWidth = terminalView.subviews.first { $0 is NSScroller }?.frame.width ?? 0
        return CGSize(
            width: (optimal.width - scrollerWidth) / CGFloat(terminal.cols),
            height: optimal.height / CGFloat(terminal.rows)
        )
    }

    /// ⌘-click on plain text. OSC 8 hyperlinks are left to SwiftTerm, which opens them
    /// through `TerminalEventProxy`.
    func openLink(atWindowPoint windowPoint: NSPoint) {
        guard let hit = linkHit(atWindowPoint: windowPoint), !hit.isHyperlink else { return }
        LinkOpener.open(hit.link, workingDirectory: currentDirectory)
    }

    func updateLinkHighlight(atWindowPoint point: NSPoint?) {
        guard let linkHighlight else { return }
        guard let point, let hit = linkHit(atWindowPoint: point), let cell = cellSize,
              let columns = terminalView.terminal?.cols else {
            linkHighlight.clear()
            return
        }
        var rects: [NSRect] = []
        var index = hit.cells.lowerBound
        while index < hit.cells.upperBound {
            let column = index % columns
            let count = min(columns - column, hit.cells.upperBound - index)
            rects.append(NSRect(
                x: CGFloat(column) * cell.width,
                y: CGFloat(index / columns + 1) * cell.height - 1.5,
                width: CGFloat(count) * cell.width,
                height: 1
            ))
            index += count
        }
        linkHighlight.show(rects, color: greeterMatchedAccent.map(Self.nsColor) ?? settings.textColor.nsColor)
    }

    /// Output can move the text under a pointer that isn't moving.
    private func refreshLinkHighlight() {
        guard linkHighlight?.isShowing == true, let window = view.window else { return }
        let held = NSEvent.modifierFlags.contains(.command)
        updateLinkHighlight(atWindowPoint: held ? window.mouseLocationOutsideOfEventStream : nil)
    }

    /// The link at a window point, if clicking it would open something.
    private func linkHit(atWindowPoint windowPoint: NSPoint) -> LinkHit? {
        guard let terminal = terminalView.terminal, let cell = cellSize else { return nil }
        let point = terminalView.convert(windowPoint, from: nil)
        guard terminalView.bounds.contains(point) else { return nil }
        let column = Int(point.x / cell.width)
        let row = Int((terminalView.bounds.height - point.y) / cell.height)
        guard let line = terminal.getLine(row: row), column < terminal.cols else { return nil }

        if let hovered = terminal.getCharData(col: column, row: row)?.getPayload() as? String {
            guard let url = LinkDetector.hyperlinkURL(payload: hovered), LinkPolicy.allowsURL(url) else { return nil }
            let columns = terminal.cols
            func payload(atCell index: Int) -> String? {
                terminal.getCharData(col: index % columns, row: index / columns)?.getPayload() as? String
            }
            let hoveredCell = row * columns + column
            var start = hoveredCell
            while start > 0, payload(atCell: start - 1) == hovered { start -= 1 }
            var end = hoveredCell + 1
            while end < columns * terminal.rows, payload(atCell: end) == hovered { end += 1 }
            return LinkHit(link: .url(url), isHyperlink: true, cells: start..<end)
        }

        // A long link wraps across rows: a row filled to the last column continues below.
        // Cells a program skipped with cursor moves hold NUL, which must read as a gap.
        func rowText(_ line: BufferLine?, trimRight: Bool) -> String {
            line?.translateToString(trimRight: trimRight) { cell in
                let character = cell.getCharacter()
                return character == "\0" ? " " : character
            } ?? ""
        }
        func isFull(_ row: Int) -> Bool {
            rowText(terminal.getLine(row: row), trimRight: true).count == terminal.cols
        }
        var firstRow = row
        while firstRow > 0, isFull(firstRow - 1) { firstRow -= 1 }
        var lastRow = row
        while lastRow < terminal.rows - 1, isFull(lastRow) { lastRow += 1 }
        var text = ""
        for current in firstRow...lastRow {
            text += rowText(current == row ? line : terminal.getLine(row: current), trimRight: current == lastRow)
        }
        let offset = (row - firstRow) * terminal.cols + column
        guard let match = LinkDetector.match(in: text, atOffset: offset),
              LinkPolicy.canOpen(match.link, workingDirectory: currentDirectory) else { return nil }
        let firstCell = firstRow * terminal.cols
        return LinkHit(
            link: match.link, isHyperlink: false,
            cells: (firstCell + match.range.lowerBound)..<(firstCell + match.range.upperBound)
        )
    }

    // MARK: - Find

    @objc func showFindBar(_ sender: Any?) {
        if findBar == nil {
            let bar = FindBarView(frame: .zero)
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.onSearch = { [weak self] query, backwards in self?.search(query, backwards: backwards) }
            bar.onClose = { [weak self] in self?.closeFindBar() }
            view.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: terminalView.topAnchor, constant: 6),
                bar.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor, constant: -8),
                bar.heightAnchor.constraint(equalToConstant: 36),
                bar.widthAnchor.constraint(lessThanOrEqualTo: terminalView.widthAnchor, constant: -16),
            ])
            findBar = bar
        }
        view.layoutSubtreeIfNeeded()
        findBar?.focus()
    }

    @objc func findNextMatch(_ sender: Any?) {
        guard let findBar else { return showFindBar(sender) }
        search(findBar.query, backwards: false)
    }

    @objc func findPreviousMatch(_ sender: Any?) {
        guard let findBar else { return showFindBar(sender) }
        search(findBar.query, backwards: true)
    }

    private func search(_ query: String, backwards: Bool) {
        guard !query.isEmpty else {
            terminalView.clearSearch()
            findBar?.showResult(found: false)
            return
        }
        let found = backwards ? terminalView.findPrevious(query) : terminalView.findNext(query)
        findBar?.showResult(found: found)
    }

    private func closeFindBar() {
        terminalView.clearSearch()
        findBar?.isHidden = true
        findBar?.removeFromSuperview()
        findBar = nil
        focusTerminal()
    }

    // MARK: - Prompts

    /// Index of the oldest line still in the scrollback. SwiftTerm only exposes it through
    /// which rows are valid, so this walks forward from the last known value in steps that
    /// can't skip past the valid range, then narrows down to its first row.
    private func firstBufferRow() -> Int {
        let terminal: Terminal = terminalView.terminal
        if terminal.getScrollInvariantLine(row: 0) != nil {
            knownFirstRow = 0
            return 0
        }
        if terminal.getScrollInvariantLine(row: knownFirstRow) != nil,
           terminal.getScrollInvariantLine(row: knownFirstRow - 1) == nil {
            return knownFirstRow
        }
        let step = max(terminal.rows, 1)
        var low = knownFirstRow
        var high = knownFirstRow + 1
        var steps = 0
        while terminal.getScrollInvariantLine(row: high) == nil, steps < 1_000_000 {
            low = high
            high += step
            steps += 1
        }
        while high - low > 1 {
            let middle = (low + high) / 2
            if terminal.getScrollInvariantLine(row: middle) != nil {
                high = middle
            } else {
                low = middle
            }
        }
        knownFirstRow = high
        return high
    }

    private func recordPrompt() {
        let terminal: Terminal = terminalView.terminal
        guard !terminal.isCurrentBufferAlternate else { return }
        // Rows are only known relative to the view, which must be at the live screen.
        guard !terminalView.canScroll || terminalView.scrollPosition >= 1 else { return }
        let first = firstBufferRow()
        promptMarks.prune(below: first)
        promptMarks.add(first + terminal.getTopVisibleRow() + terminal.getCursorLocation().y)
    }

    private func scrollToAbsoluteRow(_ row: Int) {
        let target = row - firstBufferRow()
        let delta = target - terminalView.terminal.getTopVisibleRow()
        if delta < 0 {
            terminalView.scrollUp(lines: -delta)
        } else if delta > 0 {
            terminalView.scrollDown(lines: delta)
        }
    }

    @objc func jumpToPreviousPrompt(_ sender: Any?) {
        guard !terminalView.terminal.isCurrentBufferAlternate else { return }
        let top = firstBufferRow() + terminalView.terminal.getTopVisibleRow()
        if let row = promptMarks.previous(before: top) {
            scrollToAbsoluteRow(row)
        }
    }

    @objc func jumpToNextPrompt(_ sender: Any?) {
        guard !terminalView.terminal.isCurrentBufferAlternate else { return }
        let top = firstBufferRow() + terminalView.terminal.getTopVisibleRow()
        if let row = promptMarks.next(after: top) {
            scrollToAbsoluteRow(row)
        } else {
            terminalView.scroll(toPosition: 1.0)
        }
    }

    // MARK: - View commands

    /// Clears the screen and history. Left alone while a full-screen program is drawing.
    @objc func clearTerminal(_ sender: Any?) {
        guard !terminalView.terminal.isCurrentBufferAlternate else { return }
        terminalView.feed(text: "\u{1B}[H\u{1B}[2J\u{1B}[3J")
        promptMarks.clear()
        knownFirstRow = 0
        if busyProcessName == nil {
            terminalView.send([0x0C]) // Ctrl-L: the shell redraws its prompt.
        }
    }

    @objc func increaseFontSize(_ sender: Any?) { changeFontOffset(by: 1) }
    @objc func decreaseFontSize(_ sender: Any?) { changeFontOffset(by: -1) }

    @objc func resetFontSize(_ sender: Any?) {
        fontOffset = 0
        applyFont()
    }

    private func changeFontOffset(by delta: Double) {
        let range = TerminalSettings.fontSizeRange
        let size = min(max(settings.fontSize + fontOffset + delta, range.lowerBound), range.upperBound)
        fontOffset = size - settings.fontSize
        applyFont()
    }

    private func applyFont() {
        let range = TerminalSettings.fontSizeRange
        let size = CGFloat(min(max(settings.fontSize + fontOffset, range.lowerBound), range.upperBound))
        terminalView.font = NSFont(name: settings.fontName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: - Colors

    /// The sprite's color, while the terminal is set to match the greeter.
    private var greeterMatchedAccent: SpriteColor? {
        settings.matchGreeterColors ? greeterAccent : nil
    }

    /// Color of the unread ring: the user's choice, then the greeter's, then blue.
    var ringColor: NSColor {
        settings.ringColor?.nsColor ?? greeterMatchedAccent.map(Self.nsColor) ?? .systemBlue
    }

    private static func nsColor(_ color: SpriteColor) -> NSColor {
        NSColor(
            srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255, alpha: 1
        )
    }

    /// Applies the color settings. Matching the greeter sets the palette and cursor but not
    /// the text color, which has to stay readable on the glass.
    private func applyColors() {
        let accent = greeterMatchedAccent
        terminalView.nativeForegroundColor = settings.textColor.nsColor
        terminalView.caretColor = accent.map(Self.nsColor) ?? settings.cursorColor.nsColor
        scrollIndicator?.color = settings.textColor.nsColor

        if settings.backgroundColorEnabled {
            backgroundOverlay.layer?.backgroundColor =
                settings.backgroundColor.withAlpha(settings.opacity).nsColor.cgColor
        } else {
            backgroundOverlay.layer?.backgroundColor = NSColor.clear.cgColor
        }

        let palette = accent.map(TerminalPalette.matching(accent:))
        if palette != installedPalette,
           let colors = TerminalPalette.swiftTermColors(palette ?? TerminalPalette.standard) {
            terminalView.installColors(colors)
            installedPalette = palette
        }
        onStatusChange?()
    }



    func setupTerminal() {
        // Blur backdrop (hidden when material is "none", or when a host
        // draws its own, see `showsBackdrop`)
        backdropView = BackdropView(frame: view.bounds)
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        backdropView.cornerRadius = cornerRadius
        backdropView.maskedCorners = Self.bottomCorners
        applyBackdrop()

        view.addSubview(backdropView)

        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Background color overlay: sits on top of the blur, under the text.
        backgroundOverlay = NSView(frame: view.bounds)
        backgroundOverlay.translatesAutoresizingMaskIntoConstraints = false
        backgroundOverlay.wantsLayer = true
        backgroundOverlay.layer?.cornerRadius = cornerRadius
        backgroundOverlay.layer?.maskedCorners = Self.bottomCorners
        backgroundOverlay.layer?.masksToBounds = true
        if settings.backgroundColorEnabled {
            backgroundOverlay.layer?.backgroundColor =
                settings.backgroundColor.withAlpha(settings.opacity).nsColor.cgColor
        } else {
            backgroundOverlay.layer?.backgroundColor = NSColor.clear.cgColor
        }

        view.addSubview(backgroundOverlay)

        NSLayoutConstraint.activate([
            backgroundOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        terminalView = VidrioTerminalView(frame: view.bounds)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.processDelegate = self
        installEventProxy()
        AttentionCenter.shared.register(self)
        terminalView.terminal.registerOscHandler(code: Self.greetOSCCode) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleGreetRequest() }
        }
        registerOSCHandlers()
        terminalView.terminal.changeHistorySize(settings.scrollbackLines)
        // The built-in scroller takes columns away from the terminal;
        // `scrollIndicator` shows the position without using any space.
        terminalView.scrollerEnabled = false
        // Trackpad touches are needed to count the fingers behind a scroll.
        terminalView.allowedTouchTypes.insert(.indirect)
        // Reflow once the user pauses or lets go while dragging the window
        // edge, rather than on every intermediate frame.
        terminalView.liveResizeCoalescingInterval = 0.1
        // Let macOS compose Option-key characters (e.g. Option+4 = "~" on a
        // Spanish keyboard) instead of sending them as ESC-prefixed Meta keys.
        terminalView.optionAsMetaKey = false

        // Stylization
        terminalView.wantsLayer = true
        terminalView.layer?.backgroundColor = NSColor.clear.cgColor
        terminalView.layer?.cornerRadius = cornerRadius
        terminalView.layer?.maskedCorners = Self.bottomCorners
        terminalView.layer?.masksToBounds = true
        terminalView.nativeBackgroundColor = .clear
        terminalView.nativeForegroundColor = settings.textColor.nsColor

        // Font configuration
        if let font = NSFont(name: settings.fontName, size: CGFloat(settings.fontSize)) {
            terminalView.font = font
        } else {
            terminalView.font = NSFont.monospacedSystemFont(ofSize: CGFloat(settings.fontSize), weight: .regular)
        }

        // Cursor color
        terminalView.caretColor = settings.cursorColor.nsColor
        terminalView.dimFactor = CGFloat(settings.dimFactor)
        terminalView.trueColorOverrides = Self.grayOverrides(for: settings.secondaryTextColor)

        view.addSubview(terminalView)

        terminalTopConstraint = terminalView.topAnchor.constraint(equalTo: view.topAnchor, constant: topInset)
        terminalLeadingConstraint = terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: sideInset)
        terminalTrailingConstraint = terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -sideInset)
        terminalBottomConstraint = terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -bottomInset)
        NSLayoutConstraint.activate([
            terminalTopConstraint, terminalLeadingConstraint, terminalTrailingConstraint, terminalBottomConstraint
        ])

        scrollIndicator = ScrollIndicatorView(frame: view.bounds)
        scrollIndicator.translatesAutoresizingMaskIntoConstraints = false
        scrollIndicator.color = settings.textColor.nsColor
        terminalView.onScrolled = { [weak self] position in
            self?.updateScrollIndicator(position: position)
        }
        view.addSubview(scrollIndicator)
        NSLayoutConstraint.activate([
            scrollIndicator.topAnchor.constraint(equalTo: terminalView.topAnchor),
            scrollIndicator.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor),
            scrollIndicator.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor),
            scrollIndicator.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor)
        ])

        let highlight = LinkHighlightView(frame: view.bounds)
        highlight.translatesAutoresizingMaskIntoConstraints = false
        highlight.onMouseMoved = { [weak self] point in
            self?.updateLinkHighlight(atWindowPoint: NSEvent.modifierFlags.contains(.command) ? point : nil)
        }
        highlight.onMouseExited = { [weak self] in self?.updateLinkHighlight(atWindowPoint: nil) }
        view.addSubview(highlight)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: terminalView.topAnchor),
            highlight.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor)
        ])
        linkHighlight = highlight

        // Build shell environment (process starts in viewDidLayout after layout is finalized)
        shellExecutable = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env["VIDRIO_PANE_ID"] = paneID
        env["TERM"] = "xterm-256color"
        // SwiftTerm renders 24-bit color. Without this, apps such as Claude Code detect only
        // 256 colors and downgrade their fixed RGB grays to palette entries.
        env["COLORTERM"] = "truecolor"
        // Ensure /usr/local/bin and /opt/homebrew/bin are in PATH
        if let path = env["PATH"] {
            env["PATH"] = "\(path):/usr/local/bin:/opt/homebrew/bin"
        } else {
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        }

        // Inject UTF-8 Locale if missing to ensure proper multibyte character width handling
        if env["LANG"] == nil && env["LC_ALL"] == nil && env["LC_CTYPE"] == nil {
            let langCode = Locale.current.language.languageCode?.identifier ?? "en"
            var defaultLang = "en_US.UTF-8"
            switch langCode {
            case "es": defaultLang = "es_ES.UTF-8"
            case "fr": defaultLang = "fr_FR.UTF-8"
            case "de": defaultLang = "de_DE.UTF-8"
            case "it": defaultLang = "it_IT.UTF-8"
            case "pt": defaultLang = "pt_BR.UTF-8"
            default: defaultLang = "en_US.UTF-8"
            }
            env["LANG"] = defaultLang
        }

        // Change to user's home directory
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        FileManager.default.changeCurrentDirectoryPath(homeDir)

        // Matches sereno's old sereno_prompt(): a colored bullet + colored cwd, set once per
        // shell (not re-evaluated per directory change, same as before). VIDRIO_PROMPT is
        // applied by ZshPromptShim as the last step of shell startup, after the user's own
        // .zshrc (and any theme/framework it loads) has already set PROMPT itself.
        greeterConfig = GreeterConfigStore.load()
        greeterSprite = Self.resolveGreeterSprite(config: greeterConfig)
        // Started from inside another vidrio pane, these would carry that pane's colors.
        env["SERENO_COLOR"] = nil
        env["VIDRIO_PROMPT"] = nil
        if let spriteURL = greeterSprite {
            let color = ColorExtractor.resolvedColor(for: spriteURL, overrideHex: greeterConfig.bulletColorHex)
            greeterAccent = color
            let hex = String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
            env["SERENO_COLOR"] = hex
            env["VIDRIO_PROMPT"] = "%F{\(hex)}●%f %F{\(hex)}%/%f %F{15}"
        }
        if shellExecutable.hasSuffix("zsh"),
           let zdotdir = ZshPromptShim.zdotdirIfSafe(currentEnvironment: env) {
            env["ZDOTDIR"] = zdotdir.path
        }

        shellEnvironment = Array(env.map { "\($0.key)=\($0.value)" })
        applyColors()
    }

    /// Live-applies appearance settings to an already-open window (blur, background
    /// color/opacity, font, colors) — used when vaho pushes a theme change while this
    /// window is already up. Geometry (cols/rows) is intentionally left out: like the
    /// rest of vidrio's settings, that only takes effect for the next window opened.
    /// Claude Code hardcodes its secondary text as truecolor grays 0x999999 (version, model,
    /// effort, path, hints) and 0x888888 (borders), which can vanish into light backgrounds.
    private static func grayOverrides(for color: RGBAColor?) -> [UInt32: NSColor] {
        guard let color else { return [:] }
        return [0x999999: color.nsColor, 0x888888: color.nsColor]
    }

    func applySettings(_ newSettings: TerminalSettings) {
        let scrollbackChanged = newSettings.scrollbackLines != settings.scrollbackLines
        settings = newSettings
        applyBackdrop()
        if scrollbackChanged {
            terminalView.terminal.changeHistorySize(settings.scrollbackLines)
            updateScrollIndicator(position: terminalView.scrollPosition)
        }
        applyColors()
        applyFont()
        terminalView.dimFactor = CGFloat(settings.dimFactor)
        terminalView.trueColorOverrides = Self.grayOverrides(for: settings.secondaryTextColor)
    }

    /// Renders and feeds the sprite+sysinfo greeting straight into this window's buffer via
    /// `feed(byteArray:)` — terminal *output*, parsed by the emulator, not shell input. No
    /// shell function, no subprocess, no `.zshrc` cooperation needed (contrast the old sereno
    /// integration, which sent `sereno_greet\r` as if typed). Called once, right after the
    /// shell process starts — deliberately NOT re-called when the Greeter panel saves a new
    /// sprite, so an already-open session isn't interrupted mid-use.
    /// Skipped for a window running a one-off script (no interactive shell) or sitting in the
    /// alternate screen buffer (vim, htop, claude, ...) where injected text would land in the
    /// TUI instead of at a shell prompt.
    func refreshSerenoGreeter() {
        guard !isClosing, processStarted, scriptPath == nil,
              terminalView.terminal.isCurrentBufferAlternate == false else { return }
        guard let spriteURL = greeterSprite else { return }
        let config = greeterConfig
        let bytes = GreetingRenderer.render(spriteURL: spriteURL, displayMode: config.displayMode, shellExecutable: shellExecutable, fields: config.enabledFields, bulletColorHex: config.bulletColorHex)
        terminalView.feed(byteArray: bytes[...])
    }

    /// OSC code a shell writes (`printf '\e]7770;\a'`) to ask for the greeting again, e.g. from a
    /// `c` alias that clears the screen. Unknown OSC codes are ignored by other terminals.
    private static let greetOSCCode = 7770
    /// Byte written back to the shell once the greeting is on screen, so it can wait for it
    /// before drawing the next prompt (the greeting is fed asynchronously, after the OSC
    /// parse finishes, and would otherwise land below the prompt).
    private static let greetAckByte: UInt8 = 0x06

    private func handleGreetRequest() {
        refreshSerenoGreeter()
        // Ack even when the greeting was skipped (alternate screen, no sprite) so the
        // shell never has to sit out its timeout.
        guard !isClosing, processStarted else { return }
        terminalView.send([Self.greetAckByte])
    }

    /// The sprite the greeter should show right now: the fixed selection from
    /// `~/.config/sereno/config.json`, or a random one — same default as sereno's greet.sh.
    private static func resolveGreeterSprite(config: GreeterConfig) -> URL? {
        if let filename = config.selectedSprite {
            let url = SpriteManager.spritesDir.appendingPathComponent(filename)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: SpriteManager.spritesDir, includingPropertiesForKeys: nil)) ?? []
        let valid = Set(["gif", "png", "jpg", "jpeg", "webp"])
        return files.filter { valid.contains($0.pathExtension.lowercased()) }.randomElement()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Reflowing to a new width moves lines, so recorded prompt rows no longer hold.
            if self.lastColumnCount != 0, self.lastColumnCount != newCols {
                self.promptMarks.clear()
            }
            self.lastColumnCount = newCols
        }
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in
            guard let self, !self.isClosing else { return }
            self.paneTitle = title
            guard self.forwardsTitleToWindow, let window = self.view.window else { return }
            window.title = title
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Handle CWD update
    }

    private func updateScrollIndicator(position: Double) {
        scrollIndicator?.show(position: terminalView.canScroll && position < 1 ? position : nil)
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        print("Process terminated with exit code: \(String(describing: exitCode))")
        Task { @MainActor [weak self] in
            guard let self, !self.isClosing else { return }
            self.processExited = true
            let exit = ProcessExit(waitStatus: exitCode)
            if self.scriptPath != nil, !exit.isSuccess {
                self.showFailedScriptNotice(exit)
            } else if let onProcessExit = self.onProcessExit {
                // Hosted as a pane: let the host (e.g. GridViewController)
                // decide what to do instead of closing the whole window.
                onProcessExit()
            } else if let window = self.view.window {
                // Asks the delegate directly: `performClose` does nothing
                // while a close confirmation sheet is attached.
                _ = window.delegate?.windowShouldClose?(window)
            }
        }
    }

    /// Keeps a failed script's window open with its output and how it ended. Waits a moment
    /// because the exit can be reported before the script's last output has been read.
    private func showFailedScriptNotice(_ exit: ProcessExit) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.isClosing else { return }
            self.terminateProcessOnce()
            self.terminalView.feed(text: "\r\n\u{1B}[2m[\(exit.summary). Press ⌘W to close.]\u{1B}[0m\r\n")
        }
    }
}