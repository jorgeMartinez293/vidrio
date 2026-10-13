import Cocoa
import Testing
@testable import Vidrio

@Suite struct TwoFingerScrollFilterTests {

    /// Runs a full finger-driven gesture and returns the verdict of each event.
    private func gesture(_ filter: inout TwoFingerScrollFilter) -> [Bool] {
        [
            filter.shouldDeliver(phase: .began, momentumPhase: []),
            filter.shouldDeliver(phase: .changed, momentumPhase: []),
            filter.shouldDeliver(phase: .ended, momentumPhase: []),
        ]
    }

    private func deliver(_ filter: inout TwoFingerScrollFilter, _ phase: NSEvent.Phase) -> Bool {
        filter.shouldDeliver(phase: phase, momentumPhase: [])
    }

    private func momentum(_ filter: inout TwoFingerScrollFilter) -> [Bool] {
        [
            filter.shouldDeliver(phase: [], momentumPhase: .began),
            filter.shouldDeliver(phase: [], momentumPhase: .changed),
            filter.shouldDeliver(phase: [], momentumPhase: .ended),
        ]
    }

    @Test func twoFingerScrollIsDelivered() {
        var filter = TwoFingerScrollFilter()
        filter.touchesChanged(count: 2)
        #expect(gesture(&filter) == [true, true, true])
        filter.touchesChanged(count: 0)
        #expect(momentum(&filter) == [true, true, true])
    }

    @Test(arguments: [3, 4, 5])
    func multiFingerScrollIsDropped(fingers: Int) {
        var filter = TwoFingerScrollFilter()
        filter.touchesChanged(count: fingers)
        #expect(gesture(&filter) == [false, false, false])
    }

    @Test func momentumOfMultiFingerScrollIsDropped() {
        var filter = TwoFingerScrollFilter()
        filter.touchesChanged(count: 3)
        _ = gesture(&filter)
        filter.touchesChanged(count: 0)
        #expect(momentum(&filter) == [false, false, false])
    }

    @Test func fingerAddedMidGestureDropsTheRest() {
        var filter = TwoFingerScrollFilter()
        filter.touchesChanged(count: 2)
        #expect(deliver(&filter, .began))
        filter.touchesChanged(count: 3)
        #expect(!deliver(&filter, .changed))
        // Lifting the extra finger does not rescue the gesture.
        filter.touchesChanged(count: 2)
        #expect(!deliver(&filter, .changed))
        #expect(!deliver(&filter, .ended))
        filter.touchesChanged(count: 0)
        #expect(momentum(&filter) == [false, false, false])
    }

    @Test func twoFingerScrollAfterRejectedOneIsDelivered() {
        var filter = TwoFingerScrollFilter()
        filter.touchesChanged(count: 4)
        _ = gesture(&filter)
        filter.touchesChanged(count: 0)
        filter.touchesChanged(count: 2)
        #expect(gesture(&filter) == [true, true, true])
    }

    @Test func gestureWithoutBeganIsJudgedOnItsFirstEvent() {
        var filter = TwoFingerScrollFilter()
        filter.touchesChanged(count: 3)
        _ = gesture(&filter)
        filter.touchesChanged(count: 2)
        #expect(deliver(&filter, .changed))
    }

    @Test func mouseWheelIsAlwaysDelivered() {
        var filter = TwoFingerScrollFilter()
        filter.touchesChanged(count: 3)
        _ = gesture(&filter)
        #expect(deliver(&filter, []))
    }

    @Test func deviceWithoutTouchesIsDelivered() {
        var filter = TwoFingerScrollFilter()
        #expect(gesture(&filter) == [true, true, true])
        #expect(momentum(&filter) == [true, true, true])
    }
}
