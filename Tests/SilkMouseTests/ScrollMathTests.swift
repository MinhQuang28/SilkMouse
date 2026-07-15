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

    // MARK: - Hi-res pixel gain (free-spin safety)

    /// Slow, deliberate hi-res scrolling gets the slider's full gain.
    func testPixelGainFullWhenSlow() {
        XCTAssertEqual(ScrollAnimator.pixelGain(slider: 1.5, inputSpeed: 300), 3.0, accuracy: 1e-9)
        XCTAssertEqual(ScrollAnimator.pixelGain(slider: 0.5, inputSpeed: 300), 1.0, accuracy: 1e-9)
    }

    /// Above the knee, the excess input speed passes 1:1: amplification of a free-spinning
    /// flywheel is bounded (out ≤ in + knee·(g−1)) and the OUTPUT speed is monotonic in the
    /// input speed — a decaying flywheel must never make the view speed UP mid-coast.
    func testPixelGainKneeBoundedAndMonotonic() {
        let knee = 800.0, g = 3.0
        var prevOut = 0.0
        for inSpeed in stride(from: 100.0, through: 20_000.0, by: 100.0) {
            let out = inSpeed * ScrollAnimator.pixelGain(slider: 1.5, inputSpeed: inSpeed)
            XCTAssertGreaterThan(out, prevOut, "output speed must rise with input speed")
            XCTAssertLessThanOrEqual(out, inSpeed + knee * (g - 1) + 1e-6,
                                     "flywheel amplification must stay bounded")
            prevOut = out
        }
        // Asymptotically native: at very high spin the gain approaches ×1.
        XCTAssertLessThan(ScrollAnimator.pixelGain(slider: 1.5, inputSpeed: 50_000), 1.05)
    }

    /// Slow-down gains (slider below default) reduce distance and can't overshoot — never faded.
    func testPixelGainSlowdownNeverFaded() {
        let slow = ScrollAnimator.pixelGain(slider: 0.25, inputSpeed: 300)
        XCTAssertLessThan(slow, 1.0)
        XCTAssertEqual(ScrollAnimator.pixelGain(slider: 0.25, inputSpeed: 10_000), slow, accuracy: 1e-12)
    }

    // MARK: - Reversal brake

    /// A reversed notch against a real coast (quiet input, still moving) brakes the page.
    func testBrakeFiresOnCoastReversal() {
        XCTAssertTrue(ScrollAnimator.shouldBrakeOnReversal(silence: 0.3, speed: 800))
    }

    /// Active back-and-forth ticking (no quiet window) reverses immediately — never a brake.
    func testBrakeBlockedDuringActiveTicking() {
        XCTAssertFalse(ScrollAnimator.shouldBrakeOnReversal(silence: 0.08, speed: 800))
    }

    /// A nearly-settled crawl reverses normally — stopping a barely-moving page means nothing.
    func testBrakeBlockedWhenNearlySettled() {
        XCTAssertFalse(ScrollAnimator.shouldBrakeOnReversal(silence: 0.3, speed: 60))
    }
}

/// Guards the MMF scroll model (MMFScrollMath.swift) that drives Smooth mode: acceleration curve,
/// fast-scroll speedup, drag physics, hybrid plan, and tick/swipe analysis.
final class MMFScrollMathTests: XCTestCase {

    // MARK: - Acceleration curve (tick rate → px per notch)

    /// Slow single ticks sit at minSens; the fastest ticking reaches maxSens; in between is linear.
    func testAccelerationCurveEndpoints() {
        XCTAssertEqual(MMFScrollTuning.pxPerTick(tickHz: 1, minSens: 90, maxSens: 180), 90)
        XCTAssertEqual(MMFScrollTuning.pxPerTick(tickHz: 6.25, minSens: 90, maxSens: 180), 90, accuracy: 1e-9)
        XCTAssertEqual(MMFScrollTuning.pxPerTick(tickHz: 1 / 0.015, minSens: 90, maxSens: 180), 180,
                       accuracy: 1e-9)
        let mid = MMFScrollTuning.pxPerTick(tickHz: (6.25 + 1 / 0.015) / 2, minSens: 90, maxSens: 180)
        XCTAssertEqual(mid, 135, accuracy: 1e-6)
    }

