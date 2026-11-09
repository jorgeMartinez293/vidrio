import Cocoa

/// Common interface for whatever a `TransparentWindow`'s `contentViewController`
/// is, so `AppDelegate` can clean up / live-reload settings without caring
/// whether the window holds a single terminal or a pane grid.
@MainActor
protocol TerminalHosting: AnyObject {
    func cleanup()
    func applySettings(_ newSettings: TerminalSettings)
}

extension TerminalViewController: TerminalHosting {}

/// Hosts any number of `TerminalViewController` panes tiled to fill the
/// window, like a tiling window manager: panes are arranged in columns
/// sized to the pane count, new panes open without moving existing ones, and
/// the focused pane's column and cell are enlarged. `⌘⇧N` adds a pane, `⌘`+arrow moves focus between panes, and `⌘W` closes the focused
/// pane (or the window itself once only one pane is left). ⌘-dragging a
/// pane lifts it out of the grid so it can move to a new row or column,
/// ⌥-dragging it so it can trade places with another (both keys can be
/// changed in the settings); either way, dropping it outside tears it off
/// into a window of its own.
class GridViewController: NSViewController, TerminalHosting {
    private struct Pane {
        let controller: TerminalViewController
        /// Clipping container the pane actually tiles into (see `relayout`).
        let cell: NSView
        /// Blur backdrop filling `cell`, behind `controller.view`. While a
        /// cell animates to a larger slot, the terminal inside is already
        /// at its final size and this is what shows around it instead of a
        /// bare gap.
        let cellBackdrop: BackdropView
        var isClosing = false
    }

    private var panes: [Pane] = []
    /// Indices into `panes`, per column (leftmost first, each top to
    /// bottom). Kept as state rather than derived from the pane count so a
    /// pane stays where it opened as others come and go.
    private var columns: [[Int]] = []
    private var focusedIndex = 0
    private var hasAddedInitialPane = false
    /// A pane torn off another window, which this grid starts with instead
    /// of spawning a fresh shell. Set before the window first appears.
    var initialPane: TerminalViewController?
    /// Applied to every pane as it's created, and live-reloaded onto all
    /// existing panes via `applySettings`.
    var settings: TerminalSettings = .defaults

    private let spacing: CGFloat = 8
    /// Landing slot shown while a pane is dragged around the grid. Always
    /// the topmost subview; panes go in below it (the dragged one is lifted
    /// above it by `zPosition`).
    private let slotPreview = SlotPreviewView()
    private let focusWeight: CGFloat = 1.7

    /// A pane lifted out of the grid by a ⌘-drag (see `beginPaneDrag`).
    private struct PaneDrag {
        let index: Int
        let cell: NSView
        /// Pointer position minus the cell's origin, so the pane stays
        /// under the spot it was grabbed by.
        let grabOffset: NSSize
        /// The lifted cell's size: its terminal's, which doesn't change
        /// until the drop.
        let size: NSSize
        /// Where it would land if dropped now; nil drops it back where it
        /// came from.
        var drop: Drop?
        /// The rearranging zone the drag started in (see
        /// `GridLayout.dropTarget`). Until the pointer first leaves it the
        /// pane stays home, so grabbing a pane near its column's side
        /// doesn't open a new column before it has even moved.
        let startTarget: GridLayout.DropTarget?
        var leftStartZone = false
        var cursorPushed = false
        /// The pointer left the window: the pane would become a window of
        /// its own if dropped now (see `beginPaneTearOff`).
        var tearingOff = false
    }

    /// Where a lifted pane lands: trading places with another pane (while
    /// the swap key is held), or in a new row or column of the grid.
    private enum Drop: Equatable {
        case swap(Int)
        case place(GridLayout.DropTarget)
    }

    private var paneDrag: PaneDrag?
    /// Set while another window is merge-dragged over this one and the
    /// grid shows where its panes would go.
    private var isPreviewingMerge = false
    /// Moves cells by hand while a pane is dragged and as everything
    /// settles after the drop, so slots can change mid-flight.
    private lazy var springs = FrameSpringAnimator(host: view)
    /// Drop shadow under the lifted pane. A separate view because cells
    /// clip to their rounded corners, which would clip their own shadow.
    private let liftShadow = LiftShadowView()
    /// The cell `liftShadow` currently follows (the dragged one, then the
    /// dropped one while it settles).
    private weak var shadowedCell: NSView?

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        slotPreview.frame = view.bounds
        slotPreview.autoresizingMask = [.width, .height]
        view.addSubview(slotPreview)
        liftShadow.isHidden = true
        view.addSubview(liftShadow)
        self.view = view
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let window = view.window as? TransparentWindow {
            window.onFirstResponderChange = { [weak self] responder in
                self?.handleFirstResponderChange(responder)
            }
        }
        // Deferred from viewDidLoad so the first pane's PTY is sized against
        // the window's real, final frame rather than the placeholder one
        // above.
        guard !hasAddedInitialPane else { return }
        hasAddedInitialPane = true
        if let pane = initialPane {
            initialPane = nil
            adopt(pane, placement: .fill)
        } else {
            addPane()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        relayout()
    }

