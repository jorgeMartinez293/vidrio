import Cocoa

/// Decides whether a scroll-wheel event should reach the terminal, so that only
/// two-finger trackpad scrolls are honored.
///
/// macOS reports scrolls made with three, four or five fingers through the same
/// `scrollWheel(with:)` events as a two-finger scroll (whenever the matching
/// system gestures are disabled), and those events carry no finger count. The
/// view feeds this filter the number of fingers resting on the trackpad, and the
/// filter rejects a whole gesture — including its momentum tail, which arrives
/// after the fingers have lifted — as soon as more than two fingers take part.
///
/// Devices that report no touches at all (a mouse wheel, a Magic Mouse) are left
/// alone: with fewer than three known fingers there is nothing to reject.
struct TwoFingerScrollFilter {

    static let maximumFingers = 2

    /// Fingers currently resting on the trackpad, as last reported by the view.
    private(set) var touchCount = 0
    /// Whether a scroll gesture is in its finger-driven (non-momentum) part.
    private var gestureActive = false
    /// Whether the current gesture, and the momentum that follows it, is dropped.
    private var gestureRejected = false

    mutating func touchesChanged(count: Int) {
        touchCount = count
        // A finger added mid-scroll turns the gesture into a multi-finger one.
        if gestureActive && count > Self.maximumFingers {
            gestureRejected = true
        }
    }

    mutating func shouldDeliver(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) -> Bool {
        // Neither phase set: a classic mouse wheel, which has no fingers to count.
        if phase.isEmpty && momentumPhase.isEmpty {
            return true
        }
        // Momentum inherits the verdict of the gesture that produced it.
        if phase.isEmpty {
            return !gestureRejected
        }

        // Also covers a gesture whose start was delivered to another view.
        let starting = !gestureActive || !phase.isDisjoint(with: [.began, .mayBegin])
        if starting {
            gestureActive = true
            gestureRejected = touchCount > Self.maximumFingers
        } else if touchCount > Self.maximumFingers {
            gestureRejected = true
        }
        if !phase.isDisjoint(with: [.ended, .cancelled]) {
            gestureActive = false
        }
        return !gestureRejected
    }
}
