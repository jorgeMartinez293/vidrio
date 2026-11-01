import Cocoa

class TransparentWindow: NSWindow {
    /// Fired whenever first responder successfully changes (e.g. the user
    /// clicked a different terminal pane). `GridViewController` uses this to
    /// track which pane is focused — SwiftTerm's own `becomeFirstResponder`
    /// override is `public`, not `open`, so it can't be overridden from
    /// outside its module; watching it at the window level instead works
    /// for any responder.
    var onFirstResponderChange: ((NSResponder?) -> Void)?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let result = super.makeFirstResponder(responder)
        if result {
            onFirstResponderChange?(responder)
        }
        return result
    }

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

    /// Frame the window had right before it was last zoomed. AppKit's own
    /// "user frame" is restored by `zoom(_:)`, but dragging a zoomed window by
    /// its titlebar never triggers that, so we keep our own copy to restore
    /// the original size on drag-out (like other macOS apps do).
    private var preZoomFrame: NSRect?

    /// Height of the titlebar hit area used for double-click zoom / drag-out.
    private let titlebarHitHeight: CGFloat = 50

    override func zoom(_ sender: Any?) {
        if !isZoomed {
            preZoomFrame = frame
        }
        super.zoom(sender)
    }

    override func mouseDown(with event: NSEvent) {
        let inTitlebar = event.locationInWindow.y >= frame.height - titlebarHitHeight
        if inTitlebar {
            if event.clickCount == 2 {
                zoom(nil)
                return
            }
            if event.clickCount == 1, isZoomed, let restoreFrame = preZoomFrame {
                dragOutOfZoom(startingAt: event, restoreTo: restoreFrame)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// Tracks a titlebar drag on a zoomed window. Once the pointer moves past
    /// a small threshold the window shrinks back to its pre-zoom size with a
    /// short animation. The animation is driven by hand (instead of
    /// `setFrame(animate: true)`, which blocks) so the window keeps following
    /// the pointer while it shrinks. The grab point keeps its relative
    /// horizontal position and distance from the top edge throughout.
    private func dragOutOfZoom(startingAt event: NSEvent, restoreTo restoreFrame: NSRect) {
        let duration: TimeInterval = 0.2
        let startMouse = NSEvent.mouseLocation
        let zoomedFrame = frame
        let ratio = (startMouse.x - zoomedFrame.minX) / max(zoomedFrame.width, 1)
        let topGap = zoomedFrame.maxY - startMouse.y
        var animationStart: Date?

        func update() {
            guard let start = animationStart else { return }
            let t = min(1, Date().timeIntervalSince(start) / duration)
            let eased = 1 - pow(1 - t, 3) // ease-out cubic
            let width = zoomedFrame.width + (restoreFrame.width - zoomedFrame.width) * eased
            let height = zoomedFrame.height + (restoreFrame.height - zoomedFrame.height) * eased
            let mouse = NSEvent.mouseLocation
            let target = NSRect(
                x: mouse.x - ratio * width,
                y: mouse.y + topGap - height,
                width: width,
                height: height
            )
            if target != frame {
                setFrame(target, display: true, animate: false)
            }
        }

        while true {
            // Time out every frame so the animation advances even when the
            // pointer is still.
            let next = nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date(timeIntervalSinceNow: 1.0 / 60.0),
                inMode: .eventTracking,
                dequeue: true
            )
            if next?.type == .leftMouseUp { break }

            if animationStart == nil {
                let mouse = NSEvent.mouseLocation
                guard hypot(mouse.x - startMouse.x, mouse.y - startMouse.y) > 3 else { continue }
                animationStart = Date()
            }
            update()
        }
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
