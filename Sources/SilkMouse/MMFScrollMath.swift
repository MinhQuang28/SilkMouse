import Foundation

/// Mac-Mouse-Fix-style smooth-scroll math (v3, "Regular" smoothness / LowInertia — snappy, short
/// inertia tail). Clean-room re-derivation of the published model; only the *tuning constants* are
/// taken from MMF, the code is original. The "High"/HighInertia values are noted inline for easy
/// switching.
///
/// The model, per wheel notch:
///   1. `MMFTickAnalyzer` measures the tick rate (rolling average of the last 3 inter-tick gaps)
///      and counts consecutive "swipes" (bursts of ≥3 rapid ticks) for fast-scroll.
///   2. `MMFScrollTuning.pxPerTick` maps tick rate → pixels for this notch (a capped linear
///      sensitivity curve: minSens at ≤6.25 ticks/s rising to maxSens at 66.7 ticks/s).
///   3. `MMFSpeedupCurve` multiplies the notch distance exponentially once the user chains swipes
///      (MMF's "fast scroll" — flinging through long documents).
///   4. `MMFHybridPlan` re-plans the glide: remaining distance + new notch distance are covered by
///      a short bezier whose *initial slope equals the current glide speed* (speed smoothing — no
///      velocity jump on retarget), handed off to a physical drag curve v' = −a·v^b that decays to
///      `stopSpeed`. The drag tail is what gives MMF its signature inertial coast.
enum MMFScrollTuning {

    static let maxDuration = 1.5          // s — fast-scroll animations are compressed to this

    /// Tick-rate window (MMF ScrollAnalyzer): gaps outside [15 ms, 160 ms] are clamped; a gap
    /// above the max starts a new tick sequence.
    static let tickIntervalMin = 0.015
    static let tickIntervalMax = 0.160

    /// The acceleration curve is linear from (1/tickIntervalMax, minSens) to
    /// (1/tickIntervalMin, maxSens), clamped below, linearly extended above (MMF curvature 0).
    static func pxPerTick(tickHz: Double, minSens: Double, maxSens: Double) -> Double {
        let xMin = 1.0 / tickIntervalMax
        let xMax = 1.0 / tickIntervalMin
        let slope = (maxSens - minSens) / (xMax - xMin)
        return max(minSens, minSens + slope * (tickHz - xMin))
    }
}

/// The user-facing smoothness setting — three MMF-derived curve profiles.
enum ScrollSmoothness: String, Codable, Sendable, CaseIterable {
    case snappy   // MMF "Regular" as shipped — direct, minimal tail
    case balanced // MMF's softened-Regular alternative — smooth but responsive (default)
    case floaty   // MMF "High" — long trackpad-like coast

    var label: String {
        switch self {
        case .snappy:   return "Snappy (direct)"
        case .balanced: return "Balanced"
        case .floaty:   return "Floaty (trackpad)"
        }
    }
}

/// One complete curve + sensitivity tuning. The engine resolves a profile per tick from the
/// smoothness setting and any held modifier (Option → precise, Ctrl → quick).
struct MMFScrollProfile {
    let baseMsPerStep: Double     // s — base (gesture) portion target duration
    let speedSmoothing: Double    // bezier reach along the current-speed direction (0 = linear)
    let dragCoefficient: Double   // a in v' = −a·v^b
    let dragExponent: Double      // b
    let stopSpeed: Double         // px/s — drag tail ends here
    let minSensAnchors: (lo: Double, mid: Double, hi: Double) // px/tick at slider 0 / 0.5 / 1
    let maxSensAnchors: (lo: Double, mid: Double, hi: Double)
    let speedup: MMFSpeedupCurve? // fast-scroll multiplier; nil → never speeds up

    /// MMF "Regular" as shipped: linear base, steep drag — snappy and direct.
    static let snappy = MMFScrollProfile(
        baseMsPerStep: 0.140, speedSmoothing: 0.0, dragCoefficient: 15, dragExponent: 1.05,
        stopSpeed: 30, minSensAnchors: (30, 60, 120), maxSensAnchors: (90, 120, 180),
        speedup: .regular)

    /// The alternative Regular tuning noted in MMF's ScrollConfig ("still super responsive and
    /// much smoother feeling"): speed smoothing for velocity continuity, gentler drag.
    static let balanced = MMFScrollProfile(
        baseMsPerStep: 0.175, speedSmoothing: 0.15, dragCoefficient: 25, dragExponent: 0.9,
        stopSpeed: 30, minSensAnchors: (30, 60, 120), maxSensAnchors: (90, 120, 180),
        speedup: .regular)

