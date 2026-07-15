import AppKit
import CoreGraphics
import QuartzCore

/// Smooth scrolling with Mac Mouse Fix's scroll model (v3 "Regular" smoothness / LowInertia —
/// snappy, short inertia tail), which is the feel this app targets in Smooth mode.
///
/// Smooth mode (wheel notches): every notch re-plans ONE glide (`MMFHybridPlan`, see
/// MMFScrollMath.swift): tick rate → px for this notch (acceleration curve), + the previous glide's
/// unfinished distance, covered by a short bezier whose initial slope equals the current glide
/// speed (speed smoothing — no velocity jump on retarget) that hands off to a physical drag coast
/// v' = −a·v^b down to a stop speed. Chained fast swipes multiply the distance exponentially
/// (MMF "fast scroll"). The drag portion is labeled with momentum phases (like MMF's trackpad
/// simulation) once the wheel has been quiet past the tick window, so phase-aware apps (Safari…)
/// treat the coast natively; while ticks keep arriving everything stays one gesture stream.
///
/// Smooth-step mode and hi-res pixel mice instead use a critically-damped spring toward an
/// accumulated target (state = remaining distance + velocity, see `springAdvance`): crisp
/// per-notch steps, exact stop, no coast.
///
/// Smoothness plumbing:
///   • the glide is paced by a `CADisplayLink` on its own thread+run-loop (paused when idle — zero
///     CPU — and never competing with the event tap); dt comes from `targetTimestamp` (see `step`).
///   • each frame carries its precise sub-pixel delta in the fixed-point field, so slow scrolls don't
///     visibly step between whole pixels.
/// Shared state is guarded by `lock`; `NSObject` base is only needed for the link's target selector.
final class ScrollAnimator: NSObject {

    /// Marks our own synthetic scroll events (via `.eventSourceUserData`) so the tap skips them.
    static let syntheticTag: Int64 = 0x534C_4B4D // "SLKM"

    private let lock = NSLock()
    private var remV = 0.0     // pixels still to emit, vertical (the running scroll target)
    private var remH = 0.0     // pixels still to emit, horizontal
    private var velV = 0.0     // spring velocity, px/s (same sign as rem while gliding)
    private var velH = 0.0
    private var carryV = 0.0   // sub-pixel carry for the integer pixel field
    private var carryH = 0.0
    private var running = false
    private var lastTime = 0.0
    private var lastMotionTime = 0.0   // last frame/tick that actually moved — drives the gesture hold
    private var lastStepTime = 0.0     // last time step() actually ran — feeds the stall watchdog
    private var stallRetries = 0      // consecutive stall re-wakes; escalates to a full rebuild
    private let stallWindow = 0.25    // s of `running` with no frame before a tick re-issues the wake
    private var phaseStarted = false   // whether the CURRENT stream has emitted its began event yet
    private let gestureHold = 0.12     // s to keep the stream (and link) alive after motion settles, so
                                       // consecutive notches continue ONE gesture instead of thrashing
                                       // ended→began each notch (a cause of the hitchy feel)
    private let source = CGEventSource(stateID: .hidSystemState)

    /// Which event stream the glide is currently emitting — the two phases of a real trackpad scroll.
    private enum Stream { case idle, gesture, momentum }
    private var mode = Stream.idle
    private var momentumInterrupted = false // tick landed mid-coast → close momentum, reopen a gesture

    // Undocumented gesture/momentum-phase fields + values. Tagging our synthetic events as a coherent
    // stream (began → changed → ended, momentum began → continue → ended) is what makes phase-aware
    // apps like Safari scroll smoothly instead of juddering on each discrete pixel event.
    private let scrollPhaseField = CGEventField(rawValue: 99)!    // kCGScrollWheelEventScrollPhase
    private let momentumPhaseField = CGEventField(rawValue: 123)! // kCGScrollWheelEventMomentumPhase
    private let phaseBegan: Int64 = 1
    private let phaseChanged: Int64 = 2
    private let phaseEnded: Int64 = 4
    private let momentumBegan: Int64 = 1
    private let momentumContinue: Int64 = 2
    private let momentumEnded: Int64 = 3

    private var displayLink: CADisplayLink?   // created/used only on the animator thread
    private var linkRunLoop: CFRunLoop?        // that thread's run loop, for cross-thread wake-ups
    private var thread: Thread?
    private var linkDisplayID: CGDirectDisplayID = 0    // display the live link paces (0 = unknown)
    private var pendingDisplayID: CGDirectDisplayID = 0 // display the NEXT link should pace

