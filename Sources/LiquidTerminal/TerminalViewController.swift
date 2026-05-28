import Cocoa
import SwiftTerm

// MARK: - LiquidTerminalView

/// Subclass of LocalProcessTerminalView that fixes a display issue when running
/// full-screen TUI apps (claude, vim, htop, etc.):
///
/// When the alternate screen buffer is activated/deactivated (e.g. entering or
/// exiting vim), `bufferActivated()` snaps the view to the correct scroll
/// position. Without this a stale `yDisp` can leave the view showing the wrong
/// portion of the buffer.
fileprivate class LiquidTerminalView: LocalProcessTerminalView {

    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        // Ensure the view is scrolled to the bottom of the new buffer after
        // any buffer switch so current content is always visible.
        scroll(toPosition: 1.0)
    }
}

// MARK: - TerminalViewController

class TerminalViewController: NSViewController, LocalProcessTerminalViewDelegate {

    fileprivate var terminalView: LiquidTerminalView!
    /// Solid color layer between the blur and the terminal text. Empty (clear)
    /// when `settings.backgroundColorEnabled` is false, preserving pure blur.
    private var backgroundOverlay: NSView!
    var isClosing = false
    private var processStarted = false
    private var shellExecutable: String = "/bin/zsh"
    private var shellEnvironment: [String] = []
    /// If set, the terminal launches `/bin/bash <scriptPath>` instead of an
    /// interactive shell. Used when LiquidTerminal is opened with a file
    /// (Launch Services `application(_:openFiles:)`).
    var scriptPath: String?
    /// Appearance/launch settings applied at setup. Injected by AppDelegate
    /// before the view loads; defaults reproduce the original hardcoded look.
    var settings: TerminalSettings = .defaults

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
        let radius = CGFloat(settings.cornerRadius)

        // Setup Visual Effect View for Blur (hidden when material is "none")
        let visualEffectView = NSVisualEffectView(frame: view.bounds)
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
        visualEffectView.layer?.cornerRadius = radius
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
        backgroundOverlay.layer?.cornerRadius = radius
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

        terminalView = LiquidTerminalView(frame: view.bounds)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.processDelegate = self
        terminalView.scrollerEnabled = false

        // Stylization
        terminalView.wantsLayer = true
        terminalView.layer?.backgroundColor = NSColor.clear.cgColor
        terminalView.layer?.cornerRadius = radius
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

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.topAnchor, constant: 50), // Increased top margin
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10)
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

        shellEnvironment = Array(env.map { "\($0.key)=\($0.value)" })

    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Handle resize if needed
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in
            guard let self, !self.isClosing,
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
            guard let self, !self.isClosing,
                  let window = self.view.window else { return }
            // Use performClose to route through windowShouldClose
            // which handles cleanup without crashing
            window.performClose(nil)
        }
    }
}