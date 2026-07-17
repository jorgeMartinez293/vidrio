import Cocoa

class TransparentWindow: NSWindow {
    /// Fixed inset of the traffic-light buttons from the top and leading edges,
    /// on top of their default macOS position. Pushes the buttons clear of the
    /// content's corner radius.
    private let trafficLightInset: CGFloat = 8
    private let trafficLightButtons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    /// Container the standard buttons are re-parented into. AppKit's titlebar
    /// re-sets the buttons' frames on every layout pass, so moving the buttons
    /// directly is a losing fight (and dirtying layout from the reposition
    /// handler creates a layout/notification loop). Instead the buttons live in
    /// this container, which mirrors the titlebar's size but sits offset by the
    /// user insets: AppKit's repositioning lands relative to the container, so
    /// the offset survives every layout pass with no fighting at all.
    private let trafficLightContainer = TrafficLightContainerView()

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true

        guard let titlebar = standardWindowButton(.closeButton)?.superview else { return }

        // Titlebar coords are bottom-left origin, so moving down = -y.
        trafficLightContainer.frame = titlebar.bounds.offsetBy(dx: trafficLightInset, dy: -trafficLightInset)
        trafficLightContainer.autoresizingMask = [.width, .height]
        titlebar.addSubview(trafficLightContainer)
        adoptTrafficLights()

        // AppKit can hand the buttons back to the titlebar (e.g. around
        // fullscreen transitions); cheaply re-adopt whenever that happens.
        NotificationCenter.default.addObserver(
            self, selector: #selector(adoptTrafficLights),
            name: NSWindow.didUpdateNotification, object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Setting the title makes AppKit re-lay (or rebuild) the titlebar, yanking
    /// the buttons out of our container; the terminal sets it on every prompt
    /// change (OSC title escape, e.g. after `cd`). Re-adopt synchronously so the
    /// buttons never get drawn at their default position in between.
    override var title: String {
        get { super.title }
        set {
            super.title = newValue
            adoptTrafficLights()
        }
    }

    /// Moves any traffic-light button not already in our offset container into
    /// it. The container's bounds match the titlebar's, so the button keeps the
    /// same local frame and just inherits the container's inset. If AppKit
    /// rebuilt the titlebar (the buttons live in a view that isn't the
    /// container's parent), the container migrates there first.
    @objc private func adoptTrafficLights() {
        for type in trafficLightButtons {
            guard let button = standardWindowButton(type), button.superview !== trafficLightContainer else { continue }
            if let titlebar = button.superview, titlebar !== trafficLightContainer.superview {
                trafficLightContainer.frame = titlebar.bounds.offsetBy(dx: trafficLightInset, dy: -trafficLightInset)
                titlebar.addSubview(trafficLightContainer)
            }
            let frame = button.frame
            trafficLightContainer.addSubview(button)
            button.frame = frame
        }
    }

    override var canBecomeKey: Bool {
        return true
    }

    override var canBecomeMain: Bool {
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let locationInWindow = event.locationInWindow
            // If the double-click is in the top 50 pixels (title bar area)
            if locationInWindow.y >= self.frame.height - 50 {
                self.zoom(nil)
                return
            }
        }
        super.mouseDown(with: event)
    }
}

/// Spans the whole titlebar but only the buttons inside it are clickable;
/// everywhere else clicks fall through to the titlebar (window drag, etc.).
private final class TrafficLightContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view === self ? nil : view
    }
}
