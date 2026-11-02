import Cocoa

/// Drives view frames with damped springs, by hand, one step per display
/// frame. Unlike a `CASpringAnimation`, a target can change mid-flight and
/// the motion carries its current velocity into the new one — what a drag
/// needs, where slots keep shifting while the pointer moves.
///
/// The animator never touches a view itself: each spring calls its `apply`
/// closure with the frame for the current step, so the owner decides what
/// moves along with it.
@MainActor
final class FrameSpringAnimator: NSObject {
    /// SwiftUI-style spring parameters: `response` is roughly the period in
    /// seconds, `dampingRatio` 1 settles without overshoot, lower bounces.
    struct Spring {
        var response: Double
        var dampingRatio: Double

        /// Panes making room, settling into a new slot.
        static let settle = Spring(response: 0.38, dampingRatio: 0.78)
        /// A dropped pane landing in its slot, with a small bounce.
        static let drop = Spring(response: 0.34, dampingRatio: 0.68)
        /// A lifted pane chasing the pointer: tight, with a little lag.
        static let follow = Spring(response: 0.12, dampingRatio: 0.9)
    }

    private final class State {
        var value: [Double]
        var velocity: [Double] = [0, 0, 0, 0]
        var target: [Double]
        var spring: Spring
        let apply: (NSRect) -> Void
        var completion: (() -> Void)?

        init(from: NSRect, to: NSRect, spring: Spring, apply: @escaping (NSRect) -> Void) {
            value = State.components(from)
            target = State.components(to)
            self.spring = spring
            self.apply = apply
        }

        static func components(_ rect: NSRect) -> [Double] {
            [rect.origin.x, rect.origin.y, rect.width, rect.height].map(Double.init)
        }

        static func rect(_ c: [Double]) -> NSRect {
            NSRect(x: c[0], y: c[1], width: max(c[2], 0), height: max(c[3], 0))
        }
    }

    /// The view whose display drives the ticks.
    private weak var host: NSView?
    private var states: [ObjectIdentifier: State] = [:]
    private var ticker: AnyObject?
    private var lastTick: CFTimeInterval = 0

    init(host: NSView) {
        self.host = host
        super.init()
    }

    var isAnimating: Bool { !states.isEmpty }

    func isAnimating(_ view: NSView) -> Bool {
        states[ObjectIdentifier(view)] != nil
    }

    /// The frame `view` is currently drawn at by its spring, if it has one.
    func presentedFrame(of view: NSView) -> NSRect? {
        states[ObjectIdentifier(view)].map { State.rect($0.value) }
    }

    /// Springs `view` from where it is now (or from `from`, if given) to
    /// `target`. If `view` is already springing, only the target and spring
    /// change; its velocity carries over. `completion` runs once it settles;
    /// retargeting without a new one keeps the pending one, stopping drops it.
    func animate(
        _ view: NSView,
        from: NSRect? = nil,
        to target: NSRect,
        spring: Spring = .settle,
        apply: @escaping (NSRect) -> Void,
        completion: (() -> Void)? = nil
    ) {
        let key = ObjectIdentifier(view)
        if let state = states[key] {
            state.target = State.components(target)
            state.spring = spring
            if let completion { state.completion = completion }
        } else {
            let state = State(from: from ?? view.frame, to: target, spring: spring, apply: apply)
            state.completion = completion
            states[key] = state
        }
        startTicking()
    }

    /// Drops `view`'s spring where it is, without applying its target.
    func stop(_ view: NSView) {
        states[ObjectIdentifier(view)] = nil
        if states.isEmpty { stopTicking() }
    }

    // MARK: - Ticking

    private func startTicking() {
        guard ticker == nil else { return }
        lastTick = CACurrentMediaTime()
        if #available(macOS 14.0, *), let host {
            let link = host.displayLink(target: self, selector: #selector(displayLinkFired))
            link.add(to: .main, forMode: .common)
            ticker = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            // `.common` so it keeps firing inside event-tracking loops.
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
    }

    private func stopTicking() {
        if #available(macOS 14.0, *), let link = ticker as? CADisplayLink {
            link.invalidate()
        }
        (ticker as? Timer)?.invalidate()
        ticker = nil
    }

    @objc private func displayLinkFired() {
        tick()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        // Clamped so a stall (e.g. a blocked main thread) doesn't fling
        // everything across the window on the next frame.
        let elapsed = min(now - lastTick, 1.0 / 30.0)
        lastTick = now

        var settled: [(ObjectIdentifier, State)] = []
        for (key, state) in states {
            step(state, by: elapsed)
            if isAtRest(state) {
                state.value = state.target
                settled.append((key, state))
            }
            state.apply(State.rect(state.value))
        }
        for (key, state) in settled {
            states[key] = nil
            state.completion?()
        }
        if states.isEmpty { stopTicking() }
    }

    /// Semi-implicit Euler in small substeps, stable for any spring the
    /// grid uses at any frame rate.
    private func step(_ state: State, by elapsed: Double) {
        let omega = 2 * Double.pi / max(state.spring.response, 0.01)
        let stiffness = omega * omega
        let damping = 2 * state.spring.dampingRatio * omega
        let substeps = max(1, Int(ceil(elapsed / (1.0 / 480.0))))
        let dt = elapsed / Double(substeps)
        for _ in 0..<substeps {
            for i in 0..<4 {
                let force = -stiffness * (state.value[i] - state.target[i]) - damping * state.velocity[i]
                state.velocity[i] += force * dt
                state.value[i] += state.velocity[i] * dt
            }
        }
    }

    private func isAtRest(_ state: State) -> Bool {
        (0..<4).allSatisfy {
            abs(state.value[$0] - state.target[$0]) < 0.2 && abs(state.velocity[$0]) < 2
        }
    }
}
