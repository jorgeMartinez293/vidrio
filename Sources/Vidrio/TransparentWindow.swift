import Cocoa
import SwiftTerm

class TransparentWindow: NSWindow {
    /// Fired whenever first responder successfully changes (e.g. the user
    /// clicked a different terminal pane). `GridViewController` uses this to
    /// track which pane is focused — SwiftTerm's own `becomeFirstResponder`
    /// override is `public`, not `open`, so it can't be overridden from
    /// outside its module; watching it at the window level instead works
    /// for any responder.
    var onFirstResponderChange: ((NSResponder?) -> Void)?

    /// Starts a merge drag when the user ⌘-drags this window by its top
    /// strip. Set by the app delegate for windows that can be merged; nil
    /// (or a nil session) leaves ⌘-drags alone.
    var makeMergeSession: ((TransparentWindow) -> WindowMergeSession?)?

    /// Starts tearing off the pane being ⌘-dragged in `grid` once the
    /// pointer (at the given screen point) leaves this window. Set by the
    /// app delegate; nil (or a nil session) keeps panes inside the window.
    var makePaneTearOff: ((TransparentWindow, GridViewController, NSPoint) -> PaneTearOffSession?)?

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
        // A plain titlebar drag (⌘ not held at the start) is AppKit's own
        // window move, which never reaches `runMergeDrag`; watch it instead
        // so pressing ⌘ partway through still turns it into a merge.
        NotificationCenter.default.addObserver(
            self, selector: #selector(nativeMoveWillBegin),
            name: NSWindow.willMoveNotification, object: self
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

    // MARK: - ⌘-drag to merge

    /// Intercepted here rather than in `mouseDown` so the drag is ours before
    /// the titlebar starts AppKit's own window move.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, isMergeDragHandle(event) {
            if event.modifierFlags.contains(.command), let session = makeMergeSession?(self) {
                runMergeDrag(from: event, session: session)
                return
            }
            // Might become a native window move; start watching now in
            // case `willMoveNotification` comes late or not at all.
            startNativeMoveWatch()
        } else if event.type == .leftMouseDown, event.modifierFlags.contains(.command),
                  let grid = contentViewController as? GridViewController,
                  grid.canDragPane(at: event.locationInWindow) {
            runPaneDrag(from: event, grid: grid)
            return
        }
        super.sendEvent(event)
    }

    // MARK: - ⌘-drag to rearrange panes

    /// Lifts the pane under a ⌘-press once the pointer really moves, and
    /// lets the grid move it around until release. Pulled outside the
    /// window, the pane is torn off (see `PaneTearOffSession`): dropped
    /// there it moves into another window or one of its own. A ⌘-click
    /// that never moves is handed to the terminal untouched (it opens
    /// links). Escape puts the pane back.
    private func runPaneDrag(from mouseDown: NSEvent, grid: GridViewController) {
        let start = mouseDown.locationInWindow
        var dragging = false
        var cancelled = false
        var tearOff: PaneTearOffSession?

        while true {
            guard let next = nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp, .flagsChanged, .keyDown],
                until: .distantFuture, inMode: .eventTracking, dequeue: true
            ) else { continue }
            let point = next.locationInWindow
            let mouse = NSEvent.mouseLocation
            let commandHeld = next.modifierFlags.contains(.command)

            switch next.type {
            case .keyDown:
                // Swallow every key until release, but only Escape acts.
                guard next.keyCode == 53, !cancelled else { continue }
                cancelled = true
                tearOff?.cancel()
                tearOff = nil
                if dragging { grid.endPaneDrag(cancelled: true) }
            case .flagsChanged:
                // ⌘ picks whether another window takes the drop.
                tearOff?.update(at: mouse, commandHeld: commandHeld)
            case .leftMouseUp:
                if let tearOff {
                    tearOff.finish(at: mouse, commandHeld: commandHeld)
                    // Safety net: a no-op unless the tear-off couldn't run.
                    grid.endPaneDrag(cancelled: true)
                } else if dragging {
                    grid.endPaneDrag(cancelled: cancelled)
                } else if !cancelled {
                    // Replay the click: up queued first, so it follows the
                    // down however the terminal handles it.
                    NSApp.postEvent(next, atStart: true)
                    super.sendEvent(mouseDown)
                }
                return
            default:
                guard !cancelled else { continue }
                if !dragging {
                    guard hypot(point.x - start.x, point.y - start.y) > 4 else { continue }
                    guard grid.beginPaneDrag(at: start) else {
                        NSApp.postEvent(next, atStart: true)
                        super.sendEvent(mouseDown)
                        return
                    }
                    dragging = true
                }
                let outside = !frame.contains(mouse)
                if outside, tearOff == nil {
                    tearOff = makePaneTearOff?(self, grid, mouse)
                } else if !outside, let session = tearOff {
                    session.cancel()
                    tearOff = nil
                    grid.endPaneTearOff()
                }
                if let tearOff {
                    tearOff.update(at: mouse, commandHeld: commandHeld)
                } else {
                    grid.updatePaneDrag(at: point)
                }
            }
        }
    }

    /// The top strip of the window, minus anything clickable in it: the
    /// traffic lights, and terminal text (⌘-click there opens links).
    private func isMergeDragHandle(_ event: NSEvent) -> Bool {
        guard !styleMask.contains(.fullScreen),
              event.locationInWindow.y >= frame.height - titlebarHitHeight else { return false }
        var view = contentView?.superview?.hitTest(event.locationInWindow)
        while let current = view {
            if current is NSControl || current is TerminalView { return false }
            view = current.superview
        }
        return true
    }

    /// Moves the window with the pointer, by hand, so the merge session can
    /// follow the pointer (and ⌘) on every step. Releasing ⌘ mid-drag turns
    /// it back into a plain move; Escape puts the window back.
    private func runMergeDrag(from event: NSEvent, session: WindowMergeSession) {
        let startMouse = NSEvent.mouseLocation
        let startOrigin = frame.origin
        var started = false
        isRunningMergeDrag = true
        defer { isRunningMergeDrag = false }

        while true {
            guard let next = nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp, .flagsChanged, .keyDown],
                until: .distantFuture, inMode: .eventTracking, dequeue: true
            ) else { continue }
            let mouse = NSEvent.mouseLocation
            let commandHeld = next.modifierFlags.contains(.command)

            switch next.type {
            case .keyDown:
                guard next.keyCode == 53 else { continue } // Escape
                if started { session.cancel(restoringOrigin: startOrigin) }
                return
            case .leftMouseUp:
                if started { session.finish(at: mouse, commandHeld: commandHeld) }
                return
            default:
                if !started {
                    guard hypot(mouse.x - startMouse.x, mouse.y - startMouse.y) > 3 else { continue }
                    started = true
                    session.begin()
                }
                setFrameOrigin(NSPoint(
                    x: startOrigin.x + mouse.x - startMouse.x,
                    y: startOrigin.y + mouse.y - startMouse.y
                ))
                session.update(at: mouse, commandHeld: commandHeld)
            }
        }
    }

    /// Set while `runMergeDrag` moves the window itself, so its own
    /// `setFrameOrigin` calls aren't mistaken for a native move.
    private var isRunningMergeDrag = false
    /// Polls pointer, button and ⌘ during a native window move: AppKit
    /// delivers no events to the app while it drags the window.
    private var nativeMoveTimer: Timer?
    private var nativeMoveSession: WindowMergeSession?
    private var nativeMoveStartOrigin: NSPoint = .zero
    /// Whether the window has really started moving — a press in the top
    /// strip can also just be a click or a text selection, which must
    /// never turn into a merge when ⌘ is pressed.
    private var nativeMoveConfirmed = false

    @objc private func nativeMoveWillBegin() {
        guard !isRunningMergeDrag, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        startNativeMoveWatch()
        nativeMoveConfirmed = true
    }

    private func startNativeMoveWatch() {
        guard nativeMoveTimer == nil, makeMergeSession != nil else { return }
        nativeMoveStartOrigin = frame.origin
        nativeMoveConfirmed = false
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.nativeMoveTick() }
        }
        // `.common` so it keeps firing inside AppKit's event-tracking loop.
        RunLoop.main.add(timer, forMode: .common)
        nativeMoveTimer = timer
    }

    private func nativeMoveTick() {
        let mouse = NSEvent.mouseLocation
        let commandHeld = NSEvent.modifierFlags.contains(.command)
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        if frame.origin != nativeMoveStartOrigin { nativeMoveConfirmed = true }

        guard buttonDown else {
            nativeMoveSession?.finish(at: mouse, commandHeld: commandHeld)
            stopNativeMoveWatch()
            return
        }
        if nativeMoveSession == nil, commandHeld, nativeMoveConfirmed, !isRunningMergeDrag {
            nativeMoveSession = makeMergeSession?(self)
            nativeMoveSession?.begin()
        }
        nativeMoveSession?.update(at: mouse, commandHeld: commandHeld)
    }

    private func stopNativeMoveWatch() {
        nativeMoveTimer?.invalidate()
        nativeMoveTimer = nil
        nativeMoveSession = nil
        nativeMoveConfirmed = false
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