    // Spring tuning (Smooth-step + hi-res pixel paths).
    private let pixelsPerLine = 30.0  // Smooth-step: pixels per "line" of the fixed N-line notch step
    private var omega = 26.0          // rad/s — current spring stiffness (set per tick by the mode)
    private let omegaSmooth = 26.0    // hi-res pixels: settles a burst in ~0.18 s — trackpad-like
    private let omegaStep = 40.0      // crisp: ~0.12 s so each notch lands as a discrete step
    private let maxRemaining = 6000.0 // px clamp so a fast spin can't accumulate an absurd target
    private let stopDistance = 0.1    // px; together with `stopSpeed`, flushes the final sliver
    private let stopSpeed = 20.0      // px/s; below BOTH thresholds the glide settles

    // MMF glide (Smooth wheel mode) — see MMFScrollMath.swift. One 1-D plan at a time (a wheel
    // ticks one axis per event; an axis or direction change starts a fresh plan from rest).
    private var mmfAnalyzer = MMFTickAnalyzer()
    private var plan: MMFHybridPlan?
    private var planStart = 0.0      // when the CURRENT plan started (reset on every notch)
    private var planRate = 1.0       // >1 compresses a fast-scroll plan into `maxDuration` wall time
    private var planPrevTime = 0.0   // plan-time of the previous frame (momentum labeling needs it)
    private var planEmitted = 0.0    // px of the plan already posted (absolute)
    private var planAxisIsV = true
    private var planSign = 1.0
    private let planMaxDistance = 100_000.0 // px cap (fast scroll is exponential; MMF caps similarly)

    // Hi-res pixel path (addPixels) — free-spin safety.
    private var pxInputSpeed = 0.0     // smoothed incoming px/s of the raw device stream
    private var pxLastInputTime = 0.0
    private static let pixelMaxRemaining = 2000.0 // px backlog cap (wheel spring keeps 6000)
    // Hi-res glides emit PHASE-LESS continuous events (gesture/momentum fields zero), matching what
    // the mouse itself sends. Phase-tagged streams let apps rubber-band PAST the page edge — a fast
    // free-spin overscrolls into blank space and snaps back ("content vanishes, then reappears").
    // Phase-less events clamp hard at the edge like native mouse scrolling. Wheel glides keep the
    // phased trackpad stream (per-notch smoothness in phase-aware apps).
    private var phaselessStream = false

    // Hard ceiling on the emitted scroll speed, both glide models. Whatever the input does — a
    // flywheel at full spin, a fast-scroll multiplied wheel burst — the view never moves faster
    // than this; the excess drains later (plan/spring keep the backlog) or is dropped at the
    // backlog clamps. ~6 screenfuls per second: flings through long pages while staying below
    // the rates that blank-render in heavy apps (6000 felt too slow on long documents).
    private static let maxOutputSpeed = 12_000.0 // px/s

    /// Gain for hi-res pixel input. The slider's perceptual curve (0.5 → 1.0 = native, capped ×3)
    /// applies fully to slow/deliberate scrolling; above a knee, the EXCESS input speed passes at
    /// 1:1 — a free-spinning flywheel (MX Master 3 SmartShift) carries its own hardware momentum,
    /// and multiplying it flings the view far past the page. The soft-knee keeps output speed
    /// MONOTONIC in input speed (out = g·min(in, knee) + max(in − knee, 0)): a plain speed-fade
    /// here made the output ACCELERATE while the flywheel decayed through the fade band — the
    /// "speeds up mid-coast" artifact. Slow-down gains (< 1) apply as-is; they can't overshoot.
    static func pixelGain(slider: Double, inputSpeed: Double) -> Double {
        let full = min(pow(slider / 0.5, 1.7), 3.0)
        guard full > 1, inputSpeed > pixelGainKnee else { return full }
        return (full * pixelGainKnee + (inputSpeed - pixelGainKnee)) / inputSpeed
    }
    private static let pixelGainKnee = 800.0 // px/s of input speed that still gets the full gain

    /// Pure brake predicate (extracted so it's unit-testable): a reversed notch is consumed as a
    /// brake only when the input has been quiet past the tick window (it's a coast, not active
    /// back-and-forth scrolling) AND the glide is still moving fast enough that stopping it is
    /// what the user means (a nearly-settled crawl reverses normally instead).
    static func shouldBrakeOnReversal(silence: Double, speed: Double) -> Bool {
        return silence >= MMFScrollTuning.tickIntervalMax && speed > 150
    }

    /// Caller must hold `lock`.
    private func clearPlanLocked() {
        plan = nil
        planEmitted = 0
        planPrevTime = 0
        planRate = 1
    }

