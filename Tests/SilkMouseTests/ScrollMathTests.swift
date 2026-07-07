import XCTest
@testable import SilkMouse

/// Guards the spring scroll math (`ScrollAnimator.springAdvance`) — the most regression-prone part,
/// since scroll feel has been re-tuned repeatedly. Verifies it converges to exactly the accumulated
/// target, never overshoots, eases in (no instantaneous speed jump — the anti-pulse property that
/// distinguishes it from the old exponential ease), and is frame-rate independent.
final class ScrollMathTests: XCTestCase {

    private let omega = 26.0
    private let stopDistance = 0.1
    private let stopSpeed = 20.0

    private func advance(_ rem: Double, _ vel: Double, dt: Double, omega om: Double? = nil)
        -> (delta: Double, remaining: Double, velocity: Double) {
        ScrollAnimator.springAdvance(remaining: rem, velocity: vel, dt: dt, omega: om ?? omega,
                                     stopDistance: stopDistance, stopSpeed: stopSpeed)
    }

    /// Drive `springAdvance` from rest to completion; return total emitted + frames taken.
    private func drain(target: Double, dt: Double, omega om: Double? = nil) -> (total: Double, frames: Int) {
        var rem = target, vel = 0.0, total = 0.0, frames = 0
        while rem != 0 {
            let r = advance(rem, vel, dt: dt, omega: om)
            total += r.delta
            rem = r.remaining
            vel = r.velocity
            frames += 1
            XCTAssertLessThan(frames, 10_000, "springAdvance failed to converge")
        }
        return (total, frames)
    }

    func testConvergesToExactTarget() {
        let (total, _) = drain(target: 100, dt: 1.0 / 60)
        XCTAssertEqual(total, 100, accuracy: 1e-9, "must emit exactly the accumulated distance")
    }

    func testNegativeTargetConverges() {
        let (total, _) = drain(target: -250, dt: 1.0 / 60)
        XCTAssertEqual(total, -250, accuracy: 1e-9)
    }

    /// The closed-form solution must be exact: two 1/120 s steps land on the same (remaining,
    /// velocity) state as one 1/60 s step, so refresh rate never changes the motion.
    func testFrameRateIndependentState() {
        var rem60 = 500.0, vel60 = 0.0
        var rem120 = 500.0, vel120 = 0.0
        for _ in 0..<20 {
            let a = advance(rem60, vel60, dt: 1.0 / 60)
            rem60 = a.remaining; vel60 = a.velocity
            for _ in 0..<2 {
                let b = advance(rem120, vel120, dt: 1.0 / 120)
                rem120 = b.remaining; vel120 = b.velocity
            }
            XCTAssertEqual(rem60, rem120, accuracy: 1e-6)
            XCTAssertEqual(vel60, vel120, accuracy: 1e-4)
        }
    }

    /// No frame may emit more than what was remaining (no overshoot past the target).
    func testNeverOvershoots() {
        var rem = 300.0, vel = 0.0
        while rem > 0 {
            let r = advance(rem, vel, dt: 1.0 / 60)
            XCTAssertLessThanOrEqual(r.delta, rem + 1e-9)
            XCTAssertGreaterThanOrEqual(r.remaining, -1e-9)
            rem = r.remaining; vel = r.velocity
        }
    }

    /// High incoming velocity onto a small remainder (post-reversal artifact) must clamp at the
    /// target — a clean stop, never a bounce-back past it.
    func testIncomingOvershootClampsAtTarget() {
        let r = advance(0.05, 500, dt: 1.0 / 60)
        XCTAssertEqual(r.delta, 0.05, accuracy: 1e-9)
        XCTAssertEqual(r.remaining, 0)
        XCTAssertEqual(r.velocity, 0)
    }

    /// A sub-threshold sliver (small distance AND low speed) is flushed in one frame so motion
    /// stops instead of crawling asymptotically.
    func testSubStopSliverFlushesImmediately() {
        let r = advance(0.05, 5, dt: 1.0 / 60)
        XCTAssertEqual(r.delta, 0.05, accuracy: 1e-12)
        XCTAssertEqual(r.remaining, 0)
        XCTAssertEqual(r.velocity, 0)
    }

    /// From rest the spring eases IN: the first frame's delta is smaller than the second's. (The old
    /// exponential ease jumped to peak speed instantly — the source of per-notch pulsing.)
    func testEasesInFromRest() {
        let f1 = advance(500, 0, dt: 1.0 / 60)
        let f2 = advance(f1.remaining, f1.velocity, dt: 1.0 / 60)
        XCTAssertGreaterThan(f2.delta, f1.delta)
    }

    /// Per-frame deltas form a single hump (rise, then taper) — smooth ease-in-out, no oscillation.
    /// The final flush frame (sub-`stopDistance` sliver emitted in one go) is exempt, as before.
    func testDeltasUnimodal() {
        var rem = 1000.0, vel = 0.0, prev = 0.0
        var falling = false, frames = 0
        while rem != 0 {
            let r = advance(rem, vel, dt: 1.0 / 60)
            if r.remaining == 0 { break } // flush frame — exempt
            if falling {
                XCTAssertLessThanOrEqual(r.delta, prev + 1e-9, "delta rose again after tapering")
            } else if r.delta < prev {
                falling = true
            }
            prev = r.delta
            rem = r.remaining; vel = r.velocity
            frames += 1
            XCTAssertLessThan(frames, 10_000)
        }
    }

