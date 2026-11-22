import Cocoa

/// Thin overlay thumb shown only while a terminal is scrolled back through its history. It
/// takes no layout space, so terminal columns never change, and it ignores the mouse.
final class ScrollIndicatorView: NSView {
    private static let thumbWidth: CGFloat = 3
    private static let thumbHeight: CGFloat = 36
    private static let edgeInset: CGFloat = 2

    private let thumb = CALayer()
    /// 0 is the top of the history, 1 the bottom. Nil hides the thumb.
    private var position: Double?

    var color: NSColor = .white {
        didSet { thumb.backgroundColor = color.withAlphaComponent(0.4).cgColor }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        thumb.cornerRadius = Self.thumbWidth / 2
        thumb.backgroundColor = color.withAlphaComponent(0.4).cgColor
        thumb.isHidden = true
        layer?.addSublayer(thumb)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(position newPosition: Double?) {
        guard newPosition != position else { return }
        position = newPosition
        updateThumb()
    }

    override func layout() {
        super.layout()
        updateThumb()
    }

    /// Bottom edge of the thumb in a track of `trackHeight`, whose origin is at the bottom.
    static func thumbOriginY(position: Double, trackHeight: CGFloat, thumbHeight: CGFloat) -> CGFloat {
        let clamped = CGFloat(min(max(position, 0), 1))
        return max(trackHeight - thumbHeight, 0) * (1 - clamped)
    }

    private func updateThumb() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let position else {
            thumb.isHidden = true
            return
        }
        thumb.isHidden = false
        thumb.frame = NSRect(
            x: bounds.maxX - Self.thumbWidth - Self.edgeInset,
            y: Self.thumbOriginY(position: position, trackHeight: bounds.height, thumbHeight: Self.thumbHeight),
            width: Self.thumbWidth,
            height: Self.thumbHeight
        )
    }
}