    /// MMF "High": long, floaty trackpad-like coast; fast scroll kicks in a swipe earlier.
    static let floaty = MMFScrollProfile(
        baseMsPerStep: 0.220, speedSmoothing: 0.15, dragCoefficient: 40, dragExponent: 0.7,
        stopSpeed: 30, minSensAnchors: (60, 90, 150), maxSensAnchors: (120, 180, 240),
        speedup: MMFSpeedupCurve(swipeThreshold: 2, initialSpeedup: 1.33, exponentialSpeedup: 7.5))

    /// Option-modifier precise scrolling (MMF PreciseScroll): a few px per tick for fine control,
    /// snappy curve, no fast scroll. Slider-independent (constant anchors).
    static let precise = MMFScrollProfile(
        baseMsPerStep: 0.140, speedSmoothing: 0.0, dragCoefficient: 15, dragExponent: 1.05,
        stopSpeed: 50, minSensAnchors: (2, 2, 2), maxSensAnchors: (20, 20, 20),
        speedup: nil)

    /// Ctrl-modifier quick scrolling (MMF QuickScroll): each notch moves about half a window,
    /// long inertial coast, aggressive speedup. Sensitivity comes from the screen span under the
    /// cursor, not the slider (MMF scales to 85% of the screen as the "window size").
    static func quick(screenSpan: Double) -> MMFScrollProfile {
        let window = max(screenSpan, 400) * 0.85
        return MMFScrollProfile(
            baseMsPerStep: 0.300, speedSmoothing: 0.0, dragCoefficient: 30, dragExponent: 0.7,
            stopSpeed: 1,
            minSensAnchors: (window * 0.5, window * 0.5, window * 0.5),
            maxSensAnchors: (window * 1.5, window * 1.5, window * 1.5),
            speedup: MMFSpeedupCurve(swipeThreshold: 1, initialSpeedup: 2.0, exponentialSpeedup: 10))
    }

    static func forSmoothness(_ s: ScrollSmoothness) -> MMFScrollProfile {
        switch s {
        case .snappy:   return .snappy
        case .balanced: return .balanced
        case .floaty:   return .floaty
        }
    }

    /// (minSens, maxSens) px/tick for the speed slider (anchors at 0 / 0.5 / 1, linear extension
    /// past 1 — SilkMouse's slider runs 0.05…1.5) and the display under the cursor: maxSens gets
    /// a 10%-weighted scale by screen span relative to a 1080p baseline (MMF's screen scaling),
    /// so big displays fling proportionally farther.
    func sensitivity(slider: Double, screenSizeFactor: Double = 1.0) -> (minSens: Double, maxSens: Double) {
        func piecewise(_ a: (lo: Double, mid: Double, hi: Double)) -> Double {
            if slider <= 0 { return a.lo }
            if slider <= 0.5 { return a.lo + (a.mid - a.lo) * (slider / 0.5) }
            return a.mid + (a.hi - a.mid) * ((slider - 0.5) / 0.5) // continues linearly past 1.0
        }
        let screenSizeWeight = 0.1
        let maxSens = piecewise(maxSensAnchors)
        return (piecewise(minSensAnchors),
                maxSens * (1 - screenSizeWeight) + maxSens * screenSizeWeight * screenSizeFactor)
    }
}

/// MMF's fast-scroll multiplier: 1.0 until `threshold` consecutive swipes, then an exponential
/// ramp `a·1.1^((x−t)·c) + 1 − a` scaled so the first speedup step is `initialSpeedup`.
struct MMFSpeedupCurve {
    let threshold: Double
    private let a: Double
    private let c: Double

    /// LowInertia ("Regular") tuning: kicks in on the 4th chained swipe, ×1.33 then ~×2 per
    /// further swipe. (HighInertia uses swipeThreshold 2 — one swipe earlier.)
    static let regular = MMFSpeedupCurve(swipeThreshold: 3, initialSpeedup: 1.33, exponentialSpeedup: 7.5)

    init(swipeThreshold t: Int, initialSpeedup p: Double, exponentialSpeedup c: Double) {
        self.threshold = Double(t)
        self.c = c
        self.a = (p - 1.0) / (pow(1.1, c) - 1.0)
    }

