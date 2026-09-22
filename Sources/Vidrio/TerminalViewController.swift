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
fileprivate class VidrioTerminalView: LocalProcessTerminalView {

    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        // Ensure the view is scrolled to the bottom of the new buffer after
        // any buffer switch so current content is always visible.
        scroll(toPosition: 1.0)
    }
}

// MARK: - TerminalViewController

class TerminalViewController: NSViewController, LocalProcessTerminalViewDelegate {

    fileprivate var terminalView: VidrioTerminalView!
    /// Solid color layer between the blur and the terminal text. Empty (clear)
    /// when `settings.backgroundColorEnabled` is false, preserving pure blur.
    private var backgroundOverlay: NSView!
    private var visualEffectView: NSVisualEffectView!
    var isClosing = false
    private var processStarted = false
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
        visualEffectView.layer?.cornerRadius = cornerRadius
        backgroundOverlay.layer?.cornerRadius = cornerRadius
        terminalView.layer?.cornerRadius = cornerRadius
        visualEffectView.layer?.maskedCorners = Self.bottomCorners
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
            // Run the supplied script directly. The script itself is expected
            // to keep the window open (e.g. with a trailing `read`).
            terminalView.startProcess(
                executable: "/bin/bash",
                args: [scriptPath],
                environment: shellEnvironment
            )
        } else {
            terminalView.startProcess(
                executable: shellExecutable,
                args: [],
                environment: shellEnvironment
            )
            refreshSerenoGreeter()
        }
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

        // Prevent any further delegate callbacks
        terminalView?.processDelegate = nil

        // Terminate the shell process
        terminalView?.terminate()
    }



    func setupTerminal() {
        // Setup Visual Effect View for Blur (hidden when material is "none")
        visualEffectView = NSVisualEffectView(frame: view.bounds)
        if let material = settings.blurMaterial.material {
            visualEffectView.material = material
            visualEffectView.isHidden = false
        } else {
            visualEffectView.isHidden = true
        }
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = cornerRadius
        visualEffectView.layer?.maskedCorners = Self.bottomCorners
        visualEffectView.layer?.masksToBounds = true

        view.addSubview(visualEffectView)

        NSLayoutConstraint.activate([
            visualEffectView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            visualEffectView.topAnchor.constraint(equalTo: view.topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
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
        terminalView.scrollerEnabled = false
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

        view.addSubview(terminalView)

        terminalTopConstraint = terminalView.topAnchor.constraint(equalTo: view.topAnchor, constant: topInset)
        terminalLeadingConstraint = terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: sideInset)
        terminalTrailingConstraint = terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -sideInset)
        terminalBottomConstraint = terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -bottomInset)
        NSLayoutConstraint.activate([
            terminalTopConstraint, terminalLeadingConstraint, terminalTrailingConstraint, terminalBottomConstraint
        ])

        // Build shell environment (process starts in viewDidLayout after layout is finalized)
        shellExecutable = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
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
        if let spriteURL = greeterSprite {
            let color = ColorExtractor.resolvedColor(for: spriteURL, overrideHex: greeterConfig.bulletColorHex)
            let hex = String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
            env["SERENO_COLOR"] = hex
            env["VIDRIO_PROMPT"] = "%F{\(hex)}●%f %F{\(hex)}%/%f %F{15}"
        }
        if shellExecutable.hasSuffix("zsh"),
           let zdotdir = ZshPromptShim.zdotdirIfSafe(currentEnvironment: env) {
            env["ZDOTDIR"] = zdotdir.path
        }

        shellEnvironment = Array(env.map { "\($0.key)=\($0.value)" })

    }

    /// Live-applies appearance settings to an already-open window (blur, background
    /// color/opacity, font, colors) — used when vaho pushes a theme change while this
    /// window is already up. Geometry (cols/rows) is intentionally left out: like the
    /// rest of vidrio's settings, that only takes effect for the next window opened.
    func applySettings(_ newSettings: TerminalSettings) {
        settings = newSettings

        if let material = settings.blurMaterial.material {
            visualEffectView.material = material
            visualEffectView.isHidden = false
        } else {
            visualEffectView.isHidden = true
        }

        if settings.backgroundColorEnabled {
            backgroundOverlay.layer?.backgroundColor =
                settings.backgroundColor.withAlpha(settings.opacity).nsColor.cgColor
        } else {
            backgroundOverlay.layer?.backgroundColor = NSColor.clear.cgColor
        }

        terminalView.nativeForegroundColor = settings.textColor.nsColor
        if let font = NSFont(name: settings.fontName, size: CGFloat(settings.fontSize)) {
            terminalView.font = font
        } else {
            terminalView.font = NSFont.monospacedSystemFont(ofSize: CGFloat(settings.fontSize), weight: .regular)
        }
        terminalView.caretColor = settings.cursorColor.nsColor
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
        // Handle resize if needed
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in
            guard let self, !self.isClosing, self.forwardsTitleToWindow,
                  let window = self.view.window else { return }
            window.title = title
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Handle CWD update
    }

    // Snap to the bottom whenever the user inadvertently scrolls up via trackpad.
    // Since scrollerEnabled = false there is no UI affordance for scrollback, so
    // any scroll position != bottom should be corrected immediately.
    nonisolated func scrolled(source: TerminalView, position: Double) {
        guard position < 1.0 else { return }
        Task { @MainActor [weak self] in
            self?.terminalView.scroll(toPosition: 1.0)
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        print("Process terminated with exit code: \(String(describing: exitCode))")
        Task { @MainActor [weak self] in
            guard let self, !self.isClosing else { return }
            if let onProcessExit = self.onProcessExit {
                // Hosted as a pane: let the host (e.g. GridViewController)
                // decide what to do instead of closing the whole window.
                onProcessExit()
            } else if let window = self.view.window {
                // Use performClose to route through windowShouldClose
                // which handles cleanup without crashing
                window.performClose(nil)
            }
        }
    }
}