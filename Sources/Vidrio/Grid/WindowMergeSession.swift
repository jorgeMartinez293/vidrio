import Cocoa

/// One ⌘-drag of a terminal window over the others. While the drag lasts
/// the grid window under the pointer (only while ⌘ is held) springs its
/// panes aside to open room for the incoming ones, and the dragged window
/// fades so those gaps show through. Where the pointer sits over the
/// target picks the placement: its left or right third puts the dragged
/// window's columns beside the target's, the middle fills short columns.
/// Dropping there moves every pane — live shells included — into that
/// window, and the dragged window visibly shrinks into its new slots.
@MainActor
final class WindowMergeSession {
    private let source: TransparentWindow
    private let sourceGrid: GridViewController
    /// Other windows that could take the drop, front to back.
    private let candidates: () -> [NSWindow]
    /// Hides and releases the emptied source window (see
    /// `AppDelegate.dismissWindow` for why it never goes through `close()`).
    private let dismiss: (NSWindow) -> Void

    private var target: (window: NSWindow, grid: GridViewController)?
    private var placement: GridLayout.MergePlacement = .fill
    private var cursorPushed = false

    /// Source window opacity while dragging freely, and while hovering a
    /// drop target (low enough that the gaps opening underneath read clearly).
    private let draggingAlpha: CGFloat = 0.92
    private let hoveringAlpha: CGFloat = 0.45

    init?(
        source: TransparentWindow,
        candidates: @escaping () -> [NSWindow],
        dismiss: @escaping (NSWindow) -> Void
    ) {
        guard let grid = source.contentViewController as? GridViewController,
              grid.paneCount > 0 else { return nil }
        self.source = source
        self.sourceGrid = grid
        self.candidates = candidates
        self.dismiss = dismiss
    }

    /// The pointer moved past the drag threshold.
    func begin() {
        NSCursor.closedHand.push()
        cursorPushed = true
        source.orderFront(nil)
        fadeSource(to: draggingAlpha, duration: 0.15)
    }

    func update(at mouse: NSPoint, commandHeld: Bool) {
        let newTarget = commandHeld ? dropTarget(at: mouse) : nil
        let newPlacement = newTarget.map { Self.placement(at: mouse, over: $0.window.frame) } ?? .fill
        let targetChanged = newTarget?.window !== target?.window
        guard targetChanged || newPlacement != placement else { return }

        if targetChanged { target?.grid.hideMergePreview() }
        target = newTarget
        placement = newPlacement
        if let newTarget {
            newTarget.grid.showMergePreview(
                incomingColumnCounts: sourceGrid.columnCounts,
                focusedOffset: sourceGrid.focusedOffset,
                placement: newPlacement
            )
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if targetChanged {
            fadeSource(to: newTarget == nil ? draggingAlpha : hoveringAlpha, duration: 0.18)
        }
    }

    /// Left third of the target window: beside it on the left; right third:
    /// on the right; anywhere in between: fill its short columns.
    private static func placement(at mouse: NSPoint, over frame: NSRect) -> GridLayout.MergePlacement {
        let fraction = (mouse.x - frame.minX) / max(frame.width, 1)
        if fraction < 1.0 / 3.0 { return .left }
        if fraction > 2.0 / 3.0 { return .right }
        return .fill
    }

    /// Mouse released: merge if over a target, otherwise just leave the
    /// window where it was dropped.
    func finish(at mouse: NSPoint, commandHeld: Bool) {
        update(at: mouse, commandHeld: commandHeld)
        popCursor()
        guard let target else {
            fadeSource(to: 1, duration: 0.18)
            return
        }
        merge(into: target)
    }

    /// Escape pressed mid-drag: glide the window back to where it started.
    func cancel(restoringOrigin origin: NSPoint) {
        target?.grid.hideMergePreview()
        target = nil
        popCursor()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = GridViewController.mergeTiming
            source.animator().setFrameOrigin(origin)
            source.animator().alphaValue = 1
        }
    }

    // MARK: - Merge

    private func merge(into target: (window: NSWindow, grid: GridViewController)) {
        let snapshot = Self.snapshot(of: source)
        let sourceFrame = source.frame
        let sourceAlpha = source.alphaValue
        let title = source.title

        let detached = sourceGrid.detachAllPanes()
        source.alphaValue = 0
        dismiss(source)

        if !title.isEmpty { target.window.title = title }
        target.window.makeKeyAndOrderFront(nil)
        let landing = target.grid.adopt(
            detached.controllers,
            columnCounts: detached.columnCounts,
            focusedOffset: detached.focusedOffset,
            placement: placement
        )
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)

        guard let snapshot, !landing.isEmpty else { return }
        let ghost = MergeGhostWindow(image: snapshot, frame: sourceFrame)
        ghost.alphaValue = sourceAlpha
        ghost.orderFront(nil)
        let destination = target.window.convertToScreen(landing)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = GridViewController.mergeDuration
            context.timingFunction = GridViewController.mergeTiming
            ghost.animator().setFrame(destination, display: true)
            ghost.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { ghost.orderOut(nil) }
        }
    }

    // MARK: - Helpers

    private func dropTarget(at mouse: NSPoint) -> (window: NSWindow, grid: GridViewController)? {
        for window in candidates() where window !== source {
            guard window.isVisible, !window.isMiniaturized,
                  window.frame.contains(mouse),
                  let grid = window.contentViewController as? GridViewController,
                  grid.paneCount > 0 else { continue }
            return (window, grid)
        }
        return nil
    }

    private func fadeSource(to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            source.animator().alphaValue = alpha
        }
    }

    private func popCursor() {
        guard cursorPushed else { return }
        cursorPushed = false
        NSCursor.pop()
    }

    /// What the window's content currently draws. Blur backdrops render
    /// empty here, which is fine: the ghost brings its own blur.
    private static func snapshot(of window: NSWindow) -> NSImage? {
        guard let view = window.contentView, view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Borderless, click-through stand-in for a window being merged: a
/// frosted card showing the window's last frame, which the merge animation
/// shrinks into the slots its panes now occupy while fading it out.
private final class MergeGhostWindow: NSWindow {
    init(image: NSImage, frame: NSRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        level = .floating

        let backdrop = BackdropView(frame: NSRect(origin: .zero, size: frame.size))
        backdrop.cornerRadius = 16
        backdrop.autoresizingMask = [.width, .height]

        let imageView = NSImageView(frame: backdrop.bounds)
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        backdrop.addSubview(imageView)

        contentView = backdrop
    }
}