    /// Feed a wheel notch (line deltas, already direction-corrected). In Smooth-step mode each notch
    /// is a fixed `lines`-line spring step with a crisp ease and no coast; in Smooth mode the notch
    /// re-plans an MMF hybrid glide. The caller resolves `profile` (smoothness setting or a held
    /// modifier) and `minSens`/`maxSens` (speed slider + screen scaling); `accelerate` = fast scroll.
    func addTick(lineV: Double, lineH: Double, stepped: Bool, lines: Int,
                 profile: MMFScrollProfile, minSens: Double, maxSens: Double, accelerate: Bool) {
        let now = CACurrentMediaTime()

        if stepped {
            let dist = Double(lines) * pixelsPerLine
            lock.lock()
            omega = omegaStep
            phaselessStream = false
            clearPlanLocked()
            if mode == .momentum { momentumInterrupted = true; mode = .gesture; phaseStarted = false }
            // Reversing direction: drop the opposing remainder AND velocity so the flip is immediate.
            if lineV != 0, (lineV > 0) != (remV > 0) { remV = 0; carryV = 0; velV = 0 }
            if lineH != 0, (lineH > 0) != (remH > 0) { remH = 0; carryH = 0; velH = 0 }
            remV = clampDist(remV + lineV * dist)
            remH = clampDist(remH + lineH * dist)
            lastMotionTime = now
            let action = wakeActionLocked(now: now)
            lock.unlock()
            runWakeAction(action)
            return
        }

        let axisIsV = lineV != 0
        let sign: Double = axisIsV ? (lineV > 0 ? 1 : -1) : (lineH > 0 ? 1 : -1)

        lock.lock()
        phaselessStream = false
        // MMF-style brake: an opposite notch while the glide is COASTING (input quiet past the
        // tick window, still visibly moving) stops the page dead instead of scrolling back — the
        // notch is consumed as a brake. Further opposite notches then scroll normally (the plan is
        // gone and the analyzer resets on the direction change). Reversals during active ticking
        // (gaps < the tick window) are not brakes — they flip direction immediately as before.
        if let p = plan, planAxisIsV == axisIsV, planSign != sign {
            let planTime = min((now - planStart) * planRate, p.duration)
            if ScrollAnimator.shouldBrakeOnReversal(silence: now - planStart,
                                                    speed: p.speed(at: planTime) * planRate) {
                clearPlanLocked()
                lastMotionTime = now // hold the stream open; the finish path closes it cleanly
                lock.unlock()
                return
            }
        }
        // The plan drives Smooth motion; any spring leftovers (mode switch mid-glide) would double-post.
        remV = 0; remH = 0; velV = 0; velH = 0
        // A tick mid-coast "catches" the glide, like touching a coasting trackpad: close the momentum
        // stream (posted by the link thread) and reopen a gesture. Velocity carries over — no stutter.
        if mode == .momentum { momentumInterrupted = true; mode = .gesture; phaseStarted = false }

        // Tick rate → px for this notch; chained fast swipes multiply it (MMF fast scroll).
        let analysis = mmfAnalyzer.feed(now: now, direction: Int(sign) * (axisIsV ? 1 : 2))
        var px = MMFScrollTuning.pxPerTick(tickHz: analysis.tickHz, minSens: minSens, maxSens: maxSens)
        if accelerate, let speedup = profile.speedup { px *= speedup.factor(swipes: analysis.swipes) }

        // Re-plan: unfinished distance rolls into the new glide (dropped at a sequence start, like
        // MMF) and the new plan takes off at the current glide speed — that continuity is the
        // "speed smoothing" that makes consecutive notches feel like one push.
        var leftover = 0.0
        var v0 = 0.0
        if let p = plan, planAxisIsV == axisIsV, planSign == sign {
            let planTime = min((now - planStart) * planRate, p.duration)
            if !analysis.isSequenceStart { leftover = max(p.total - planEmitted, 0) }
            v0 = p.speed(at: planTime) * planRate
        }
        let p = MMFHybridPlan(distance: min(leftover + px, planMaxDistance), initialSpeed: v0,
                              profile: profile)
        plan = p
        planStart = now
        planPrevTime = 0
        planEmitted = 0
        planRate = max(1.0, p.duration / MMFScrollTuning.maxDuration)
        planAxisIsV = axisIsV
        planSign = sign
        if analysis.isSequenceStart { carryV = 0; carryH = 0 }
        lastMotionTime = now
        let action = wakeActionLocked(now: now)
        lock.unlock()

        runWakeAction(action)
    }