    func factor(swipes: Double) -> Double {
        let x = swipes + 1 // MMF counts swipes from 0
        guard x >= threshold else { return 1.0 }
        return min(a * pow(1.1, (x - threshold) * c) + 1 - a, 100_000)
    }
}

/// Tick-rate + swipe analysis (MMF ScrollAnalyzer). Feed every wheel notch; returns the smoothed
/// tick rate that drives the acceleration curve, the consecutive-swipe count that drives fast
/// scroll, and whether this notch starts a fresh sequence (leftover glide distance is dropped).
struct MMFTickAnalyzer {

    struct Result {
        var tickHz: Double        // smoothed, clamped to [6.25, 66.7]
        var swipes: Double        // consecutive-swipe count (free-spin wheels count fractionally)
        var isSequenceStart: Bool // true → discard the previous glide's leftover distance
    }

    private var lastTickTime = 0.0
    private var lastDirection = 0
    private var consecutiveTicks = 0      // 0-based position within the current burst
    private var swipes = 0.0
    private var ticksInSequence = 0
    private var sequenceStartTime = 0.0
    private var gapWindow: [Double] = []  // rolling average, capacity 3

    private static let swipeMinTicks = 2         // previous burst needs a tick counter ≥ this
    private static let swipeMaxInterval = 0.375  // s between bursts to chain swipes (High: 0.6)
    private static let swipeMinTickSpeed = 16.0  // ticks/s averaged over the sequence (High: 12)
    private static let freeSpinTicksPerSwipe = 11.0

    mutating func reset() {
        lastTickTime = 0
        lastDirection = 0
        consecutiveTicks = 0
        swipes = 0
        ticksInSequence = 0
        sequenceStartTime = 0
        gapWindow.removeAll()
    }

    /// `direction`: any stable key that changes on axis or sign flips (e.g. ±1 / ±2).
    mutating func feed(now: Double, direction: Int) -> Result {
        if direction != lastDirection {
            reset()
            lastDirection = direction
        }

        let rawGap = max(now - lastTickTime, MMFScrollTuning.tickIntervalMin)
        ticksInSequence += 1

        if rawGap > MMFScrollTuning.tickIntervalMax {
            // First tick of a new burst — decide whether it chains the swipe count.
            let previousBurstLongEnough = consecutiveTicks >= MMFTickAnalyzer.swipeMinTicks
            let closeEnough = rawGap <= MMFTickAnalyzer.swipeMaxInterval
            let sequenceElapsed = now - sequenceStartTime
            let fastEnough = sequenceElapsed > 0
                && Double(ticksInSequence) / sequenceElapsed >= MMFTickAnalyzer.swipeMinTickSpeed
            if previousBurstLongEnough, closeEnough, fastEnough, lastTickTime > 0 {
                swipes += 1
            } else {
                swipes = 0
                sequenceStartTime = now
                ticksInSequence = 0
            }
            consecutiveTicks = 0
            gapWindow.removeAll()
        } else {
            consecutiveTicks += 1
            gapWindow.append(rawGap)
            if gapWindow.count > 3 { gapWindow.removeFirst() }
        }

        // Free-spinning wheels never pause between "swipes"; credit fractional swipes instead so
        // fast scroll still engages after ~a wheel-turn of continuous ticks.
        if Double(consecutiveTicks) >= MMFTickAnalyzer.freeSpinTicksPerSwipe {
            swipes += 1.0 / MMFTickAnalyzer.freeSpinTicksPerSwipe
        }

        lastTickTime = now

        let smoothedGap: Double
        if consecutiveTicks == 0 {
            smoothedGap = MMFScrollTuning.tickIntervalMax // single/slow ticks sit at the curve floor
        } else {
            smoothedGap = min(gapWindow.reduce(0, +) / Double(gapWindow.count),
                              MMFScrollTuning.tickIntervalMax)
        }

        return Result(tickHz: 1.0 / smoothedGap,
                      swipes: swipes,
                      isSequenceStart: consecutiveTicks == 0 && swipes == 0)
    }
}

/// Quadratic bezier through (0,0) → p1 → (1,1) on normalized time/distance, used as the glide's
/// gesture portion. p1 sits `speedSmoothing` along the unit vector of the current speed, which
/// makes the curve's initial slope equal the running glide speed — the "speed smoothing" that
/// removes per-notch velocity jumps.
struct MMFSpeedBezier {
    let p1x: Double
    let p1y: Double

