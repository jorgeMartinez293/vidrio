import Cocoa

/// Underlines the link under the pointer while ⌘ is held, and shows the pointing hand.
/// Sits above the terminal without taking any clicks. It tracks the mouse itself because
/// SwiftTerm's mouse handlers can't be overridden from outside its module.
final class LinkHighlightView: NSView {
    /// Pointer position in window coordinates.
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?

    private var underlines: [NSRect] = []
    private var color: NSColor = .white
    private(set) var isShowing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func mouseMoved(with event: NSEvent) { onMouseMoved?(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }

    func show(_ rects: [NSRect], color: NSColor) {
        guard rects != underlines || color != self.color || !isShowing else { return }
        if !isShowing {
            NSCursor.pointingHand.push()
            isShowing = true
        }
        underlines = rects
        self.color = color
        needsDisplay = true
    }

    func clear() {
        guard isShowing else { return }
        NSCursor.pop()
        isShowing = false
        underlines = []
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        underlines.forEach { $0.fill() }
    }
}