    // MARK: - Pane lifecycle

    @discardableResult
    private func addPane() -> TerminalViewController {
        let controller = TerminalViewController()
        controller.settings = settings
        attach(controller)
        focusedIndex = panes.count - 1
        applyChrome()

        // Chrome (corner radius/insets) is set before controller.view is ever
        // touched, so setupTerminal() builds its layers/constraints with the
        // right values the first time instead of via a redundant live-patch.
        let cell = panes[panes.count - 1].cell
        cell.addSubview(controller.view)
        addChild(controller)
        view.addSubview(cell, positioned: .below, relativeTo: slotPreview)
        relayout(animated: true)
        return controller
    }

    /// Wraps `controller` in a new cell and appends it to the grid's
    /// bookkeeping — placed in `columns` too, unless the caller places it
    /// itself. Doesn't touch `controller.view` or the view hierarchy.
    private func attach(_ controller: TerminalViewController, placingInColumns: Bool = true) {
        controller.onProcessExit = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.closePane(controller)
        }

        // Each pane tiles as `cell`, which animates into its grid slot.
        // `controller.view` sits inside it and is sized straight to the
        // slot's final size (see `relayout`), so the terminal's grid always
        // matches the space it is shown in. `cellBackdrop` fills whatever
        // part of the cell the terminal doesn't cover mid-animation.
        let cell = NSView()
        cell.wantsLayer = true
        cell.layer?.masksToBounds = true

        // The cell's backdrop is the pane's only blur; the terminal's own
        // would stack a second one on top of it.
        controller.showsBackdrop = false
        let cellBackdrop = BackdropView()
        cell.addSubview(cellBackdrop)

