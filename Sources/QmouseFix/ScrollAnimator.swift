import AppKit
import CoreGraphics
import QuartzCore

/// Trackpad-like smooth scrolling: a critically-damped spring glides toward an accumulated distance
/// target, with an MMF-style momentum tail for flicks.
///
/// Model (per axis): each wheel notch ADDS a distance to the remaining target; every frame a
/// critically-damped spring (state = remaining distance + velocity, see `springAdvance`) moves toward
/// that target. The spring is what makes consecutive notches feel like ONE continuous push instead of
/// per-notch pulses: a new notch only moves the target — velocity carries over unchanged (the previous
/// exponential-ease model jumped speed instantaneously on every notch) — and motion still stops exactly
/// at the accumulated distance (no floaty over-coast, which Chromium/VS Code render as "khựng/trễ").
/// A direction reversal drops target and velocity together so flipping is crisp.
///
/// Momentum tail: when ticks stop arriving but the glide still has real speed + distance (a flick),
/// the gesture stream is closed and the REST of the glide is emitted as momentum-phase events with a
/// softer spring — the began→changed→ended, then momentum began→continue→ended shape of a real
/// trackpad, so phase-aware apps (Safari elastic scrolling…) treat the coast natively. Total distance
/// is unchanged, only the labeling and the tail's stretch differ; slow deliberate scrolling never
/// qualifies (speed+distance gated) and keeps the exact stop.
///
/// Smoothness plumbing:
///   • the glide is paced by a `CADisplayLink` on its own thread+run-loop (paused when idle — zero
///     CPU — and never competing with the event tap); dt comes from `targetTimestamp` (see `step`).
///   • each frame carries its precise sub-pixel delta in the fixed-point field, so slow scrolls don't
///     visibly step between whole pixels.
/// Shared state is guarded by `lock`; `NSObject` base is only needed for the link's target selector.
final class ScrollAnimator: NSObject {

    /// Marks our own synthetic scroll events (via `.eventSourceUserData`) so the tap skips them.
    static let syntheticTag: Int64 = 0x5132_4D46 // "Q2MF"

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
    private var steppedMode = false         // Smooth-step never hands off to momentum

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

    // Scroll tuning — distance accumulator + critically-damped spring. Each notch ADDS a fixed
    // distance to the remaining target; the spring (see `springAdvance`) glides there with continuous
    // velocity, so per-frame deltas ease in AND out (no per-notch pulsing) while motion still stops
    // exactly at the accumulated distance (keeps the "khựng/giật + trễ" fix for Chromium/VS Code,
    // whose own velocity trackers hated spike-then-decay deltas).
    private let pixelsPerNotch = 70.0 // Smooth: distance one notch contributes at speed 1.0 (× `speed`)
    private let pixelsPerLine = 30.0  // Smooth-step: pixels per "line" of the fixed N-line notch step
    private var omega = 26.0          // rad/s — current spring stiffness (set per tick by the mode)
    private let omegaSmooth = 26.0    // settles a step in ~0.18 s — trackpad-like
    private let omegaStep = 40.0      // crisp: ~0.12 s so each notch lands as a discrete step
    private let omegaMomentum = 10.0  // soft: stretches a flick's tail into a longer coast
    private let maxRemaining = 6000.0 // px clamp so a fast spin can't accumulate an absurd target
    private let stopDistance = 0.1    // px; together with `stopSpeed`, flushes the final sliver
    private let stopSpeed = 20.0      // px/s; below BOTH thresholds the glide settles
    // Momentum handoff — a flick is "a RAPID input burst that went quiet while the glide is still
    // moving with a real backlog". The last inter-tick gap and the backlog AT the last tick are the
    // discriminators that survive spring drain during the silence window (current-`rem` gates don't:
    // the spring drains ~78%/100 ms, so any at-check distance gate is either dead or hair-trigger).
    // Steady deliberate ticking (gaps ≳ 0.1 s) never qualifies at any speed — it keeps the exact
    // stop — while ending a fast burst/spin gets the trackpad-style coast. See `shouldStartMomentum`.
    private static let momentumGap = 0.10         // s of input silence before the coast can start
    private static let flickMaxGap = 0.08         // s — the burst's last inter-tick gap must be rapid
    private static let momentumMinSpeed = 350.0   // px/s the glide must still be doing at handoff
    private static let momentumMinBacklog = 80.0 // px still queued when the burst ended — low enough
                                                 // that accel-OFF flicks (steady-state backlog ≈88 px)
                                                 // still coast; two quick default-speed notches (~80 px)
                                                 // stay just under