    /// Speed slider maps to MMF's low/medium/high sensitivity anchors and extends beyond 1.0.
    func testSensitivityMapping() {
        let p = MMFScrollProfile.balanced
        XCTAssertEqual(p.sensitivity(slider: 0).minSens, 30)
        XCTAssertEqual(p.sensitivity(slider: 0.5).minSens, 60)
        XCTAssertEqual(p.sensitivity(slider: 0.5).maxSens, 120)
        XCTAssertEqual(p.sensitivity(slider: 1).maxSens, 180)
        XCTAssertGreaterThan(p.sensitivity(slider: 1.5).maxSens, 180)
    }

    /// Screen-size scaling: maxSens gets a 10%-weighted boost by screen span vs the 1080p
    /// baseline; minSens is untouched (slow single ticks stay gentle on any display).
    func testSensitivityScreenScaling() {
        let p = MMFScrollProfile.balanced
        let base = p.sensitivity(slider: 0.5, screenSizeFactor: 1.0)
        let big = p.sensitivity(slider: 0.5, screenSizeFactor: 2.0) // 2160p display
        XCTAssertEqual(big.minSens, base.minSens)
        XCTAssertEqual(big.maxSens, base.maxSens * 1.1, accuracy: 1e-9)
    }

    /// The three smoothness profiles order correctly: floaty coasts longer than balanced,
    /// which coasts longer than snappy, for the same flick.
    func testSmoothnessProfilesOrdered() {
        let dist = 400.0, v0 = 1500.0
        let snappy = MMFHybridPlan(distance: dist, initialSpeed: v0, profile: .snappy)
        let balanced = MMFHybridPlan(distance: dist, initialSpeed: v0, profile: .balanced)
        let floaty = MMFHybridPlan(distance: dist, initialSpeed: v0, profile: .floaty)
        XCTAssertLessThan(snappy.duration, balanced.duration)
        XCTAssertLessThan(balanced.duration, floaty.duration)
    }

    /// Modifier profiles: precise moves a few px per notch regardless of the slider; quick moves
    /// about half a window per notch, scaled to the screen.
    func testModifierProfiles() {
        let precise = MMFScrollProfile.precise.sensitivity(slider: 1.5)
        XCTAssertEqual(precise.minSens, 2)
        XCTAssertLessThanOrEqual(precise.maxSens, 20)
        let quick = MMFScrollProfile.quick(screenSpan: 1080).sensitivity(slider: 0.5)
        XCTAssertEqual(quick.minSens, 1080 * 0.85 * 0.5, accuracy: 1e-9)
        XCTAssertEqual(quick.maxSens, 1080 * 0.85 * 1.5, accuracy: 1e-9)
        XCTAssertNil(MMFScrollProfile.precise.speedup, "precise never fast-scrolls")
    }

    // MARK: - Fast-scroll speedup

    /// No speedup below the swipe threshold; the first step is ×initialSpeedup; growth is monotonic.
    func testSpeedupCurve() {
        let c = MMFSpeedupCurve.regular
        XCTAssertEqual(c.factor(swipes: 0), 1.0)
        XCTAssertEqual(c.factor(swipes: 2), 1.0) // swipes+1 == 3 == threshold → still exactly 1.0
        XCTAssertEqual(c.factor(swipes: 3), 1.33, accuracy: 1e-9)
        var prev = 1.0
        for s in 0...12 {
            let f = c.factor(swipes: Double(s))
            XCTAssertGreaterThanOrEqual(f, prev)
            prev = f
        }
        XCTAssertLessThanOrEqual(c.factor(swipes: 500), 100_000)
    }

    // MARK: - Drag segment (v' = −a·v^b)

    /// The closed forms must be self-consistent: distance(duration) == distance, speed decays
    /// from v0 to stopSpeed, and distance(t) is monotonic — for exponents both < 1 (MMF High:
    /// 0.7) and > 1 (MMF Regular: 1.05).
    func testDragSegmentSelfConsistent() throws {
        for (a, b) in [(40.0, 0.7), (15.0, 1.05)] {
            let d = try XCTUnwrap(MMFDragSegment(initialSpeed: 800, a: a, b: b, stopSpeed: 30))
            XCTAssertEqual(d.speed(at: 0), 800, accuracy: 1e-6)
            XCTAssertEqual(d.speed(at: d.duration), 30, accuracy: 1e-6)
            XCTAssertEqual(d.speed(at: d.duration * 2), 30, accuracy: 1e-6, "clamp past the end")
            XCTAssertEqual(d.distance(at: d.duration), d.distance, accuracy: 1e-9)
            var prev = 0.0
            for i in 0...50 {
                let t = d.duration * Double(i) / 50
                let x = d.distance(at: t)
                XCTAssertGreaterThanOrEqual(x, prev - 1e-9, "monotonic (b=\(b))")
                prev = x
            }
        }
    }

