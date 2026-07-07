# Scroll Review — smoothness vs Mac Mouse Fix + bugs

Scope: ScrollAnimator.swift, EventTapEngine.swift, AppConfig.swift, SpaceDragGesture.swift, ScrollMathTests.swift.
Verdict: architecture solid (dedicated tap thread, CADisplayLink pacing, phase-tagged gestures, sub-pixel deltas, unit-tested math). Feel gap vs MMF comes from the animation MODEL, not the plumbing. One real race likely explains residual "scroll dies" reports.

## Why it feels less smooth than Mac Mouse Fix

### S1. Velocity discontinuity per notch (biggest feel gap)
ScrollAnimator.swift:172-177 — pure exponential ease-out: each notch ADDS distance to `rem`, per-frame delta = `rem * (1-e^(-dt/τ))`. Velocity jumps instantly to `rem/τ` at tick arrival (infinite acceleration, no ease-in), then decays. Slow/steady ticking → sawtooth velocity → per-notch pulsing. MMF uses curves with velocity continuity (animator re-targets FROM current velocity). Fix: replace exponential with critically-damped spring (state = position error + velocity); velocity stays continuous across ticks, keeps exact-distance property, ~10 lines.

### S2. No momentum/coast tail
τ=0.07s → motion fully settles ~0.2-0.35s after last notch; momentum phase (field 123) never emitted. MMF simulates trackpad momentum: fast flick → long glide + momentum-phase events (apps like Safari handle coast natively, elastic bounce works). Here fast flicks stop abruptly = "khựng". Accel cap (2.05 × 70px = ~143px/notch) also far below MMF flick travel. Fix: on settle with high terminal velocity, emit momentum-phase tail (began=1/continue=2/end=3 on field 123) with slower decay.

### S3. dt jitter — CACurrentMediaTime instead of link timestamps
ScrollAnimator.swift:247-248 — `dt` from `CACurrentMediaTime()` varies with callback dispatch latency while frames present at fixed vsync → micro-judder. Use `link.targetTimestamp` deltas.

### S4. Display link bound to NSScreen.main
ScrollAnimator.swift:230 — link paces at the KEY screen's refresh, not screen under cursor. 120Hz MBP + 60Hz external → scroll on 120Hz screen paced at 60Hz (or vice versa). Also NSScreen.main called off-main-thread (unsupported AppKit). Fix: pick screen containing cursor; rebuild on screen change (already have handleWake hook).

### S5. phaseBegan carries first frame's delta
ScrollAnimator.swift:283-284 — real trackpads send began with ZERO delta then changed. Phase-aware apps may drop began's delta → first-frame hitch. Minor; verify per-app. Fix: emit began(0,0), motion starts on next frame's changed.

## Bugs

### B1 [HIGH] Race: endGestureNow vs addTick → link paused while running=true → scroll dead
ScrollAnimator.swift:148-166 + 182-201. Window: endGestureNow (main thread, fired by space/app-switch/device notifications) sets `running=false`, unlocks, THEN enqueues pause block. If a wheel tick lands in that gap: addTick sees wasIdle → sets running=true → enqueues UNpause block FIRST; endGestureNow then enqueues pause AFTER. Blocks run in enqueue order → final state: link paused, running=true, rem>0. Every later tick sees wasIdle=false → never wakes. Scroll dead until next space/app switch resets it. User-visible: "scroll randomly stops, comes back after switching apps" — same symptom class as fbb86ac/0f24710. Likelihood amplified: space-drag feature triggers activeSpaceDidChange WHILE user is actively scrolling. Fix: inside the pause block re-check `running` under lock (skip pause if a new gesture started), or generation counter; cleaner: route all pause/unpause decisions through step() only.

### B2 [MED] applyContinuous contradicts the codebase's own finding on in-place edits
EventTapEngine.swift:306-311 comment: "macOS does NOT honor in-place delta edits on a passed-through wheel event" (stated reason Standard-reverse needed fresh events). But applyContinuous (EventTapEngine.swift:344-354) does exactly in-place edits + passthrough for continuous mice (speed slider + reverse on MX-Master-class). One of the two is misdiagnosed. If comment is right → speed/reverse silently no-op on high-res mice. Verify on hardware; if broken, post fresh scaled event like the reverse path.

### B3 [LOW] Cross-axis acceleration carryover
ScrollAnimator.swift:89-92 — `dir` = sign of dominant axis only; vertical +1 tick followed by horizontal +1 tick counts as sameDir → accel multiplier carries across axes.

### B4 [LOW] Stale header doc
ScrollAnimator.swift:5-13 — header describes impulse+velocity-decay model and says both accelerators "disabled in current profile"; actual code is distance-accumulator with active accel toggle. Doc rot → misleads future maintenance.

### B5 [VERIFY] Modifier+scroll in smooth mode
Synthetic events (post at cghidEventTap) usually inherit physically-held modifiers, so Shift+wheel (horizontal) / Ctrl+wheel (zoom) likely still work — but untested. Verify once; if broken, copy `event.flags` from original.

## Recommended fix order
1. B1 race — ✅ FIXED 260707 (pause block re-checks running/phaseStarted/displayLink under lock; code-reviewer confirmed, also closes a 2nd strand path via handleWake rebuild)
2. S3 targetTimestamp — ✅ FIXED 260707 (dt from link.targetTimestamp, clamped [0, 0.05]; confirmed)
3. S1 spring model (the MMF feel gap)
4. S2 momentum tail (pairs with S1)
5. S4 cursor-screen display link
6. B2 verify on hardware, then fix or fix comment
7. S5/B3/B4 cleanups

## Unresolved questions
- B2: does in-place scroll-field editing work for continuous events on this macOS version? (needs hardware test)
- B5: modifier merge behavior for HID-posted synthetic scrolls (needs quick manual test)
- S5: which apps actually drop began-frame delta (Safari? Chromium?)