    /// Retargeting mid-glide (a new notch adds distance, velocity carried over) must NOT jump the
    /// per-frame delta the way the old ease did — growth is acceleration-limited, not instantaneous.
    func testRetargetKeepsVelocityContinuous() {
        var rem = 200.0, vel = 0.0, prevDelta = 0.0
        for _ in 0..<4 {
            let r = advance(rem, vel, dt: 1.0 / 60)
            prevDelta = r.delta
            rem = r.remaining; vel = r.velocity
        }
        let added = 300.0
        rem += added // notch mid-glide: target moves, velocity unchanged
        let next = advance(rem, vel, dt: 1.0 / 60)
        // Old model would jump by the full eased fraction of `added`; the spring must stay well under.
        let oldModelJump = added * (1 - exp(-(1.0 / 60) / 0.07))
        XCTAssertLessThan(next.delta - prevDelta, oldModelJump * 0.5,
                          "delta jumped on retarget — velocity continuity broken")
    }

    /// A stiffer spring (Smooth-step) settles in fewer frames than the softer Smooth spring.
    func testStifferOmegaSettlesFaster() {
        XCTAssertLessThan(drain(target: 200, dt: 1.0 / 60, omega: 40).frames,
                          drain(target: 200, dt: 1.0 / 60, omega: 26).frames)
    }

    // MARK: - Momentum handoff predicate

    /// A flick — rapid burst, then silence, still fast, real backlog — hands off to momentum.
    func testMomentumFiresOnFlick() {
        XCTAssertTrue(ScrollAnimator.shouldStartMomentum(
            silence: 0.12, lastGap: 0.05, speed: 800, backlog: 300, stepped: false))
    }

    /// Steady deliberate ticking (inter-tick gaps ≳ 0.1 s) must NEVER coast, at any speed —
    /// that's the exact-stop guarantee for slow scrolling.
    func testMomentumBlockedDuringSteadyTicking() {
        XCTAssertFalse(ScrollAnimator.shouldStartMomentum(
            silence: 0.12, lastGap: 0.12, speed: 2000, backlog: 500, stepped: false))
    }

    /// While ticks are still arriving (no real silence yet), no handoff — the gesture continues.
    func testMomentumBlockedWhileTicksStillArriving() {
        XCTAssertFalse(ScrollAnimator.shouldStartMomentum(
            silence: 0.05, lastGap: 0.05, speed: 800, backlog: 300, stepped: false))
    }

    /// A single notch's "last gap" is the huge pause before it — never a flick.
    func testMomentumBlockedForSingleNotch() {
        XCTAssertFalse(ScrollAnimator.shouldStartMomentum(
            silence: 0.12, lastGap: 5.0, speed: 800, backlog: 300, stepped: false))
    }

    /// Too slow or too shallow a backlog → settle exactly, no coast label.
    func testMomentumBlockedWhenSlowOrShallow() {
        XCTAssertFalse(ScrollAnimator.shouldStartMomentum(
            silence: 0.12, lastGap: 0.05, speed: 200, backlog: 300, stepped: false))
        XCTAssertFalse(ScrollAnimator.shouldStartMomentum(
            silence: 0.12, lastGap: 0.05, speed: 800, backlog: 50, stepped: false))
    }

    /// Smooth-step mode never coasts — its notches are discrete steps by definition.
    func testMomentumNeverInSteppedMode() {
        XCTAssertFalse(ScrollAnimator.shouldStartMomentum(
            silence: 0.12, lastGap: 0.05, speed: 800, backlog: 300, stepped: true))
    }

    // MARK: - Acceleration (speedup) curve

    /// A fast same-direction notch ramps the multiplier up; it never exceeds the ceiling.
    func testAccelRampsUpAndCaps() {
        var a = 1.0
        for _ in 0..<20 { a = ScrollAnimator.nextAccel(current: a, gap: 0.05, sameDir: true) }
        XCTAssertGreaterThan(a, 1.0)
        XCTAssertLessThanOrEqual(a, 2.05 + 1e-9, "must not exceed accelMax")
    }

    /// A slow notch (large gap) resets the multiplier to 1.0 even at high current value.
    func testAccelResetsOnSlowTick() {
        XCTAssertEqual(ScrollAnimator.nextAccel(current: 2.5, gap: 1.0, sameDir: true), 1.0, accuracy: 1e-9)
    }

    /// Reversing direction resets the multiplier even when ticks are fast.
    func testAccelResetsOnDirectionChange() {
        XCTAssertEqual(ScrollAnimator.nextAccel(current: 2.0, gap: 0.05, sameDir: false), 1.0, accuracy: 1e-9)
    }

    /// One fast tick from rest grows the multiplier above 1.0 but stays modest.
    func testAccelSingleFastTick() {
        let a = ScrollAnimator.nextAccel(current: 1.0, gap: 0.05, sameDir: true)
        XCTAssertGreaterThan(a, 1.0)
        XCTAssertLessThan(a, 2.0)
    }
}
