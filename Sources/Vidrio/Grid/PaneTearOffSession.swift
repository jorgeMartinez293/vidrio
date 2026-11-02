import Cocoa

/// A pane ⌘-dragged out of its window. While the pointer stays outside,
/// the pane floats under it as a frosted ghost and the grid it came from
/// closes the gap. Over another grid window (only while ⌘ is held) that
/// window springs its panes aside to preview where the pane would land,
/// exactly like a window merge: its left or right third adds the pane as a
/// new column on that side, the middle fills a short column. Dropping there
/// moves the pane, live shell included, into that window; dropping anywhere
/// else opens it in a window of its own.
@MainActor
final class PaneTearOffSession {
    private let sourceWindow: NSWindow
    private let sourceGrid: GridViewController
    /// Other windows that could take the drop, front to back.
    private let candidates: () -> [NSWindow]
    /// Opens a new window around a pane dropped where no window takes it,
    /// given the frame (screen coordinates) it was dropped at, and returns
    /// the new window's frame.
    private let openWindow: (TerminalViewController, NSRect) -> NSRect

    private let ghost: MergeGhostWindow
    /// Pointer position minus the ghost's origin, so the pane stays under
    /// the spot it was grabbed by.
    private let grabOffset: NSSize
    private var target: (window: NSWindow, grid: GridViewController)?
    private var placement: GridLayout.MergePlacement = .fill

    /// Ghost opacity while dragging freely, and while hovering a drop target
    /// (low enough that the gap opening underneath reads clearly).
    private let draggingAlpha: CGFloat = 0.92
    private let hoveringAlpha: CGFloat = 0.45

    /// Tears the pane lifted in `sourceGrid` off its grid and shows its
    /// ghost at `mouse`. Nil if no pane is being dragged.
    init?(
        sourceWindow: NSWindow,
        sourceGrid: GridViewController,
        at mouse: NSPoint,
        candidates: @escaping () -> [NSWindow],
        openWindow: @escaping (TerminalViewController, NSRect) -> NSRect
    ) {
        guard let info = sourceGrid.beginPaneTearOff() else { return nil }
        self.sourceWindow = sourceWindow
        self.sourceGrid = sourceGrid
        self.candidates = candidates
        self.openWindow = openWindow
        self.grabOffset = info.grabOffset
        ghost = MergeGhostWindow(image: info.image, frame: NSRect(
            origin: NSPoint(x: mouse.x - info.grabOffset.width, y: mouse.y - info.grabOffset.height),
            size: info.size
        ))
        ghost.alphaValue = 0
        ghost.orderFront(nil)
        fadeGhost(to: draggingAlpha, duration: 0.15)
    }

    func update(at mouse: NSPoint, commandHeld: Bool) {
        ghost.setFrameOrigin(NSPoint(x: mouse.x - grabOffset.width, y: mouse.y - grabOffset.height))

        let newTarget = commandHeld
            ? WindowMergeSession.dropTarget(at: mouse, among: candidates(), excluding: sourceWindow)
            : nil
        let newPlacement = newTarget.map {
            WindowMergeSession.placement(at: mouse, over: $0.window.frame)
        } ?? .fill
        let targetChanged = newTarget?.window !== target?.window
        guard targetChanged || newPlacement != placement else { return }

        if targetChanged { target?.grid.hideMergePreview() }
        target = newTarget
        placement = newPlacement
        if let newTarget {
            newTarget.grid.showMergePreview(incomingColumnCounts: [1], focusedOffset: 0, placement: newPlacement)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if targetChanged {
            fadeGhost(to: newTarget == nil ? draggingAlpha : hoveringAlpha, duration: 0.18)
        }
    }

    /// The pointer came back over the source window, or Escape was
    /// pressed: drop the ghost and any target preview. The caller puts the
    /// pane back into its own grid's drag.
    func cancel() {
        target?.grid.hideMergePreview()
        target = nil
        let ghost = ghost
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ghost.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { ghost.orderOut(nil) }
        }
    }

    /// Mouse released outside the source window: the pane moves into the
    /// window under the pointer, or into a new one if there's none.
    func finish(at mouse: NSPoint, commandHeld: Bool) {
        update(at: mouse, commandHeld: commandHeld)
        // Nil if the pane's shell exited mid-drag.
        guard let pane = sourceGrid.takeTornOffPane() else {
            cancel()
            return
        }

        let destination: NSRect
        if let target {
            target.window.makeKeyAndOrderFront(nil)
            let landing = target.grid.adopt(pane, placement: placement)
            destination = target.window.convertToScreen(landing)
        } else {
            destination = openWindow(pane, ghost.frame)
        }
        target = nil

        // Grow or shrink the ghost into the pane's new place while fading it.
        let ghost = ghost
        ghost.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = GridViewController.mergeDuration
            context.timingFunction = GridViewController.mergeTiming
            ghost.animator().setFrame(destination, display: true)
            ghost.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { ghost.orderOut(nil) }
        }
    }

    private func fadeGhost(to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ghost.animator().alphaValue = alpha
        }
    }
}