    /// `v0` in normalized units: (px/s) · duration / distance. 0 → pure ease-in from rest.
    init(normalizedInitialSpeed v0: Double, smoothing: Double) {
        // Direction of the current speed in normalized coords: dx ∝ 1, dy ∝ v0.
        let norm = (1 + v0 * v0).squareRoot()
        p1x = smoothing * (1 / norm)
        p1y = smoothing * (v0 / norm)
    }

    func x(atT t: Double) -> Double { t * (2 * p1x * (1 - t) + t) }
    func y(atT t: Double) -> Double { t * (2 * p1y * (1 - t) + t) }

    /// dy/dx — the normalized speed at parameter t.
    func slope(atT t: Double) -> Double {
        let dx = 2 * p1x + 2 * t * (1 - 2 * p1x)
        let dy = 2 * p1y + 2 * t * (1 - 2 * p1y)
        return dx == 0 ? .infinity : dy / dx
    }

    /// y as a function of x (analytic t-from-x for the quadratic; p1x < 0.5 keeps x monotonic).
    func y(atX x: Double) -> Double {
        let a = 1 - 2 * p1x
        let t: Double
        if abs(a) < 1e-12 {
            t = x // p1x == 0.5 → x(t) = t
        } else {
            t = (-p1x + (p1x * p1x + a * x).squareRoot()) / a
        }
        return y(atT: min(max(t, 0), 1))
    }
}

/// Closed-form drag decay v' = −a·v^b from `v0` down to `stopSpeed` (b ≠ 1, 2 — MMF High uses 0.7).
/// distance(t) = (v0^{2−b} − v(t)^{2−b}) / (a(2−b)),  v(t) = (v0^{1−b} − a(1−b)t)^{1/(1−b)}.
struct MMFDragSegment {
    let a: Double
    let b: Double
    let v0: Double
    let vStop: Double
    let duration: Double
    let distance: Double

    /// From an initial speed: coast from `v0` until decayed to `stopSpeed`.
    init?(initialSpeed v0: Double, a: Double, b: Double, stopSpeed: Double) {
        guard v0 > stopSpeed else { return nil }
        self.a = a; self.b = b; self.v0 = v0; self.vStop = stopSpeed
        duration = (pow(v0, 1 - b) - pow(stopSpeed, 1 - b)) / (a * (1 - b))
        distance = (pow(v0, 2 - b) - pow(stopSpeed, 2 - b)) / (a * (2 - b))
    }

    /// From a target distance: solve the v0 whose full decay covers exactly `distance` px
    /// (fallback when the incoming speed already out-coasts the requested distance).
    init(distance: Double, a: Double, b: Double, stopSpeed: Double) {
        let v0 = pow(distance * a * (2 - b) + pow(stopSpeed, 2 - b), 1 / (2 - b))
        self.init(initialSpeed: v0, a: a, b: b, stopSpeed: stopSpeed)!
    }

    func speed(at t: Double) -> Double {
        let core = pow(v0, 1 - b) - a * (1 - b) * t
        let stopCore = pow(vStop, 1 - b)
        // core runs from pow(v0, 1−b) to stopCore: downward for b < 1, upward for b > 1 (the
        // exponent 1/(1−b) flips sign with it). Clamp at stopCore either way for t ≥ duration.
        return pow(b < 1 ? max(core, stopCore) : min(core, stopCore), 1 / (1 - b))
    }

    func distance(at t: Double) -> Double {
        guard t < duration else { return distance }
        return (pow(v0, 2 - b) - pow(speed(at: t), 2 - b)) / (a * (2 - b))
    }
}

/// One glide: bezier gesture portion (up to the transition point) + drag coast, covering exactly
/// `total` px in `duration` s. Rebuilt on every wheel notch with the then-current speed.
struct MMFHybridPlan {
    let total: Double            // px, > 0
    let duration: Double         // s
    let transitionTime: Double   // s — bezier portion ends here
    let transitionDistance: Double
    private let bezier: MMFSpeedBezier?
    private let bezierDuration: Double // full (unclipped) bezier time scale
    private let drag: MMFDragSegment?
    private let scale: Double          // total / raw curve end — the transition search stops within
                                       // a distance epsilon; normalizing makes the end land exactly

