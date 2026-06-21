import CoreGraphics
import Foundation

/// Turns discrete mouse-wheel notches into a smooth, eased pixel-scroll animation.
/// Lives entirely on the event-tap thread's run loop: fed from the tap callback (`addTick`),
/// drained by a run-loop timer that posts pixel-precise scroll events.
final class ScrollAnimator {

    /// Marks our own synthetic scroll events (via `.eventSourceUserData`) so the tap skips them.
    static let syntheticTag: Int64 = 0x5132_4D46 // "Q2MF"

    private var remainingV = 0.0
    private var remainingH = 0.0
    private var timer: CFRunLoopTimer?
    private let source = CGEventSource(stateID: .hidSystemState)

    private let pixelsPerLine = 48.0  // travel distance of one wheel notch
    private let stiffness = 0.28      // fraction of remaining distance consumed per frame (ease-out)

    /// Feed a wheel tick (line deltas, already direction-corrected). Accumulates the target.
    func addTick(lineV: Double, lineH: Double) {
        remainingV += lineV * pixelsPerLine
        remainingH += lineH * pixelsPerLine
        startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let t = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
                                                CFAbsoluteTimeGetCurrent(),
                                                1.0 / 90.0, 0, 0) { [weak self] _ in
            self?.step()
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, .commonModes)
        timer = t
    }

    private func step() {
        let v = nextStep(&remainingV)
        let h = nextStep(&remainingH)
        if v != 0 || h != 0 { postPixels(v: Int32(v), h: Int32(h)) }
        if abs(remainingV) < 1 && abs(remainingH) < 1 {
            remainingV = 0; remainingH = 0
            stop()
        }
    }

    /// Ease-out step that always makes progress (so it converges instead of stalling sub-pixel).
    private func nextStep(_ remaining: inout Double) -> Double {
        var s = (remaining * stiffness).rounded()
        if s == 0 && abs(remaining) >= 1 { s = remaining > 0 ? 1 : -1 }
        remaining -= s
        return s
    }

    private func postPixels(v: Int32, h: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2, wheel1: v, wheel2: h, wheel3: 0) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: ScrollAnimator.syntheticTag)
        event.post(tap: .cghidEventTap)
    }

    private func stop() {
        if let timer { CFRunLoopTimerInvalidate(timer) }
        timer = nil
    }
}