    /// The distance-based init must produce a segment covering exactly the requested distance.
    func testDragSegmentFromDistance() {
        for (a, b) in [(40.0, 0.7), (15.0, 1.05)] {
            let d = MMFDragSegment(distance: 500, a: a, b: b, stopSpeed: 30)
            XCTAssertEqual(d.distance, 500, accuracy: 1e-6)
            XCTAssertGreaterThan(d.v0, 30)
        }
    }

    /// Slower initial speeds coast shorter — the physical sanity check. Regular's steeper
    /// exponent (b=1.05, a=15) must also coast shorter than High's (b=0.7, a=40) at high speed.
    func testDragSlowerCoastsShorter() throws {
        let fast = try XCTUnwrap(MMFDragSegment(initialSpeed: 2000, a: 15, b: 1.05, stopSpeed: 30))
        let slow = try XCTUnwrap(MMFDragSegment(initialSpeed: 400, a: 15, b: 1.05, stopSpeed: 30))
        XCTAssertGreaterThan(fast.distance, slow.distance)
        XCTAssertGreaterThan(fast.duration, slow.duration)
        let high = try XCTUnwrap(MMFDragSegment(initialSpeed: 2000, a: 40, b: 0.7, stopSpeed: 30))
        XCTAssertLessThan(fast.duration, high.duration, "Regular tail must be shorter than High's")
    }

    // MARK: - Hybrid plan

    /// The plan must cover exactly the requested distance (within the search epsilon), monotonically.
    func testPlanCoversRequestedDistance() {
        for distance in [90.0, 250.0, 1200.0, 8000.0] {
            for v0 in [0.0, 400.0, 3000.0] {
                let p = MMFHybridPlan(distance: distance, initialSpeed: v0)
                XCTAssertEqual(p.distance(at: p.duration), distance, accuracy: 1e-6,
                               "end must land exactly on the target (d=\(distance), v0=\(v0))")
                XCTAssertEqual(p.total, distance)
                var prev = 0.0
                for i in 0...100 {
                    let x = p.distance(at: p.duration * Double(i) / 100)
                    XCTAssertGreaterThanOrEqual(x, prev - 1e-6, "distance must be monotonic")
                    prev = x
                }
            }
        }
    }

    /// Speed smoothing (the mechanism — Regular ships with smoothing 0, so pass it explicitly):
    /// the plan takes off at (about) the incoming glide speed.
    func testPlanStartsAtIncomingSpeed() {
        let v0 = 900.0
        let p = MMFHybridPlan(distance: 400, initialSpeed: v0, profile: .balanced)
        XCTAssertEqual(p.speed(at: 0), v0, accuracy: v0 * 0.02,
                       "initial speed must match the incoming glide speed")
    }

    /// Softened-Regular single notch: eases in from rest (speed smoothing), ends in a moderate
    /// drag coast decaying to the stop speed — smooth but still responsive, no long float.
    func testPlanFromRestEasesInWithShortTail() {
        let p = MMFHybridPlan(distance: 60, initialSpeed: 0)
        XCTAssertLessThan(p.speed(at: 0.005), p.speed(at: 0.05),
                          "must ease in from rest, not jump to full speed")
        XCTAssertTrue(p.inDragPhase(at: p.duration - 0.01), "tail must be the drag coast")
        XCTAssertEqual(p.speed(at: p.duration - 1e-6), 30, accuracy: 5)
        XCTAssertGreaterThan(p.duration, 0.15, "single notch should glide, not snap")
        XCTAssertLessThan(p.duration, 0.7, "the tail must stay reasonably short")
    }

    /// A bigger backlog produces a longer, farther plan (fast scroll keeps stretching the glide).
    func testPlanScalesWithDistance() {
        let small = MMFHybridPlan(distance: 100, initialSpeed: 0)
        let large = MMFHybridPlan(distance: 4000, initialSpeed: 0)
        XCTAssertGreaterThan(large.duration, small.duration)
    }

