import Cocoa

/// Thin rounded border drawn over a grid where a ⌘-drag would land if
/// released now: the slot of a pane being moved within the grid, or the
/// slots another window's panes would take in a merge. Purely visual — it
/// never takes mouse events.
final class SlotPreviewView: NSView {
    private var slotLayers: [CAShapeLayer] = []
    /// Bumped on every show/hide so a fade-out that finishes after the
    /// preview was shown again doesn't hide it.
    private var generation = 0

    private let slotRadius: CGFloat = 16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        alphaValue = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows the preview with one slot per rect in `slots` (in this view's
    /// coordinates), springing the slots in from slightly smaller.
    func show(slots: [NSRect]) {
        generation += 1
        let tint = NSColor.white

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slotLayers.forEach { $0.removeFromSuperlayer() }
        slotLayers = slots.map { makeSlot($0, tint: tint) }
        slotLayers.forEach { layer?.addSublayer($0) }
        CATransaction.commit()

        for slot in slotLayers {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.86
            spring.toValue = 1
            spring.damping = 13
            spring.stiffness = 210
            spring.mass = 1
            spring.duration = spring.settlingDuration
            slot.add(spring, forKey: "springIn")
        }

        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func hide(animated: Bool) {
        generation += 1
        guard !isHidden else { return }
        guard animated else {
            alphaValue = 0
            isHidden = true
            return
        }
        let current = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.isHidden = true
            }
        }
    }

    private func makeSlot(_ rect: NSRect, tint: NSColor) -> CAShapeLayer {
        let slot = CAShapeLayer()
        // A standalone layer anchors at its center, so the spring-in
        // scales each slot about its own middle.
        slot.frame = rect.insetBy(dx: 2, dy: 2)
        slot.path = CGPath(
            roundedRect: slot.bounds, cornerWidth: slotRadius, cornerHeight: slotRadius,
            transform: nil
        )
        slot.fillColor = tint.withAlphaComponent(0.05).cgColor
        slot.strokeColor = tint.withAlphaComponent(0.6).cgColor
        slot.lineWidth = 1.5
        return slot
    }
}
