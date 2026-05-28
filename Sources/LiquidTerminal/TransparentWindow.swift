import Cocoa

class TransparentWindow: NSWindow {
    /// The content corner radius this window was built with. Used to push the
    /// traffic-light buttons clear of a large rounded corner.
    private let cornerRadius: CGFloat
    /// Below this radius the default macOS button position is left untouched
    /// (matches the original look at the default radius). Above it, buttons
    /// shift inward proportionally so the corner arc no longer overlaps them.
    private static let radiusThreshold: CGFloat = 16
    /// How much of each extra point of radius translates into button inset.
    private static let radiusFactor: CGFloat = 0.7
    private let trafficLightButtons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    /// System default frames captured once, so repeated repositioning never
    /// accumulates the offset.
    private var defaultButtonFrames: [NSWindow.ButtonType: NSRect] = [:]

    init(contentRect: NSRect, cornerRadius: CGFloat = 0) {
        self.cornerRadius = cornerRadius
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

        // Reposition after the initial titlebar layout has assigned default
        // button frames, and again on resize in case AppKit relays them.
        DispatchQueue.main.async { [weak self] in self?.repositionTrafficLights() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(repositionTrafficLights),
            name: NSWindow.didResizeNotification, object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Shifts the close/minimize/zoom buttons down and to the right so a large
    /// content corner radius doesn't curve into them. No-op for small radii.
    @objc private func repositionTrafficLights() {
        let offset = max(0, (cornerRadius - Self.radiusThreshold) * Self.radiusFactor)
        for type in trafficLightButtons {
            guard let button = standardWindowButton(type) else { continue }
            // Capture the untouched default frame the first time we see it.
            let base = defaultButtonFrames[type] ?? button.frame
            if defaultButtonFrames[type] == nil { defaultButtonFrames[type] = base }
            // Titlebar coords are bottom-left origin, so moving down = -y.
            button.setFrameOrigin(NSPoint(x: base.origin.x + offset, y: base.origin.y - offset))
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