    /// Feed raw pixel deltas from a high-res "continuous" mouse (e.g. Keychron M6) that reports pixel
    /// motion but has no hardware flywheel, so macOS renders it choppily. Accumulating the pixels into
    /// the same ease-to-target glide smooths the bursts the way the notch path smooths wheel clicks —
    /// total distance is preserved (scaled by `speed`), just spread over the ease window.
    func addPixels(pxV: Double, pxH: Double, speed: Double) {
        let now = CACurrentMediaTime()

        lock.lock()
        phaselessStream = true
        // Measure the incoming stream's speed (px/s, exponentially smoothed) — the free-spin
        // detector. A long idle gap starts the estimate fresh.
        let mag = max(abs(pxV), abs(pxH))
        let gap = now - pxLastInputTime
        pxLastInputTime = now
        let inst = mag / min(max(gap, 0.001), 0.2)
        pxInputSpeed = gap > 0.2 ? inst : pxInputSpeed * 0.7 + inst * 0.3
        let gain = ScrollAnimator.pixelGain(slider: speed, inputSpeed: pxInputSpeed)
        omega = omegaSmooth
        clearPlanLocked()
        if mode == .momentum { momentumInterrupted = true; mode = .gesture; phaseStarted = false }
        if pxV != 0, (pxV > 0) != (remV > 0) { remV = 0; carryV = 0; velV = 0 }
        if pxH != 0, (pxH > 0) != (remH > 0) { remH = 0; carryH = 0; velH = 0 }
        // Tighter clamp than the wheel paths: when the user stops a free-spinning wheel by hand,
        // whatever is queued here still drains — keep that "extra glide" bounded to ~a screenful.
        remV = min(max(remV + pxV * gain, -ScrollAnimator.pixelMaxRemaining), ScrollAnimator.pixelMaxRemaining)
        remH = min(max(remH + pxH * gain, -ScrollAnimator.pixelMaxRemaining), ScrollAnimator.pixelMaxRemaining)
        // Pixel input never coasts: a hi-res mouse delivers each physical notch as a BURST of events
        // a few ms apart, so inter-event gaps can't tell a flick from one slow notch. The spring's
        // own tail already smooths the end of a fast hi-res swipe.
        lastMotionTime = now
        let action = wakeActionLocked(now: now)
        lock.unlock()

        runWakeAction(action)
    }

    private func clampDist(_ v: Double) -> Double { max(-maxRemaining, min(maxRemaining, v)) }

    /// What an input event must do to get the glide running, decided under `lock` (caller holds it),
    /// executed after unlock by `runWakeAction`.
    private enum WakeAction { case none, wake, rebuild }

    private func wakeActionLocked(now: Double) -> WakeAction {
        if !running {
            running = true; lastTime = now; mode = .gesture; phaseStarted = false
            lastStepTime = now // arm the watchdog from the wake, not from a stale previous glide
            stallRetries = 0
            return .wake
        }
        // Stall watchdog: `running` yet no frame for a whole `stallWindow` means the link is
        // stranded — paused by some race we lost, or invalidated by the OS without any notification
        // (sleep/display-change edge cases keep finding new shapes). During a healthy glide step()
        // runs every frame, so this can't false-positive. Re-issue the (idempotent) wake; if that
        // keeps failing, escalate to a full link-thread rebuild. Either way the user's next tick
        // heals scroll in ≤ stallWindow instead of it staying dead until a Space/app switch.
        if now - lastStepTime > stallWindow {
            lastStepTime = now // re-arm — one recovery attempt per window
            stallRetries += 1
            return stallRetries >= 3 ? .rebuild : .wake
        }
        return .none
    }

    private func runWakeAction(_ action: WakeAction) {
        switch action {
        case .none: break
        case .wake: startOrWake()
        case .rebuild: handleWake() // drops the stuck backlog; the very next tick rebuilds fresh
        }
    }