    /// - Parameters:
    ///   - distance: px to cover (> 0)
    ///   - initialSpeed: current glide speed in px/s (≥ 0); the plan starts at this speed
    ///   - profile: curve shape (base duration, speed smoothing, drag, stop speed)
    init(distance: Double, initialSpeed: Double, profile: MMFScrollProfile = .balanced) {
        let baseDuration = profile.baseMsPerStep
        let smoothing = profile.speedSmoothing
        let dragCoefficient = profile.dragCoefficient
        let dragExponent = profile.dragExponent
        let stopSpeed = profile.stopSpeed

        total = distance
        bezierDuration = baseDuration
        let curve = MMFSpeedBezier(normalizedInitialSpeed: initialSpeed * baseDuration / distance,
                                   smoothing: smoothing)

        // Combined distance if the drag tail is attached at bezier parameter t: the bezier covers
        // y(t)·distance, then the drag coasts from the speed at t.
        func speedAt(_ t: Double) -> Double { curve.slope(atT: t) * distance / baseDuration }
        func combined(_ t: Double) -> Double {
            let base = curve.y(atT: t) * distance
            guard let d = MMFDragSegment(initialSpeed: speedAt(t), a: dragCoefficient,
                                         b: dragExponent, stopSpeed: stopSpeed) else { return base }
            return base + d.distance
        }

        // Find the latest attachment point where bezier + drag covers exactly `distance`:
        // coarse scan from t=1 downward, then bisection (MMF BezierHybridCurve).
        let epsilon = 0.2
        var t: Double? = nil
        var lo = 0.0, hi = 1.0
        var bracketed = false
        for k in 0...10 {
            let tk = 1.0 - Double(k) / 10.0
            let c = combined(tk)
            if abs(c - distance) < epsilon { t = tk; break }
            if c <= distance { lo = tk; hi = tk + 0.1; bracketed = true; break }
        }
        if t == nil, bracketed {
            for _ in 0..<64 {
                let mid = (lo + hi) / 2
                let c = combined(mid)
                if abs(c - distance) < epsilon { t = mid; break }
                if c < distance { lo = mid } else { hi = mid }
            }
            if t == nil { t = (lo + hi) / 2 }
        }

        if let t {
            let exitSpeed = speedAt(t)
            let dragSeg = MMFDragSegment(initialSpeed: exitSpeed, a: dragCoefficient,
                                         b: dragExponent, stopSpeed: stopSpeed)
            bezier = curve
            transitionTime = curve.x(atT: t) * baseDuration
            transitionDistance = curve.y(atT: t) * distance
            drag = dragSeg
            duration = transitionTime + (dragSeg?.duration ?? 0)
            let rawEnd = transitionDistance + (dragSeg?.distance ?? 0)
            scale = rawEnd > 0 ? distance / rawEnd : 1
        } else {
            // Even attaching at t=0 over-coasts (huge incoming speed, small distance): drag-only
            // plan that covers exactly `distance`. The incoming speed is dropped, like MMF.
            let dragSeg = MMFDragSegment(distance: distance, a: dragCoefficient,
                                         b: dragExponent, stopSpeed: stopSpeed)
            bezier = nil
            transitionTime = 0
            transitionDistance = 0
            drag = dragSeg
            duration = dragSeg.duration
            scale = distance / dragSeg.distance
        }
    }

    /// Distance covered `t` seconds in (monotonic, distance(duration) == total).
    func distance(at t: Double) -> Double {
        if t >= duration { return total }
        if t <= transitionTime, let bezier {
            return bezier.y(atX: t / bezierDuration) * total * scale
        }
        guard let drag else { return total }
        return (transitionDistance + drag.distance(at: t - transitionTime)) * scale
    }

    /// Instantaneous speed (px/s) — feeds the next notch's speed smoothing.
    func speed(at t: Double) -> Double {
        if t >= duration { return 0 }
        if t <= transitionTime, let bezier {
            let a = 1 - 2 * bezier.p1x
            let x = t / bezierDuration
            let tp = abs(a) < 1e-12 ? x : (-bezier.p1x + (bezier.p1x * bezier.p1x + a * x).squareRoot()) / a
            return bezier.slope(atT: min(max(tp, 0), 1)) * total * scale / bezierDuration
        }
        guard let drag else { return 0 }
        return drag.speed(at: t - transitionTime) * scale
    }

    /// True once `t` is past the bezier portion — the coast that gets labeled as momentum.
    func inDragPhase(at t: Double) -> Bool { t > transitionTime }
}