    /// The gesture→drag transition point must split distance consistently.
    func testPlanTransitionConsistency() {
        let p = MMFHybridPlan(distance: 500, initialSpeed: 600)
        XCTAssertEqual(p.distance(at: p.transitionTime), p.transitionDistance, accuracy: 0.5)
        XCTAssertFalse(p.inDragPhase(at: p.transitionTime * 0.5))
        XCTAssertTrue(p.inDragPhase(at: p.transitionTime + 0.01))
    }

    // MARK: - Tick analyzer

    /// Slow deliberate ticks: every tick is rate-floor (minSens) and never counts swipes.
    func testAnalyzerSlowTicks() {
        var a = MMFTickAnalyzer()
        var t = 10.0
        for _ in 0..<10 {
            let r = a.feed(now: t, direction: 1)
            XCTAssertEqual(r.tickHz, 6.25, accuracy: 1e-9)
            XCTAssertEqual(r.swipes, 0)
            t += 0.3
        }
    }

    /// A rapid burst reports a high tick rate (smoothed over the last 3 gaps).
    func testAnalyzerFastBurst() {
        var a = MMFTickAnalyzer()
        var t = 10.0
        var last = MMFTickAnalyzer.Result(tickHz: 0, swipes: 0, isSequenceStart: true)
        for _ in 0..<5 {
            last = a.feed(now: t, direction: 1)
            t += 0.03
        }
        XCTAssertEqual(last.tickHz, 1 / 0.03, accuracy: 1.0)
    }

    /// Chained fast swipes increment the swipe counter; a long pause resets it.
    func testAnalyzerSwipeChainingAndReset() {
        var a = MMFTickAnalyzer()
        var t = 10.0
        var swipes = 0.0
        for _ in 0..<4 { // four bursts of 7 fast ticks, 0.25 s apart (avg rate ≥ 12 ticks/s)
            for _ in 0..<7 {
                swipes = a.feed(now: t, direction: 1).swipes
                t += 0.02
            }
            t += 0.25 - 0.02
        }
        XCTAssertGreaterThanOrEqual(swipes, 3, "chained bursts must count as consecutive swipes")

        t += 2.0 // long pause → reset
        XCTAssertEqual(a.feed(now: t, direction: 1).swipes, 0)
    }

    /// A direction change resets everything — the first opposite tick is a fresh sequence.
    func testAnalyzerDirectionChangeResets() {
        var a = MMFTickAnalyzer()
        var t = 10.0
        for _ in 0..<5 { _ = a.feed(now: t, direction: 1); t += 0.03 }
        let r = a.feed(now: t + 0.03, direction: -1)
        XCTAssertTrue(r.isSequenceStart)
        XCTAssertEqual(r.tickHz, 6.25, accuracy: 1e-9)
        XCTAssertEqual(r.swipes, 0)
    }

    /// The first tick after idle is a sequence start (leftover glide distance gets dropped).
    func testAnalyzerSequenceStart() {
        var a = MMFTickAnalyzer()
        XCTAssertTrue(a.feed(now: 10, direction: 1).isSequenceStart)
        XCTAssertFalse(a.feed(now: 10.03, direction: 1).isSequenceStart)
    }

    /// Swipe chaining follows the profile's window: floaty (0.6 s / 12 ticks-per-s) chains bursts
    /// that snappy/balanced (0.375 s / 16) would reset — MMF's per-curve chaining forgiveness.
    func testAnalyzerSwipeWindowPerProfile() {
        func swipes(maxInterval: Double, minTickSpeed: Double) -> Double {
            var a = MMFTickAnalyzer()
            var t = 10.0, s = 0.0
            for _ in 0..<3 { // three 7-tick bursts, 0.5 s between burst starts
                for _ in 0..<7 {
                    s = a.feed(now: t, direction: 1,
                               swipeMaxInterval: maxInterval, swipeMinTickSpeed: minTickSpeed).swipes
                    t += 0.02
                }
                t += 0.5 - 7 * 0.02
            }
            return s
        }
        XCTAssertGreaterThanOrEqual(swipes(maxInterval: 0.6, minTickSpeed: 12), 2)
        XCTAssertEqual(swipes(maxInterval: 0.375, minTickSpeed: 16), 0)
    }
}
