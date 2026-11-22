import Cocoa

/// Overlay on a pane's cell: a ring while it has unread activity and a dot with its agent's
/// state. Lives on the cell, not the terminal, because an unfocused terminal is wider than
/// its cell and would clip anything anchored to its right edge.
final class PaneStatusView: NSView {
    private static let dotSize: CGFloat = 8
    private static let dotInset: CGFloat = 9

    private let ring = CALayer()
    private let dot = CALayer()
    private var agentState: AgentState?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        ring.borderWidth = 2
        ring.isHidden = true
        dot.cornerRadius = Self.dotSize / 2
        dot.isHidden = true
        layer?.addSublayer(ring)
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var cornerRadius: CGFloat = 16 {
        didSet { ring.cornerRadius = cornerRadius }
    }

    func update(unread: Bool, agentState newState: AgentState?, ringColor: NSColor) {
        ring.isHidden = !unread
        ring.borderColor = ringColor.withAlphaComponent(0.9).cgColor
        guard newState != agentState else { return }
        agentState = newState
        dot.isHidden = newState == nil
        dot.backgroundColor = Self.color(for: newState).cgColor
        dot.removeAnimation(forKey: "pulse")
        if newState == .working {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.3
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            dot.add(pulse, forKey: "pulse")
        }
    }

    private static func color(for state: AgentState?) -> NSColor {
        switch state {
        case .working: return .systemBlue
        case .waiting: return .systemOrange
        case .done: return .systemGreen
        case .error: return .systemRed
        case nil: return .clear
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        dot.frame = NSRect(
            x: bounds.maxX - Self.dotSize - Self.dotInset,
            y: bounds.maxY - Self.dotSize - Self.dotInset,
            width: Self.dotSize, height: Self.dotSize
        )
        CATransaction.commit()
    }
}
