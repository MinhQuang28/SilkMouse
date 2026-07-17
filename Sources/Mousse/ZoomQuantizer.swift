/// Quantizes the Cmd+scroll zoom-delta stream into discrete keystroke steps for the macOS 27+
/// fallback (`MagnifySynthesizer.postZoomKeystroke`). The pinch path integrates deltas natively;
/// keystrokes can't — and firing one per raw event would zoom-storm on free-spin/continuous mice
/// (a flick is dozens to hundreds of events). Instead: accumulate deltas and fire one step per
/// `step` worth, at most one step per `minInterval`, with a bounded backlog so a hard flick owes
/// at most a few steps. The backlog drains only on later feeds (no timer), so zooming can never
/// continue on its own after the wheel stops. Carry resets on direction flips and idle gaps.
///
/// Pure value type with injected time — no clocks, no posting — so it's unit-testable.
struct ZoomQuantizer {
    private let step: Double        // magnification per zoom step (one wheel notch's worth)
    private let minInterval: Double // s between steps — app zoom steps are chunky (~10% each)
    private let idleReset: Double   // s of wheel silence after which leftover carry is stale
    private let maxCarry: Double    // backlog bound, in magnification units

    private var carry = 0.0
    private var lastFeed = -Double.infinity
    private var lastFire = -Double.infinity

    /// `step` defaults to the engine's per-notch zoom tick (60/800), so one ratchet notch stays
    /// exactly one zoom step.
    init(step: Double = 60.0 / 800.0, minInterval: Double = 0.1,
         idleReset: Double = 0.3, maxPendingSteps: Double = 3) {
        self.step = step
        self.minInterval = minInterval
        self.idleReset = idleReset
        self.maxCarry = maxPendingSteps * step
    }

    /// Feed one event's magnification delta; returns the zoom steps to fire now: -1, 0, or +1
    /// (positive = zoom in).
    mutating func feed(_ magnification: Double, at now: Double) -> Int {
        guard magnification != 0 else { return 0 }
        if now - lastFeed > idleReset { carry = 0 }
        lastFeed = now
        if carry != 0, (carry > 0) != (magnification > 0) { carry = 0 } // direction flip
        carry = min(max(carry + magnification, -maxCarry), maxCarry)
        guard now - lastFire >= minInterval, abs(carry) >= step else { return 0 }
        let fired = carry > 0 ? 1 : -1
        carry -= Double(fired) * step
        lastFire = now
        return fired
    }
}