        panes.append(Pane(controller: controller, cell: cell, cellBackdrop: cellBackdrop))
        if placingInColumns {
            columns = GridLayout.appending(panes.count - 1, to: columns)
        }
    }

    // MARK: - Merging windows

    /// Number of live panes — what a merge would carry over.
    var paneCount: Int { panes.count }

    /// How many panes each column holds, leftmost first — the shape a
    /// merge keeps when it places this grid beside another.
    var columnCounts: [Int] { columns.map(\.count) }

    /// Where the focused pane falls in reading order — the order
    /// `detachAllPanes` hands panes over in.
    var focusedOffset: Int { columns.flatMap { $0 }.firstIndex(of: focusedIndex) ?? 0 }

    /// Takes every pane out of this grid, live shells included, in reading
    /// order (column by column, each top to bottom) so they keep their
    /// relative placement in the grid that adopts them. Nothing is torn
    /// down: the caller hands the controllers straight to `adopt`, and this
    /// grid is left empty for its window to be dismissed.
    func detachAllPanes() -> (
        controllers: [TerminalViewController], columnCounts: [Int], focusedOffset: Int
    ) {
        endPaneDrag(cancelled: true)
        let order = columns.flatMap { $0 }
        let controllers = order.map { panes[$0].controller }
        let columnCounts = self.columnCounts
        let focusedOffset = self.focusedOffset
        for controller in controllers {
            controller.onProcessExit = nil
            controller.removeFromParent()
        }
        panes.removeAll()
        columns.removeAll()
        focusedIndex = 0
        return (controllers, columnCounts, focusedOffset)
    }

    /// Takes in panes detached from another grid (in reading order, its
    /// columns holding `columnCounts` panes each) and tiles them per
    /// `placement`. The newcomers fade and scale into their final slots
    /// while the existing panes spring over to make room. Returns the
    /// newcomers' slots in window coordinates, the spot the merge animation
    /// shrinks the source window into.
    @discardableResult
    func adopt(
        _ controllers: [TerminalViewController],
        columnCounts: [Int],
        focusedOffset: Int,
        placement: GridLayout.MergePlacement
    ) -> NSRect {
        guard !controllers.isEmpty else { return .zero }
        endPaneDrag(cancelled: true)
        isPreviewingMerge = false
        slotPreview.hide(animated: true)
        let first = panes.count
        for controller in controllers {
            attach(controller, placingInColumns: false)
        }
        columns = GridLayout.merging(
            incomingColumnCounts: Self.validated(columnCounts, total: controllers.count),
            startingAt: first, into: columns, placement: placement
        )
        focusedIndex = first + min(max(focusedOffset, 0), controllers.count - 1)
        applyChrome()

        let frames = targetFrames()
        let sizes = terminalSizes(for: frames)
        for idx in first..<panes.count {
            let pane = panes[idx]
            pane.cell.frame = frames[idx]
            pane.cellBackdrop.frame = NSRect(origin: .zero, size: frames[idx].size)
            pane.controller.view.frame = NSRect(origin: .zero, size: sizes[idx])
            pane.cell.alphaValue = 0
            // `addSubview` moves the terminal out of the old window's
            // hierarchy without tearing anything down — the shell keeps
            // running and only sees one SIGWINCH for its new size.
            pane.cell.addSubview(pane.controller.view)
            addChild(pane.controller)
            view.addSubview(pane.cell, positioned: .below, relativeTo: slotPreview)
        }

        // The panes already here are usually mid-spring from the hover
        // preview, which left room exactly where the newcomers land; they
        // carry on from there and take their final terminal size now.
        for idx in 0..<first {
            let pane = panes[idx]
            setTerminalSize(of: pane, to: sizes[idx])
            springs.animate(pane.cell, to: frames[idx], apply: springApply(for: pane))
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.mergeDuration
            context.timingFunction = Self.mergeTiming
            for idx in first..<panes.count {
                panes[idx].cell.animator().alphaValue = 1
                Self.addScaleIn(to: panes[idx].cell, from: 0.9)
            }
        }
        focusFocusedPane()

        let landing = frames[first..<panes.count].reduce(NSRect.null) { $0.union($1) }
        return view.convert(landing, to: nil)
    }

    /// Takes in a single pane torn off another grid (see `adopt`).
    @discardableResult
    func adopt(_ pane: TerminalViewController, placement: GridLayout.MergePlacement) -> NSRect {
        adopt([pane], columnCounts: [1], focusedOffset: 0, placement: placement)
    }

    /// Where a single pane coming from another window (torn off it, or the
    /// window's only pane) lands with the pointer at `screenPoint`: the same
    /// rows and columns a pane dragged within this grid can go to.
    func placementForIncomingPane(atScreenPoint screenPoint: NSPoint) -> GridLayout.MergePlacement {
        guard let window = view.window else { return .fill }
        let point = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return GridLayout.dropTarget(at: point, in: currentLayout()).map { .at($0) } ?? .fill
    }

    /// Marks this grid as the drop target of a merge drag carrying another
    /// grid's panes (its columns holding `incomingColumnCounts` each): the
    /// panes already here spring aside into the slots they'd have after
    /// the merge, and a thin border outlines each gap a newcomer will fill.
    /// Terminals keep their size meanwhile (the cells just clip or reveal
    /// them), so shells aren't resized back and forth while the pointer
    /// comes and goes; that happens once, on drop. Call again whenever the
    /// placement changes.
    func showMergePreview(
        incomingColumnCounts: [Int], focusedOffset: Int, placement: GridLayout.MergePlacement
    ) {
        let incomingCount = incomingColumnCounts.reduce(0, +)
        guard incomingCount > 0, !panes.isEmpty, paneDrag == nil else { return }
        isPreviewingMerge = true
        let first = panes.count
        let layout = GridLayout.compute(
            columns: GridLayout.merging(
                incomingColumnCounts: incomingColumnCounts, startingAt: first,
                into: columns, placement: placement
            ),
            focusedIndex: first + min(max(focusedOffset, 0), incomingCount - 1),
            bounds: view.bounds, spacing: spacing, focusWeight: focusWeight
        )
        let slots = layout.frames.map {
            view.backingAlignedRect($0, options: .alignAllEdgesNearest)
        }
        for (idx, pane) in panes.enumerated() {
            springs.animate(pane.cell, to: slots[idx], apply: springApply(for: pane))
        }
        slotPreview.show(slots: Array(slots[first...]))
    }

    /// The merge drag left (or was cancelled): spring every pane back home.
    func hideMergePreview() {
        guard isPreviewingMerge else { return }
        isPreviewingMerge = false
        slotPreview.hide(animated: true)
        let frames = targetFrames()
        let sizes = terminalSizes(for: frames)
        for (idx, pane) in panes.enumerated() {
            // Normally a no-op: terminals never left their size. Catches a
            // pane closing mid-hover, which skipped the regular relayout.
            setTerminalSize(of: pane, to: sizes[idx])
            springs.animate(pane.cell, to: frames[idx], apply: springApply(for: pane))
        }
    }

    /// `counts` if it describes exactly `total` panes, otherwise a single
    /// column of them — so a mismatched shape can never drop a pane.
    private static func validated(_ counts: [Int], total: Int) -> [Int] {
        counts.allSatisfy({ $0 > 0 }) && counts.reduce(0, +) == total ? counts : [total]
    }

    /// Pacing for the merge's eased parts (newcomers fading in, the source
    /// window shrinking into place), timed to land with the panes' springs.
    static let mergeDuration: TimeInterval = 0.34
    static let mergeTiming = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)

    /// Visual-only scale-up from `scale` to full size about the view's
    /// center. AppKit's layers are anchored bottom-left, so the transform is
    /// built around the center by hand; the model value stays identity.
    static func addScaleIn(to view: NSView, from scale: CGFloat) {
        guard let layer = view.layer else { return }
        let w = layer.bounds.width / 2, h = layer.bounds.height / 2
        var start = CATransform3DMakeTranslation(w, h, 0)
        start = CATransform3DScale(start, scale, scale, 1)
        start = CATransform3DTranslate(start, -w, -h, 0)
        let animation = CASpringAnimation(keyPath: "transform")
        animation.fromValue = start
        animation.toValue = CATransform3DIdentity
        animation.mass = 1
        animation.stiffness = 260
        animation.damping = 20
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: "mergeScaleIn")
    }

    private func handleFirstResponderChange(_ responder: NSResponder?) {
        guard let idx = panes.firstIndex(where: { $0.controller.owns(responder) }),
              idx != focusedIndex else { return }
        focusedIndex = idx
        applyChrome()
        relayout(animated: true)
    }

    private func closePane(_ controller: TerminalViewController) {
        guard let idx = panes.firstIndex(where: { $0.controller === controller }),
              !panes[idx].isClosing else { return }
        // Pane indices are about to shift under the drag; put it back first.
        endPaneDrag(cancelled: true)

        guard panes.count > 1 else {
            // Last pane left: behave like closing a normal terminal window.
            view.window?.performClose(nil)
            return
        }

        panes[idx].isClosing = true
        controller.cleanup()
        let closedCell = panes[idx].cell
        closedCell.isHidden = true
        panes.remove(at: idx)
        columns = GridLayout.removing(idx, from: columns)
        focusedIndex = min(focusedIndex, panes.count - 1)
        applyChrome()
        relayout(animated: true)
        focusFocusedPane()

        // Mirrors AppDelegate.dismissWindow: SwiftTerm's [unowned self]
        // observers make removing its view from the hierarchy unsafe while
        // any of its CA transactions might still be in flight, so the
        // actual removal is deferred.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak controller] in
            controller?.removeFromParent()
            controller?.view.removeFromSuperview()
            closedCell.removeFromSuperview()
        }
    }

    // MARK: - Actions (wired via the File menu's responder chain)

    /// Closes the focused pane, or the window itself if it's the only pane
    /// left.
    @objc func closeFocusedTerminal(_ sender: Any?) {
        guard focusedIndex < panes.count else { return }
        if panes.count == 1 {
            view.window?.performClose(nil)
        } else {
            closePane(panes[focusedIndex].controller)
        }
    }

    @objc func addGridPane(_ sender: Any?) {
        addPane()
        focusFocusedPane()
    }

    @objc func moveGridFocusUp(_ sender: Any?) { moveFocus(.up) }
    @objc func moveGridFocusDown(_ sender: Any?) { moveFocus(.down) }
    @objc func moveGridFocusLeft(_ sender: Any?) { moveFocus(.left) }
    @objc func moveGridFocusRight(_ sender: Any?) { moveFocus(.right) }

    private func moveFocus(_ direction: GridLayout.Direction) {
        guard panes.count > 1 else { return }
        let layout = GridLayout.compute(
            columns: columns, focusedIndex: focusedIndex, bounds: view.bounds,
            spacing: spacing, focusWeight: focusWeight
        )
        let newIndex = GridLayout.move(from: focusedIndex, direction: direction, layout: layout)
        guard newIndex != focusedIndex else { return }
        focusedIndex = newIndex
        applyChrome()
        relayout(animated: true)
        focusFocusedPane()
    }

    private func focusFocusedPane() {
        guard focusedIndex < panes.count else { return }
        panes[focusedIndex].controller.focusTerminal()
    }

    // MARK: - Layout

    /// Window resize skips the animation, since it already fires
    /// continuously — everything else (focus change, pane add/remove)
    /// asks for `animated: true`, so a pane's cell slides into its new
    /// slot instead of jumping there.
    private func relayout(animated: Bool = false) {
        guard !panes.isEmpty else { return }
        // A drag lays the grid out itself, as a preview; the real layout
        // only changes on the drop.
        guard paneDrag == nil, !isPreviewingMerge else { return }
        let frames = targetFrames()
        let sizes = terminalSizes(for: frames)
        let applyFrames = {
            for (idx, pane) in self.panes.enumerated() {
                let target = frames[idx]
                if self.springs.isAnimating(pane.cell) {
                    // Still settling from a drop: steer the spring to the
                    // new slot instead of fighting it frame by frame.
                    self.setTerminalSize(of: pane, to: sizes[idx])
                    self.springs.animate(pane.cell, to: target, apply: self.springApply(for: pane))
                    continue
                }
                if animated {
                    pane.cell.animator().frame = target
                    pane.cellBackdrop.animator().frame = NSRect(origin: .zero, size: target.size)
                } else {
                    pane.cell.frame = target
                    pane.cellBackdrop.frame = NSRect(origin: .zero, size: target.size)
                }
                // Every pane's terminal takes its slot's final size in a
                // single step, never animated: animating it would resize
                // the terminal through every intermediate frame, reflowing
                // its text and sending the program inside a burst of
                // SIGWINCHes it redraws for sizes that are already stale,
                // leaving mangled lines behind. The cell's clip hides the
                // difference while the cell itself animates.
                let terminalFrame = NSRect(origin: .zero, size: sizes[idx])
                if pane.controller.view.frame != terminalFrame {
                    pane.controller.view.frame = terminalFrame
                }
            }
        }
        guard animated else {
            applyFrames()
            return
        }
        // Sped up well past macOS's default 0.25s so darting between panes
        // reads as a quick slide rather than a laggy animation.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            applyFrames()
        }
    }

    /// The grid's own layout, unsnapped: what drops are hit-tested against.
    private func currentLayout() -> GridLayout.Result {
        GridLayout.compute(
            columns: columns, focusedIndex: focusedIndex,
            bounds: view.bounds, spacing: panes.count > 1 ? spacing : 0, focusWeight: focusWeight
        )
    }

    /// Every pane's final slot for `columns` (the grid's own by default)
    /// and the current focus.
    private func targetFrames(columns: [[Int]]? = nil, focusedIndex: Int? = nil) -> [NSRect] {
        // No spacing to reserve with nothing to space between — a single
        // pane fills the window edge-to-edge exactly like the original
        // single-window look, instead of sitting inset with a visible gap
        // that throws off how its 28pt corner radius reads.
        let layout = GridLayout.compute(
            columns: columns ?? self.columns, focusedIndex: focusedIndex ?? self.focusedIndex,
            bounds: view.bounds, spacing: panes.count > 1 ? spacing : 0, focusWeight: focusWeight
        )
        // Weighted slots land on fractional points; snapping them to
        // whole device pixels keeps every terminal row (and each row
        // stripe of an inline image) on exact pixel boundaries,
        // instead of blurred or seamed.
        return layout.frames.map {
            view.backingAlignedRect($0, options: .alignAllEdgesNearest)
        }
    }

    /// The terminal size for each pane in `frames` (the grid's slots for
    /// the current focus). Every pane keeps the width its slot has while
    /// it is focused, even when it isn't: otherwise each focus move would
    /// change the column count of every terminal, and programs that wrap
    /// their own text (Claude Code, for one) would leave everything above
    /// the screen wrapped at the old width. A narrower unfocused cell just
    /// clips the terminal's right side. The height follows the slot, so
    /// the bottom of the terminal, where the prompt lives, stays visible.
    private func terminalSizes(for frames: [NSRect]) -> [NSSize] {
        frames.indices.map { idx in
            let focusedWidth = idx == focusedIndex
                ? frames[idx].width
                : targetFrames(focusedIndex: idx)[idx].width
            return NSSize(width: max(frames[idx].width, focusedWidth), height: frames[idx].height)
        }
    }

    /// A single pane keeps the app's original chrome (28pt radius, 50pt top
    /// inset to clear the window's traffic lights). Once there's more than
    /// one, every pane shrinks to a tighter uniform inset. The grid isn't
    /// margined out from under the window's traffic lights — like the
    /// original single-window look, the top-left pane's card sits behind
    /// them, and its own top inset (30pt, enough to clear the button row)
    /// keeps its terminal text from running under them. Only the focused
    /// pane forwards its shell's OSC title to the window.
    private func applyChrome() {
        let single = panes.count == 1
        for (idx, pane) in panes.enumerated() {
            let radius: CGFloat = single ? 28 : 16
            let insets = single ? Self.singlePaneInsets : Self.gridPaneInsets
            pane.controller.cornerRadius = radius
            pane.controller.topInset = insets.top
            pane.controller.sideInset = insets.side
            pane.controller.bottomInset = insets.bottom
            pane.controller.forwardsTitleToWindow = idx == focusedIndex

            // `cell` itself clips `controller.view` while the cell animates
            // (see `relayout`) — without its own radius here, that clip
            // lands on a bare rectangular edge instead of matching
            // cellBackdrop's rounded corner.
            pane.cell.layer?.cornerRadius = radius

            pane.cellBackdrop.cornerRadius = radius
            pane.cellBackdrop.apply(settings.blurMaterial)
        }
    }

    private static let singlePaneInsets = (top: CGFloat(50), side: CGFloat(10), bottom: CGFloat(10))
    private static let gridPaneInsets = (top: CGFloat(30), side: CGFloat(8), bottom: CGFloat(8))

    // MARK: - Dragging panes

    /// Whether a ⌘-drag starting at `windowPoint` would lift a pane.
    func canDragPane(at windowPoint: NSPoint) -> Bool {
        paneDrag == nil && paneIndex(at: view.convert(windowPoint, from: nil)) != nil
    }

    /// Lifts the pane under `windowPoint` out of the grid: it takes focus,
    /// floats above the others with a shadow and follows the pointer, while
    /// a dashed slot marks where it will land. Returns false if there's no
    /// pane to lift there.
    @discardableResult
    func beginPaneDrag(at windowPoint: NSPoint) -> Bool {
        let point = view.convert(windowPoint, from: nil)
        guard paneDrag == nil, !isPreviewingMerge, let idx = paneIndex(at: point) else { return false }
        let pane = panes[idx]
        let start = springs.presentedFrame(of: pane.cell) ?? pane.cell.frame
        let size = pane.controller.view.frame.size
        let grabOffset = NSSize(
            width: min(max(point.x - start.minX, 0), size.width),
            height: min(max(point.y - start.minY, 0), size.height)
        )
        paneDrag = PaneDrag(
            index: idx, cell: pane.cell, grabOffset: grabOffset, size: size,
            startTarget: GridLayout.dropTarget(at: point, in: currentLayout(), moving: idx)
        )

        NSCursor.closedHand.push()
        paneDrag?.cursorPushed = true
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)

        if focusedIndex != idx {
            focusedIndex = idx
            applyChrome()
        }
        focusFocusedPane()

        // Above every other cell and above the slot preview.
        for other in panes { other.cell.layer?.zPosition = 0 }
        pane.cell.layer?.zPosition = 10
        liftShadow.layer?.zPosition = 9
        liftShadow.cornerRadius = pane.cell.layer?.cornerRadius ?? 16
        liftShadow.frame = start
        liftShadow.isHidden = false
        shadowedCell = pane.cell
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            liftShadow.animator().alphaValue = 1
        }

        springs.animate(
            pane.cell, from: start,
            to: NSRect(origin: NSPoint(x: point.x - grabOffset.width, y: point.y - grabOffset.height), size: size),
            spring: .follow, apply: springApply(for: pane)
        )
        updateDragPreview()
        return true
    }

    /// Moves the lifted pane with the pointer and picks where it would
    /// land. Normally that's a new row or column, chosen by
    /// `GridLayout.dropTarget`; with `swapping` (the swap key held), it's
    /// the slot of the pane under the pointer, which springs into the
    /// lifted pane's old slot instead. The rest of the grid springs around
    /// to match.
    func updatePaneDrag(at windowPoint: NSPoint, swapping: Bool) {
        guard let drag = paneDrag, !drag.tearingOff else { return }
        let point = view.convert(windowPoint, from: nil)
        springs.animate(
            drag.cell,
            to: NSRect(
                origin: NSPoint(x: point.x - drag.grabOffset.width, y: point.y - drag.grabOffset.height),
                size: drag.size
            ),
            spring: .follow, apply: springApply(for: panes[drag.index])
        )

        // Hit-tested against the grid's own slots, not the previewed ones:
        // the preview moves panes under the pointer, which would make the
        // pick flip back and forth as they go.
        let layout = currentLayout()
        let newDrop: Drop?
        if swapping {
            let hovered = nearestPane(to: point, in: layout.frames)
            newDrop = hovered.flatMap { $0 == drag.index ? nil : .swap($0) }
        } else {
            let target = GridLayout.dropTarget(at: point, in: layout, moving: drag.index)
            if !drag.leftStartZone, target != drag.startTarget {
                paneDrag?.leftStartZone = true
            }
            if let target, paneDrag?.leftStartZone == true,
               GridLayout.placing(drag.index, at: target, in: columns) != columns {
                newDrop = .place(target)
            } else {
                newDrop = nil
            }
        }
        guard newDrop != drag.drop else { return }
        paneDrag?.drop = newDrop
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        updateDragPreview()
    }

    /// The pane (other than a closing one) whose frame holds `point`, or
    /// the closest one when it sits in a gap.
    private func nearestPane(to point: NSPoint, in frames: [NSRect]) -> Int? {
        func distance(_ frame: NSRect) -> CGFloat {
            hypot(max(frame.minX - point.x, 0, point.x - frame.maxX),
                  max(frame.minY - point.y, 0, point.y - frame.maxY))
        }
        return frames.indices
            .filter { !panes[$0].isClosing }
            .min { distance(frames[$0]) < distance(frames[$1]) }
    }

    /// Drops the lifted pane: into its landing slot (in a new row or
    /// column, or trading places with the hovered pane), or straight back
    /// home if `cancelled`. Terminals
    /// take their final size once, here, and every cell springs into place.
    func endPaneDrag(cancelled: Bool) {
        guard let drag = paneDrag else { return }
        paneDrag = nil
        if drag.cursorPushed { NSCursor.pop() }
        slotPreview.hide(animated: true)
        if drag.tearingOff {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                drag.cell.animator().alphaValue = 1
            }
        }

        if !cancelled, let drop = drag.drop {
            columns = columns(applying: drop, moving: drag.index)
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }

        let frames = targetFrames()
        let sizes = terminalSizes(for: frames)
        for (idx, pane) in panes.enumerated() {
            setTerminalSize(of: pane, to: sizes[idx])
            let cell = pane.cell
            springs.animate(
                cell, to: frames[idx], spring: idx == drag.index ? .drop : .settle,
                apply: springApply(for: pane)
            ) { [weak self] in
                guard let self, self.paneDrag?.cell !== cell else { return }
                cell.layer?.zPosition = 0
                if self.shadowedCell === cell {
                    self.shadowedCell = nil
                    if self.paneDrag == nil { self.liftShadow.isHidden = true }
                }
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            liftShadow.animator().alphaValue = 0
        }
        focusFocusedPane()
    }

    // MARK: - Tearing panes off

    /// The lifted pane was pulled out of the window: it fades from the grid
    /// (the caller shows it floating under the pointer instead, from the
    /// returned snapshot) and the other panes spring together to close its
    /// gap, previewing the grid without it. Returns nil if no pane is lifted.
    func beginPaneTearOff() -> (image: NSImage?, size: NSSize, grabOffset: NSSize)? {
        guard var drag = paneDrag else { return nil }
        if !drag.tearingOff {
            drag.tearingOff = true
            drag.drop = nil
            paneDrag = drag
            slotPreview.hide(animated: true)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                drag.cell.animator().alphaValue = 0
                liftShadow.animator().alphaValue = 0
            }
            let frames = framesWithoutPane(drag.index)
            for (idx, pane) in panes.enumerated() where idx != drag.index {
                springs.animate(pane.cell, to: frames[idx], apply: springApply(for: pane))
            }
        }
        let snapshot = panes[drag.index].controller.view.snapshotImage()
        return (snapshot, drag.size, drag.grabOffset)
    }

    /// The torn-off pane came back over the window: it reappears under the
    /// pointer and the grid previews the drop as usual again.
    func endPaneTearOff() {
        guard var drag = paneDrag, drag.tearingOff else { return }
        drag.tearingOff = false
        paneDrag = drag
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            drag.cell.animator().alphaValue = 1
            liftShadow.animator().alphaValue = 1
        }
        updateDragPreview()
    }

    /// Dropped outside the window: takes the torn-off pane out of the grid,
    /// live shell included, and lets the rest settle into their new slots.
    /// Its view stays where it is until the caller moves it into the grid
    /// that adopts it (see `adopt`). Returns nil if no pane was torn off.
    func takeTornOffPane() -> TerminalViewController? {
        guard let drag = paneDrag, drag.tearingOff else { return nil }
        paneDrag = nil
        if drag.cursorPushed { NSCursor.pop() }
        slotPreview.hide(animated: false)
        liftShadow.isHidden = true
        shadowedCell = nil

        let pane = panes[drag.index]
        panes.remove(at: drag.index)
        columns = GridLayout.removing(drag.index, from: columns)
        focusedIndex = min(drag.index, panes.count - 1)
        applyChrome()

        pane.controller.onProcessExit = nil
        pane.controller.removeFromParent()
        pane.cell.layer?.zPosition = 0
        // Emptied once the adopting grid moves the terminal out; removed
        // later for the same reason `closePane` defers its removal.
        let cell = pane.cell
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            cell.removeFromSuperview()
        }

        let frames = targetFrames()
        let sizes = terminalSizes(for: frames)
        for (idx, other) in panes.enumerated() {
            setTerminalSize(of: other, to: sizes[idx])
            springs.animate(other.cell, to: frames[idx], spring: .settle, apply: springApply(for: other))
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        return pane.controller
    }

    /// Slots for the grid as it would be without pane `removed`, indexed
    /// like the current pane list (the removed pane's own entry is unused).
    private func framesWithoutPane(_ removed: Int) -> [NSRect] {
        let remaining = panes.count - 1
        let layout = GridLayout.compute(
            columns: GridLayout.removing(removed, from: columns),
            focusedIndex: min(removed, remaining - 1),
            bounds: view.bounds, spacing: remaining > 1 ? spacing : 0, focusWeight: focusWeight
        )
        return panes.indices.map { idx in
            if idx == removed { return .zero }
            let frame = layout.frames[idx > removed ? idx - 1 : idx]
            return view.backingAlignedRect(frame, options: .alignAllEdgesNearest)
        }
    }

    private func paneIndex(at point: NSPoint) -> Int? {
        guard panes.count > 1 else { return nil }
        return panes.indices.first { idx in
            !panes[idx].isClosing
                && (springs.presentedFrame(of: panes[idx].cell) ?? panes[idx].cell.frame).contains(point)
        }
    }

    /// Slots for the grid as it would be after dropping `drag` now.
    private func previewFrames(for drag: PaneDrag) -> [NSRect] {
        guard let drop = drag.drop else { return targetFrames() }
        return targetFrames(columns: columns(applying: drop, moving: drag.index))
    }

    /// The grid's columns after pane `index` is dropped as `drop`.
    private func columns(applying drop: Drop, moving index: Int) -> [[Int]] {
        switch drop {
        case .swap(let other):
            return GridLayout.swapping(index, other, in: columns)
        case .place(let target):
            return GridLayout.placing(index, at: target, in: columns)
        }
    }

    /// Springs every pane but the lifted one to its previewed slot and
    /// marks the landing slot. Terminals keep their size meanwhile — it
    /// only changes on the drop, so shells aren't resized back and forth
    /// while the pointer wanders.
    private func updateDragPreview() {
        guard let drag = paneDrag else { return }
        let frames = previewFrames(for: drag)
        for (idx, pane) in panes.enumerated() where idx != drag.index {
            springs.animate(pane.cell, to: frames[idx], apply: springApply(for: pane))
        }
        slotPreview.show(slots: [frames[drag.index]])
    }

    /// Lays a pane out at a spring's current frame. The terminal stays
    /// pinned to the cell's top-left corner, so when it's larger or smaller
    /// than its moving cell, the difference shows at the bottom and right
    /// rather than cutting off its first lines.
    private func springApply(for pane: Pane) -> (NSRect) -> Void {
        let cell = pane.cell
        let backdrop = pane.cellBackdrop
        let terminal = pane.controller.view
        return { [weak self] frame in
            cell.frame = frame
            backdrop.frame = NSRect(origin: .zero, size: frame.size)
            terminal.setFrameOrigin(NSPoint(x: 0, y: frame.height - terminal.frame.height))
            if let self, self.shadowedCell === cell {
                self.liftShadow.frame = frame
            }
        }
    }

    /// Resizes a pane's terminal (pinned top-left, see `springApply`)
    /// without touching its cell.
    private func setTerminalSize(of pane: Pane, to size: NSSize) {
        let cellHeight = (springs.presentedFrame(of: pane.cell) ?? pane.cell.frame).height
        let frame = NSRect(origin: NSPoint(x: 0, y: cellHeight - size.height), size: size)
        if pane.controller.view.frame != frame {
            pane.controller.view.frame = frame
        }
    }

    // MARK: - TerminalHosting

    func cleanup() {
        for pane in panes {
            pane.controller.cleanup()
        }
    }

    func applySettings(_ newSettings: TerminalSettings) {
        settings = newSettings
        for pane in panes {
            pane.controller.applySettings(newSettings)
        }
        applyChrome()
    }
}

/// Soft shadow drawn under a lifted pane. Masked to only the outside of
/// its rounded rect, so it never darkens the translucent pane above it.
private final class LiftShadowView: NSView {
    var cornerRadius: CGFloat = 16 {
        didSet { updatePaths() }
    }

    private let outsideMask = CAShapeLayer()
    private let maskBleed: CGFloat = 80

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 20
        layer?.shadowOffset = CGSize(width: 0, height: -10)
        outsideMask.fillRule = .evenOdd
        layer?.mask = outsideMask
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePaths()
    }

    private func updatePaths() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let shape = CGPath(
            roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
        )
        layer?.shadowPath = shape
        let mask = CGMutablePath()
        mask.addRect(bounds.insetBy(dx: -maskBleed, dy: -maskBleed))
        mask.addPath(shape)
        outsideMask.frame = bounds
        outsideMask.path = mask
        CATransaction.commit()
    }
}