    /// Close any in-flight glide/gesture immediately and reset, so the NEXT scroll opens a fresh
    /// `began`. A smooth gesture that spans a Space switch gets orphaned (the new Space's window never
    /// saw its `began`) and is ignored until a fresh one starts — forcing that fresh start here is the
    /// fix. `running = false` is the part that matters (next tick becomes `wasIdle`); the posted `ended`
    /// just closes the gesture cleanly in the app we were scrolling.
    func endGestureNow() {
        lock.lock()
        let rl = linkRunLoop
        // Which stream (if any) needs closing. An interrupted coast whose momentum-ended hasn't been
        // posted yet (momentumInterrupted pending, mode already flipped back to .gesture by the tick)
        // still counts as an open momentum stream — dropping it would leave the app's momentum
        // sequence unterminated.
        let openStream = momentumInterrupted ? Stream.momentum : (phaseStarted ? mode : Stream.idle)
        running = false
        mode = .idle
        phaseStarted = false
        momentumInterrupted = false
        remV = 0; remH = 0; carryV = 0; carryH = 0; velV = 0; velH = 0
        phaselessStream = false
        clearPlanLocked()
        mmfAnalyzer.reset()
        lock.unlock()

        guard openStream != .idle, let rl else { return } // nothing open → nothing to close
        // The block runs on the link thread (rl is the run loop `runLoop()` drives), the same thread
        // as step()/post() — so touching `post()` and `displayLink` here is single-threaded and safe.
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            // Re-check state under lock: a tick can slip in between endGestureNow's unlock and
            // this block being enqueued. That tick sees running == false, sets it true and
            // enqueues an un-pause block — which then runs BEFORE this one (enqueue order), so
            // pausing unconditionally here would strand the link paused while running == true.
            // Every later tick would see wasIdle == false and never wake the link again → smooth
            // scroll dead until the next Space/app switch. So: pause only while still idle. (A
            // tick landing after this check enqueues its un-pause behind us — still awake.)
            // Likewise, if the new stream already emitted its `began`, posting `ended` now would
            // spuriously close it mid-flight — skip it; the old stream is abandoned either way.
            self.lock.lock()
            let newStreamBegan = self.phaseStarted
            let stillIdle = !self.running
            let link = self.displayLink // read under lock (handleWake/runLoop write it)
            self.lock.unlock()
            if !newStreamBegan {
                if openStream == .momentum {
                    self.post(intV: 0, intH: 0, preciseV: 0, preciseH: 0,
                              gesturePhase: 0, momentumPhase: self.momentumEnded)
                } else {
                    self.post(intV: 0, intH: 0, preciseV: 0, preciseH: 0, gesturePhase: self.phaseEnded)
                }
            }
            if stillIdle { link?.isPaused = true }
        }
        CFRunLoopWakeUp(rl)
    }

    /// Pure, frame-rate-independent critically-damped-spring step (extracted so it's unit-testable).
    /// State per axis = (remaining distance to target, velocity). A new notch only grows `remaining`;
    /// velocity carries over — that continuity is what kills per-notch pulsing. Uses the exact
    /// closed-form solution x(t) = (x₀ + Bt)·e^(−ωt) with B = ωx₀ − v₀ (x = remaining, v = −ẋ), so
    /// any frame-rate partitioning of the same wall time yields identical motion. Flushes the final
    /// sliver once BOTH remaining and velocity are negligible, and clamps at the target if incoming
    /// velocity would overshoot (a reversal artifact becomes a clean stop, never a bounce-back).
    static func springAdvance(remaining: Double, velocity: Double, dt: Double, omega: Double,
                              stopDistance: Double, stopSpeed: Double)
        -> (delta: Double, remaining: Double, velocity: Double) {
        if abs(remaining) < stopDistance, abs(velocity) < stopSpeed { return (remaining, 0, 0) }
        if remaining == 0 { return (0, 0, 0) } // fast-but-nowhere-to-go: settle (unreachable in practice)
        let b = omega * remaining - velocity
        let decay = exp(-omega * dt)
        var rem1 = (remaining + b * dt) * decay
        var vel1 = (velocity + omega * b * dt) * decay
        if rem1 == 0 || (rem1 > 0) != (remaining > 0) { rem1 = 0; vel1 = 0 } // crossed target → stop dead
        return (remaining - rem1, rem1, vel1)
    }

    /// Display currently under the mouse pointer, via thread-safe CoreGraphics only (querying
    /// AppKit's NSScreen off the main thread is unsupported — that resolution happens in `runLoop`).
    private static func displayUnderCursor() -> CGDirectDisplayID {
        guard let loc = CGEvent(source: nil)?.location else { return 0 }
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(loc, 1, &display, &count) == .success, count > 0 else { return 0 }
        return display
    }

    /// Spawn the animator thread. Caller must hold `lock` (publishes `thread` before unlocking so a
    /// concurrent wake can't double-spawn); caller starts the returned thread AFTER unlocking.
    private func spawnLinkThreadLocked() -> Thread {
        let t = Thread { [weak self] in self?.runLoop() }
        t.name = "com.silkmouse.scroll-animator"
        t.qualityOfService = .userInteractive
        thread = t
        return t
    }

    /// Spin up the animator thread on first use, or un-pause its display link on later glides.
    /// A glide starting on a DIFFERENT display than the link paces (mixed-refresh setups: 120 Hz
    /// MBP + 60 Hz external) rebuilds the link for the cursor's display — glide state is preserved,
    /// only the pacing clock changes. `thread`/`linkRunLoop` are read+written under `lock` so a
    /// failed start (see `runLoop`) can be retried by the next tick without racing.
    private func startOrWake() {
        let target = ScrollAnimator.displayUnderCursor()
        lock.lock()
        if thread == nil {
            pendingDisplayID = target
            let t = spawnLinkThreadLocked()
            lock.unlock()
            t.start()
            return
        }
        // Retarget to the cursor's display. Only reached from idle (or a stalled link), so the old
        // link isn't mid-glide — tear it down, keep rem/vel/running, spawn a replacement that
        // drains the same state at the right refresh rate.
        if target != 0, linkDisplayID != 0, target != linkDisplayID {
            pendingDisplayID = target
            let rl = linkRunLoop
            let link = displayLink
            displayLink = nil; linkRunLoop = nil; linkDisplayID = 0
            let t = spawnLinkThreadLocked() // replaces `thread` → old thread's zombie guard trips
            lock.unlock()
            if let rl {
                CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) {
                    link?.invalidate()
                    CFRunLoopStop(rl)
                }
                CFRunLoopWakeUp(rl)
            }
            t.start()
            return
        }
        let rl = linkRunLoop
        lock.unlock()
        // Toggle `isPaused` on the link's own thread (CADisplayLink isn't documented thread-safe).
        guard let rl else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.displayLink?.isPaused = false
        }
        CFRunLoopWakeUp(rl)
    }

    /// macOS invalidates the display link across sleep/wake: the link thread stays alive but its
    /// CADisplayLink (bound to the pre-sleep display session) stops firing, so `step` never runs,
    /// `running` stays stuck true, and smooth scroll dies permanently. Tear the old link+thread down
    /// so the next tick rebuilds a fresh link bound to the current display.
    func handleWake() {
        lock.lock()
        let rl = linkRunLoop
        let link = displayLink
        // Same open-stream logic as endGestureNow: close whatever the teardown orphans, so the
        // frontmost app doesn't carry an unterminated gesture/momentum sequence across the nap.
        let openStream = momentumInterrupted ? Stream.momentum : (phaseStarted ? mode : Stream.idle)
        displayLink = nil
        linkRunLoop = nil
        thread = nil
        linkDisplayID = 0
        running = false
        remV = 0; remH = 0; carryV = 0; carryH = 0; velV = 0; velH = 0
        phaselessStream = false
        clearPlanLocked()
        mmfAnalyzer.reset()
        mode = .idle
        phaseStarted = false
        momentumInterrupted = false
        stallRetries = 0
        lock.unlock()

        guard let rl else { return } // no thread yet ⇒ nothing posted yet ⇒ openStream is .idle too
        // Invalidate the stale link and stop its run loop on its own thread (so the thread exits and
        // the next addTick spins up a clean replacement). Post the closing event there too — post()
        // stays single-threaded (link thread only). Best-effort: if the loop already stopped, the
        // block never runs and the stream stays unterminated, which apps tolerate (LOW, cosmetic).
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            if let self, openStream != .idle {
                if openStream == .momentum {
                    self.post(intV: 0, intH: 0, preciseV: 0, preciseH: 0,
                              gesturePhase: 0, momentumPhase: self.momentumEnded)
                } else {
                    self.post(intV: 0, intH: 0, preciseV: 0, preciseH: 0, gesturePhase: self.phaseEnded)
                }
            }
            link?.invalidate()
            CFRunLoopStop(rl)
        }
        CFRunLoopWakeUp(rl)
    }

    private func runLoop() {
        lock.lock()
        let wantedDisplay = pendingDisplayID
        lock.unlock()
        // Resolve the NSScreen for the cursor's display ON THE MAIN THREAD (AppKit isn't safe
        // off-main); fall back to the key screen when the lookup misses (cursor query failed,
        // display just unplugged). Sync is safe here: no lock is held, and the main thread never
        // blocks waiting on this thread.
        let made: (link: CADisplayLink, display: CGDirectDisplayID)? = DispatchQueue.main.sync {
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value == wantedDisplay
            } ?? NSScreen.main
            guard let screen else { return nil }
            let actual = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                          as? NSNumber)?.uint32Value ?? 0
            return (screen.displayLink(target: self, selector: #selector(step(_:))), actual)
        }
        guard let (link, actualDisplay) = made else {
            // No display right now (asleep / clamshell / switching). Reset so the NEXT tick retries
            // instead of leaving smooth scroll permanently dead.
            lock.lock()
            if thread === Thread.current { // don't clobber a replacement spawned after a rebuild
                thread = nil; running = false
                remV = 0; remH = 0; velV = 0; velH = 0; carryV = 0; carryH = 0
                clearPlanLocked()
                mode = .idle; phaseStarted = false; momentumInterrupted = false
                stallRetries = 0
            }
            lock.unlock()
            return
        }
        lock.lock()
        guard thread === Thread.current else {
            // handleWake (or the stall watchdog's rebuild) replaced this thread while it was still
            // starting up. Publishing our link now would leave TWO live links stepping — double-rate
            // spring, duplicated events — with ours unreachable forever. Bow out instead.
            lock.unlock()
            link.invalidate()
            return
        }
        linkRunLoop = CFRunLoopGetCurrent()
        displayLink = link
        linkDisplayID = actualDisplay
        lock.unlock()
        link.add(to: .current, forMode: .common)
        // A bare port keeps the run loop alive while the link is paused, so the thread survives idle.
        RunLoop.current.add(NSMachPort(), forMode: .common)
        CFRunLoopRun()
    }

    /// One display-refresh tick: advance the spring toward the accumulated target, hand the glide off
    /// to the momentum stream when a flick's ticks stop, and pause the link when settled.
    @objc private func step(_ link: CADisplayLink) {
        lock.lock()
        // Animation clock = the frame's presentation time (targetTimestamp), not wall-clock at
        // callback dispatch: dispatch latency jitters while frames present exactly on vsync, so a
        // wall-clock dt wobbles the per-frame delta → visible micro-judder. Same mach timebase as
        // CACurrentMediaTime(), so mixing with the seed from addTick/addPixels is safe.
        let now = link.targetTimestamp
        let dt = min(max(now - lastTime, 0), 0.05) // clamp: no negative dt, no lurch after a stall
        lastTime = now
        lastStepTime = now // the link is alive — stand the stall watchdog down
        stallRetries = 0

        // A fresh tick landed mid-coast (flagged in addTick/addPixels): close the momentum stream
        // before emitting, so the new gesture opens cleanly — momentum-ended → began, exactly the
        // "catch a coasting trackpad" event sequence.
        let closeMomentum = momentumInterrupted
        momentumInterrupted = false

        var dV = 0.0, dH = 0.0
        var wantMomentum = false
        let maxFrameD = ScrollAnimator.maxOutputSpeed * dt // speed ceiling, as px for THIS frame
        if let p = plan {
            // MMF glide: sample the plan at (wall time since the last re-plan) × compression rate.
            // Advance at most 50 ms of plan time per frame (the plan-path twin of the spring's dt
            // clamp): across a sleep/stall the mach clock can jump far ahead of the last frame,
            // and an unclamped sample would dump the glide's whole backlog as one violent frame.
            let planTime = min((now - planStart) * planRate,
                               planPrevTime + 0.05 * planRate,
                               p.duration)
            // Speed ceiling: emit at most maxFrameD; `planEmitted` tracks what was POSTED, so any
            // capped excess simply drains over the following frames — distance is never lost.
            let d = min(max(p.distance(at: planTime) - planEmitted, 0), maxFrameD)
            planEmitted += d
            if planAxisIsV { dV = d * planSign } else { dH = d * planSign }
            // Momentum labeling (MMF trackpad sim): the drag coast is momentum, but only after the
            // wheel has been quiet past the tick window (each notch resets `planStart`) and only
            // for frames that lie ENTIRELY inside the drag portion — so steady ticking stays one
            // gesture stream instead of churning ended→momentum→began between notches.
            wantMomentum = (now - planStart) >= MMFScrollTuning.tickIntervalMax
                && p.inDragPhase(at: planPrevTime) && p.inDragPhase(at: planTime)
            planPrevTime = planTime
            // Drained (fully emitted, not merely past the end time — the ceiling may still be
            // draining a capped backlog); the finish path closes the stream.
            if planTime >= p.duration, p.total - planEmitted < 0.5 { clearPlanLocked() }
        } else {
            let (sV, newRemV, newVelV) = ScrollAnimator.springAdvance(
                remaining: remV, velocity: velV, dt: dt, omega: omega,
                stopDistance: stopDistance, stopSpeed: stopSpeed)
            let (sH, newRemH, newVelH) = ScrollAnimator.springAdvance(
                remaining: remH, velocity: velH, dt: dt, omega: omega,
                stopDistance: stopDistance, stopSpeed: stopSpeed)
            dV = sV; remV = newRemV; velV = newVelV
            dH = sH; remH = newRemH; velH = newVelH
            // Speed ceiling: hand any excess back to the spring's target so it drains later.
            if abs(dV) > maxFrameD {
                let capped = dV > 0 ? maxFrameD : -maxFrameD
                remV += dV - capped; dV = capped
            }
            if abs(dH) > maxFrameD {
                let capped = dH > 0 ? maxFrameD : -maxFrameD
                remH += dH - capped; dH = capped
            }
        }

        // Hand the open gesture stream off to momentum when the glide enters its coast.
        var closeGesture = false
        if mode == .gesture, phaseStarted, wantMomentum {
            closeGesture = true
            mode = .momentum
            phaseStarted = false
        }

        let moving = dV != 0 || dH != 0
        var iV = 0.0, iH = 0.0
        if moving {
            lastMotionTime = now
            carryV += dV; iV = carryV.rounded(.towardZero); carryV -= iV
            carryH += dH; iH = carryH.rounded(.towardZero); carryH -= iH
        } else {
            carryV = 0; carryH = 0 // settle, but keep the stream/link warm
        }

        // Only truly finish once the glide has been idle past the hold window — until then a new tick
        // can revive the SAME stream, avoiding the ended→began churn that feels hitchy.
        let finish = !moving && (now - lastMotionTime) >= gestureHold
        let willEmit = moving
        let emitStream = mode
        let hadBegun = phaseStarted
        let phaseless = phaselessStream
        // Phase-less glides never open a stream — nothing to begin, nothing to end.
        if willEmit, !phaseless { phaseStarted = true }
        if finish { running = false; mode = .idle; phaseStarted = false }
        lock.unlock()

        if closeMomentum {
            post(intV: 0, intH: 0, preciseV: 0, preciseH: 0, gesturePhase: 0, momentumPhase: momentumEnded)
        }
        if closeGesture {
            post(intV: 0, intH: 0, preciseV: 0, preciseH: 0, gesturePhase: phaseEnded)
        }
        if finish {
            // Close whichever stream was open so the app finalizes it cleanly.
            if hadBegun {
                if emitStream == .momentum {
                    post(intV: 0, intH: 0, preciseV: 0, preciseH: 0,
                         gesturePhase: 0, momentumPhase: momentumEnded)
                } else {
                    post(intV: 0, intH: 0, preciseV: 0, preciseH: 0, gesturePhase: phaseEnded)
                }
            }
            link.isPaused = true // pause (not tear down) → zero CPU until the next tick
        } else if willEmit {
            if phaseless {
                // Hi-res glide: a plain continuous event, phase fields zero — exactly what the
                // mouse itself sends, so apps clamp at page edges instead of rubber-banding.
                post(intV: Int32(iV), intH: Int32(iH), preciseV: dV, preciseH: dH, gesturePhase: 0)
            } else if emitStream == .momentum {
                post(intV: Int32(iV), intH: Int32(iH), preciseV: dV, preciseH: dH,
                     gesturePhase: 0, momentumPhase: hadBegun ? momentumContinue : momentumBegan)
            } else {
                // Real trackpads open a gesture with an EMPTY began frame; deltas arrive in
                // `changed` frames. Some apps discard began's delta outright, which would eat the
                // first frame of every gesture (a small hitch at each start). So: began(0,0) and
                // the delta as `changed`, posted back-to-back in the same frame — no lost motion,
                // no added latency. (Momentum began carries its delta, matching real hardware.)
                if !hadBegun {
                    post(intV: 0, intH: 0, preciseV: 0, preciseH: 0, gesturePhase: phaseBegan)
                }
                post(intV: Int32(iV), intH: Int32(iH), preciseV: dV, preciseH: dH,
                     gesturePhase: phaseChanged)
            }
        }
    }

    private func post(intV: Int32, intH: Int32, preciseV: Double, preciseH: Double,
                      gesturePhase: Int64, momentumPhase: Int64 = 0) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2, wheel1: intV, wheel2: intH, wheel3: 0) else { return }
        // Mark continuous so apps treat it as trackpad-style smooth scrolling, not a wheel notch.
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Strip keyboard modifiers: freshly created events snapshot the live modifier state, and
        // our modifiers all MEAN something upstream (Shift = axis swap, Option = precise, Ctrl =
        // quick — already applied before the glide). Passing them through would double-apply the
        // effect in apps with their own modifier handling (Chromium transposes Shift+wheel itself).
        event.flags = []
        // Carry the exact sub-pixel delta for apps that read the fixed-point field (most modern ones),
        // so slow scrolls glide instead of stepping between whole pixels.
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: preciseV)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: preciseH)
        // Stamp the phases so phase-aware apps (Safari) render a coherent gesture + coast, not jumps.
        // At most one of the two is nonzero at a time — a real trackpad stream looks the same.
        event.setIntegerValueField(scrollPhaseField, value: gesturePhase)
        event.setIntegerValueField(momentumPhaseField, value: momentumPhase)
        event.setIntegerValueField(.eventSourceUserData, value: ScrollAnimator.syntheticTag)
        event.post(tap: .cghidEventTap)
    }
}