    // Acceleration: rapid consecutive notches in the same direction multiply each notch's distance, so a
    // fast flick travels much farther than slow, deliberate clicks (MMF-style "scroll speedup").
    private var lastTickTime = 0.0    // when the previous notch arrived (for the inter-tick gap)
    private var lastTickGap = Double.infinity // gap between the last two input events (flick detector)
    private var backlogAtTick = 0.0   // max |rem| right after the last input event landed
    private var lastTickDir = 0       // sign of the previous notch's dominant axis (for reset on reversal)
    private var lastTickAxisIsV = true // axis of the previous notch — the ramp must not carry across axes
    private var accel = 1.0           // current speedup multiplier (1.0 = none)
    private static let accelGap = 0.18  // s; notches closer than this ramp the multiplier up
    private static let accelStep = 0.28 // multiplier added per consecutive fast notch
    private static let accelMax = 2.05  // ceiling so a fast spin can't fling absurdly far

    /// Feed a wheel notch (line deltas, already direction-corrected). In Smooth-step mode each notch is
    /// a fixed `lines`-line step with a crisp ease and no coast; otherwise `speed` scales a momentum glide.
    func addTick(lineV: Double, lineH: Double, speed: Double, stepped: Bool, lines: Int, accelerate: Bool) {
        let now = CACurrentMediaTime()
        var dist = stepped ? Double(lines) * pixelsPerLine : pixelsPerNotch * speed

        lock.lock()
        steppedMode = stepped
        omega = stepped ? omegaStep : omegaSmooth
        // A tick mid-coast "catches" the glide, like touching a coasting trackpad: close the momentum
        // stream (posted by the link thread) and reopen a gesture. Velocity carries over — no stutter.
        if mode == .momentum { momentumInterrupted = true; mode = .gesture; phaseStarted = false }
        // Acceleration applies to momentum (Smooth) only — Smooth-step's fixed N-line step must stay
        // constant per notch. Ramp the multiplier on rapid same-direction notches; reset otherwise
        // (a reversal or an axis change must not inherit the ramp).
        if accelerate && !stepped {
            let axisIsV = lineV != 0
            let dir = axisIsV ? (lineV > 0 ? 1 : -1) : (lineH > 0 ? 1 : -1)
            accel = ScrollAnimator.nextAccel(current: accel, gap: now - lastTickTime,
                                             sameDir: dir == lastTickDir && axisIsV == lastTickAxisIsV)
            lastTickDir = dir
            lastTickAxisIsV = axisIsV
            dist *= accel
        } else {
            accel = 1.0
        }
        lastTickGap = now - lastTickTime
        lastTickTime = now
        // Reversing direction: drop the opposing remainder AND velocity so the flip is immediate.
        // Also break the burst rhythm — otherwise a quick flip inherits the old direction's rapid
        // lastTickGap and a SINGLE reversed notch can qualify as a "flick" and coast.
        if lineV != 0, (lineV > 0) != (remV > 0) { remV = 0; carryV = 0; velV = 0; lastTickGap = .infinity }
        if lineH != 0, (lineH > 0) != (remH > 0) { remH = 0; carryH = 0; velH = 0; lastTickGap = .infinity }
        remV = clampDist(remV + lineV * dist)
        remH = clampDist(remH + lineH * dist)
        backlogAtTick = max(abs(remV), abs(remH))
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
        // Perceptual gain curve: 0.5 (slider default) → 1.0 = native magnitude, with SUB-LINEAR
        // reach below it. Hi-res mice natively scroll fast, and an MMF-like slow pace needs gains
        // down to a few % of native — a linear map can't get there without wrecking the slider's
        // top half. Exponent tuned by feel; top capped at the previous linear maximum (3×).
        let gain = min(pow(speed / 0.5, 1.7), 3.0)

        lock.lock()
        steppedMode = false
        omega = omegaSmooth
        if mode == .momentum { momentumInterrupted = true; mode = .gesture; phaseStarted = false }
        if pxV != 0, (pxV > 0) != (remV > 0) { remV = 0; carryV = 0; velV = 0 }
        if pxH != 0, (pxH > 0) != (remH > 0) { remH = 0; carryH = 0; velH = 0 }
        remV = clampDist(remV + pxV * gain)
        remH = clampDist(remH + pxH * gain)
        backlogAtTick = max(abs(remV), abs(remH))
        // Pixel input is NEVER flick-eligible: a hi-res mouse delivers each physical notch as a
        // BURST of events a few ms apart, so the inter-event gap can't tell a rapid flick from one
        // slow notch — the handoff would fire between ordinary notches and the next notch would
        // interrupt it, an ended→momentum→ended→began churn per notch that renders as visible
        // stutter. The spring's own tail already smooths the end of a fast hi-res swipe.
        lastTickGap = .infinity
        lastTickTime = now
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

    /// Pure speedup-curve step (extracted so it's unit-testable): a notch within `accelGap` of the
    /// previous one AND in the same direction bumps the multiplier by `accelStep` up to `accelMax`;
    /// any slow or reversed notch resets to 1.0.
    static func nextAccel(current: Double, gap: Double, sameDir: Bool) -> Double {
        guard sameDir, gap < accelGap else { return 1.0 }
        return min(accelMax, current + accelStep)
    }

    /// Pure momentum-handoff predicate (extracted so it's unit-testable): hand the glide off to the
    /// momentum stream once the input has been quiet for `momentumGap` — but only when the quiet
    /// followed a rapid burst (`lastGap`), the glide is still moving (`speed`), and the burst left a
    /// real backlog behind (`backlog`, measured AT the last tick, before the spring drained it).
    /// Smooth-step never coasts — its notches are discrete steps by definition.
    static func shouldStartMomentum(silence: Double, lastGap: Double, speed: Double,
                                    backlog: Double, stepped: Bool) -> Bool {
        guard !stepped else { return false }
        return silence > momentumGap && lastGap < flickMaxGap
            && speed > momentumMinSpeed && backlog > momentumMinBacklog
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

    /// Spin up the animator thread on first use, or un-pause its display link on later glides.
    /// `thread`/`linkRunLoop` are read+written under `lock` so a failed start (see `runLoop`) can be
    /// retried by the next tick without racing.
    private func startOrWake() {
        lock.lock()
        if thread == nil {
            let t = Thread { [weak self] in self?.runLoop() }
            t.name = "com.qmousefix.scroll-animator"
            t.qualityOfService = .userInteractive
            thread = t
            lock.unlock()
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
        running = false
        remV = 0; remH = 0; carryV = 0; carryH = 0; velV = 0; velH = 0
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
        guard let link = NSScreen.main?.displayLink(target: self, selector: #selector(step(_:))) else {
            // No display right now (asleep / clamshell / switching). Reset so the NEXT tick retries
            // instead of leaving smooth scroll permanently dead.
            lock.lock()
            if thread === Thread.current { // don't clobber a replacement spawned after a rebuild
                thread = nil; running = false
                remV = 0; remH = 0; velV = 0; velH = 0; carryV = 0; carryH = 0
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

        // Momentum handoff: a rapid burst went quiet but the glide still carries real speed — that's
        // a flick's tail. Close the gesture stream and relabel the rest as momentum events (what a
        // trackpad does when the fingers lift), softening the spring so the coast stretches.
        var closeGesture = false
        if mode == .gesture, phaseStarted,
           ScrollAnimator.shouldStartMomentum(silence: now - lastTickTime, lastGap: lastTickGap,
                                              speed: max(abs(velV), abs(velH)),
                                              backlog: backlogAtTick, stepped: steppedMode) {
            closeGesture = true
            mode = .momentum
            phaseStarted = false
            omega = omegaMomentum
        }
        // A fresh tick landed mid-coast (flagged in addTick/addPixels): close the momentum stream
        // before emitting, so the new gesture opens cleanly — momentum-ended → began, exactly the
        // "catch a coasting trackpad" event sequence.
        let closeMomentum = momentumInterrupted
        momentumInterrupted = false

        let (dV, newRemV, newVelV) = ScrollAnimator.springAdvance(
            remaining: remV, velocity: velV, dt: dt, omega: omega,
            stopDistance: stopDistance, stopSpeed: stopSpeed)
        let (dH, newRemH, newVelH) = ScrollAnimator.springAdvance(
            remaining: remH, velocity: velH, dt: dt, omega: omega,
            stopDistance: stopDistance, stopSpeed: stopSpeed)
        remV = newRemV; velV = newVelV
        remH = newRemH; velH = newVelH

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
        if willEmit { phaseStarted = true }
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
            if emitStream == .momentum {
                post(intV: Int32(iV), intH: Int32(iH), preciseV: dV, preciseH: dH,
                     gesturePhase: 0, momentumPhase: hadBegun ? momentumContinue : momentumBegan)
            } else {
                post(intV: Int32(iV), intH: Int32(iH), preciseV: dV, preciseH: dH,
                     gesturePhase: hadBegun ? phaseChanged : phaseBegan)
            }
        }
    }

    private func post(intV: Int32, intH: Int32, preciseV: Double, preciseH: Double,
                      gesturePhase: Int64, momentumPhase: Int64 = 0) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2, wheel1: intV, wheel2: intH, wheel3: 0) else { return }
        // Mark continuous so apps treat it as trackpad-style smooth scrolling, not a wheel notch.
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
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
