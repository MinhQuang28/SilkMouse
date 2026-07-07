# QmouseFix Audit — Sleep/Wake Failures, Memory Leaks, Crash Risks

Date: 2026-07-07 | Scope: all of `Sources/QmouseFix/` (13 files, ~1.9k LOC) + uncommitted changes (stall watchdog, zombie guard, beginActivity). Build: clean. Tests: 34/34 pass (`swift test`).
Out of scope per instructions: style, naming, scroll-feel tuning.

## Hypothesis Verdicts (A–I)

| # | Hypothesis | Verdict | Why |
|---|-----------|---------|-----|
| A | handleWake block never runs → leaked CADisplayLink that can fire again | **REFUTED** (leak); residual no-op TOCTOU exists, benign | Exactly one handleWake can capture a given runloop: `linkRunLoop` is read+nil'd in one locked section (ScrollAnimator.swift:349-353), so a second rapid handleWake sees nil and returns (:363). The loop can ONLY exit via that same invalidate+stop block — the NSMachPort (:401) keeps it alive otherwise — so the invalidate is guaranteed to execute; no un-invalidated link survives, and a torn-down link's runloop never runs again so it can't fire. Display-parameter storms: at most one teardown per live thread generation; each teardown fully reclaims. Residual: endGestureNow (:255,:271) / startOrWake (:334,:338) can enqueue onto a runloop that stopped between their unlocked read and the enqueue — the block never runs, but neither block strongly captures the runloop (no retain cycle) and pending blocks are released when the CFRunLoop finalizes; the skipped pause/`ended` is moot because handleWake reset the state. No leak, no dead state. |
| B | animator↔link retain cycle | **CONFIRMED cycle, no practical leak** | `displayLink(target: self…)` retains the animator; animator retains `displayLink` (:71,:374,:397). Every teardown path invalidates: handleWake block (:366-369), zombie guard (:393). Animator is owned by the immortal `EventTapEngine.shared` anyway, and rebuilds don't accumulate (old link invalidated + released each cycle). Informational only; becomes a real leak only if the animator ever stops being process-lifetime. |
| C | NSMachPort leaked per rebuild | **REFUTED** | One `NSMachPort()` per animator thread (:401). handleWake's block stops the loop → `CFRunLoopRun` returns → thread exits → per-thread CFRunLoop finalized → port source released → NSMachPort dealloc destroys its receive right. Max one live port; rebuild churn is bounded (see A). |
| D | passUnretained refcon dangling pointer | **REFUTED** | `EventTapEngine` is `static let shared` + `private init` (EventTapEngine.swift:10-11); there is no stop()/teardown anywhere in the codebase, so the refcon (:170) and IOHID context (:96) are valid for process lifetime. ScrollAnimator/SpaceDrag are owned by it. **Caveat:** any future teardown path makes both callbacks dangling — leave a comment or convert to a registered-lifetime pattern before ever adding one. |
| E | Force unwraps / int conversions can trap | **MOSTLY REFUTED, two real (low) trap sites** | `CGEventField(rawValue: 99/123)!` (ScrollAnimator.swift:62-63, EventTapEngine.swift:337-338) cannot trap — C-imported enums' `init(rawValue:)` always succeeds for any value. `Int32(iV)` in step (:486,:489) is safe: `clampDist` bounds rem to ±6000 (:148-149,:193) so per-frame carry < 6001. `created!` (EventTapEngine.swift:187) is guarded by the retry loop. Remaining trap sites: Finding 2. |
| F | Timer/observer/IOHID lifecycle leaks | **REFUTED — acceptable-by-lifetime** | Watchdog Timer uses `[weak self]` (:132), retained by main runloop, intentionally never invalidated. Observers added once (start() re-entry blocked by `guard thread == nil`, :43) on an immortal object. IOHIDManagerOpen never closed — process lifetime, non-fatal open failure logged (:105-108). NSEvent monitors removed in stop()/onDisappear (ButtonCaptureField.swift:44-49, ShortcutControl.swift:47-51). |
| G | Sleep mid-glide → dead scroll or stale momentum stream | **CONFIRMED SAFE for dead-scroll; one stream-hygiene gap** | Walked: coast running → lid close → link dead → didWake handleWake tears down (state cleared, thread exits) → screensDidWake handleWake idempotent (rl nil) → next tick spawns fresh thread+link. NSScreen.main nil at wake → failure path (:376-385) resets under identity guard, retries per tick. If BOTH notifications are missed, the new watchdog heals in ≤3×0.25s of active scrolling. Gap: handleWake never posts `momentumEnded`/`phaseEnded` for an open stream → Finding 3. Bounded quirk: a tick landing between the two wake notifications builds a fresh link that the second notification immediately destroys — one dropped tick's backlog, next tick rebuilds (feel-level, self-healing). |
| H | SpaceDrag/RemapAction/SystemActions: CF imbalance, nil crash, stuck button across sleep | **CONFIRMED one issue (stuck drag state)**; rest refuted | No manual CFRetain/CFRelease anywhere; `takeUnretainedValue()` on the Unmanaged AX constant is correct. Every CGEvent/NSEvent creation is nil-guarded (RemapAction.swift:61-77, SystemActions.swift:86-91, ScrollAnimator.swift:497, MediaKey.swift:33, EventTapEngine.swift:312 with passthrough fallback). Modifier sequences post down+up within one serial-queue block — sleep only delays the tail, releases still post on wake. Stuck state across sleep: Finding 1. |
| I | SwiftUI/Combine/KVO retain cycles keeping windows alive | **REFUTED** | ConfigStore is a @MainActor singleton, no subscriptions held. Monitors removed on disappear. No KVO. Monitor closures capture struct copies + immortal singletons — nothing references a window, so nothing can keep one alive. |

## New-code adversarial checks (uncommitted)

- **Stall watchdog** (ScrollAnimator.swift:199-226): thread-safe. `wakeActionLocked` runs only on the tap thread (serial); the escalated `handleWake()` from the tap thread uses the same single `lock`, no lock nesting, and enqueues/wakes only after unlock — no deadlock. Double-teardown impossible (rl read+nil atomic under lock). No livelock: `.wake` is idempotent; `.rebuild` resets `stallRetries` (:360) and drops the backlog by design; if NSScreen.main stays nil, cost is one short-lived thread spawn per tick while the user scrolls with no display — bounded work, self-terminating. Cannot false-positive during a healthy glide (step updates `lastStepTime` every frame, :416, including the paused-idle case because `running` is false there and the first branch of wakeActionLocked handles it). No reachable state with `running == true` and no recovery: every pause site either clears `running` in the same critical section or re-checks `stillIdle` under lock (:282-295), and the watchdog backstops OS-invalidated links.
- **Zombie guard** (ScrollAnimator.swift:378, :388-395): `Thread.current` inside a `Thread {}` body returns the same Thread instance that was `start()`ed, so `thread === Thread.current` is a valid generation check. Publication happens only under that guard, so two live links can never be *published*; the losing starter invalidates its own link on its own thread (:393) before exiting. The only two-live-link window is transient: handleWake clears state → a tick spawns thread2+link2 before rl1's invalidate block runs → both step for ≤ a few ms. Shared `lastTime` splits dt so total distance is conserved; old link is guaranteed invalidated when its block drains. Informational.
- **beginActivity** (QmouseFixApp.swift:31-37): CONFIRMED safe. `.userInitiatedAllowingIdleSystemSleep` is `.userInitiated` minus `idleSystemSleepDisabled`; `.latencyCritical` only affects timer coalescing/QoS and sets no sleep-assertion flags. Neither prevents idle system sleep, display sleep, or lid-close sleep. Token stored in a strong instance property for app lifetime — correct (the activity ends if the token deallocs).

## Findings

### MED-1 — Stale SpaceDrag `down` state survives sleep: swallowed drags + spurious Space switches after wake
- **Where:** SpaceDragGesture.swift:38 (`down`), :64-69 (only reset path is a button-up we receive); EventTapEngine.swift:115-118 (handleWake never touches spaceDrag).
- **Interleaving:** user holds the space-drag button → lid closes (or the tap is disabled) → button released while asleep → the `otherMouseUp` never reaches the tap → wake: `down == true` with no button held. Now (a) every `otherMouseDragged` from ANY held button is consumed by `handleDrag` (guard at :74 passes) — swallowed from apps AND able to fire Space switches / Mission Control from unrelated drags; (b) persists until the user happens to press the gesture button once (`handleButtonDown` re-arms).
- **Fix (keeps state tap-thread-only):** add `func cancel() { down = false; dragged = false }` to SpaceDragGesture; in EventTapEngine add `private var pendingDragReset = false` guarded by the existing `lock`; set it in `handleWake()`; in `handle()`'s existing locked snapshot section (:203-216) read+clear it, and call `spaceDrag.cancel()` on the tap thread right after unlock.

### LOW-2 — Unclamped integer conversions from foreign event fields can trap
- **Where:** EventTapEngine.swift:358-361 (`Int64(scaled.rounded())` in `scaleInt`, gain up to 3.0) and :313-314 (`Int32(lineV)`, `Int32(lineH)` building the reversed event).
- **Mechanism:** the tap sees every scroll event system-wide, including synthetic events from other processes. `Int32(_: Double)` / `Int64(_: Double)` trap on overflow. A crafted/buggy event with |delta| > 2³¹ (line path) or |delta·3| > 2⁶³ (scaleInt path) hard-crashes the app. No real device gets near these magnitudes — defense-in-depth, cheap fix.
- **Fix:** clamp before converting, e.g. `Int64(scaled.rounded().clamped(to: -1e15...1e15))` and `Int32(exactly: lineV.rounded()) ?? Int32(clamping: Int(lineV.rounded()))` — or simply `min(max(lineV, -1e6), 1e6)` before `Int32(_)`.

### LOW-3 — handleWake abandons an open gesture/momentum stream without posting `ended`
- **Where:** ScrollAnimator.swift:348-371 (contrast endGestureNow :260-296, which closes streams).
- **Mechanism:** sleep mid-coast after `momentumBegan` was posted → wake teardown clears state silently → the frontmost app is left with an unterminated momentum stream. Most apps recover on the next `began`; risk is cosmetic (e.g. stuck rubber-band). Not a leak or crash.
- **Fix (optional):** in handleWake, snapshot the open stream (same logic as endGestureNow:260) and post the matching `ended` inside the invalidate block before `CFRunLoopStop`.

### LOW-4 — `CFRunLoopAddSource` with implicitly-unwrapped nil source
- **Where:** EventTapEngine.swift:189-190. `CFMachPortCreateRunLoopSource` returns optional; passing nil to `CFRunLoopAddSource` (takes `CFRunLoopSource!`) would crash. Essentially unreachable with a valid tap port, but a one-line `guard let source else { return }` removes the trap.

### LOW-5 — `NSScreen.main` accessed from the animator background thread
- **Where:** ScrollAnimator.swift:374. AppKit does not document `NSScreen.main` as thread-safe. Works in practice (widely done), but it runs on every animator-thread (re)build, including wake races while AppKit is re-enumerating displays. If ever hardened: snapshot the screen on the main thread and pass it in, or wrap in a main-thread hop before spawning.

### LOW-6 — Benign data race on `EventTapEngine.tap`
- **Where:** written once on the tap thread (:188), read from the main thread by reEnableTap/watchdog (:123-124) and handleWake without synchronization. Single pointer-sized write-once value — safe on arm64 in practice, but TSan would flag it. Fix if desired: publish under the existing `lock` or make it a `OSAllocatedUnfairLock`-guarded property.

## Positive observations (verified, not assumed)

- The recurring "link paused while running==true" defect class is now closed from both ends: every pause site re-validates under the lock, and the watchdog backstops the un-notifiable OS-invalidation case.
- Teardown is single-owner by construction (rl read+nil in one critical section) — that one design choice is what makes A, C, and the double-rebuild concerns all fall away.
- All CGEvent/NSEvent creations nil-guarded; no manual CF memory management to imbalance; singletons make the passUnretained pattern sound.
- `beginActivity` options chosen correctly for a background input agent (no sleep assertions).

## Metrics
- Build: clean (`swift build` via `swift test`). Tests: 34/34 pass. Linting: not configured; no compile warnings observed in output.

## Recommended actions (priority order)
1. Fix MED-1 (SpaceDrag reset on wake) — small, contained, closes the only real wake-related behavioral defect found.
2. Add the two clamps for LOW-2 and the guard for LOW-4 — three lines total, removes all reachable traps in the tap path.
3. Optionally close streams in handleWake (LOW-3) for event-stream hygiene.
4. Leave B/C/F as-is (lifetime-bounded by design); add a comment near the refcon noting the never-dealloc invariant (D).

## Unresolved questions
- None blocking. One untestable-here assumption: pending CFRunLoop blocks are released at runloop finalization (CF source behavior; affects only the already-benign A-residual).

## Fixes applied (260707, same session)
- MED-1 ✅ `SpaceDragGesture.cancel()` + `pendingDragCancel` flag in EventTapEngine, set by
  `handleWake`/`handleDeviceChange` under lock, consumed at the top of the tap callback (tap thread).
- LOW-2 ✅ `scaleInt` clamps to ±1e15 + finite check; reverse path uses `int32Clamped` for wheel deltas.
- LOW-3 ✅ `ScrollAnimator.handleWake` captures `openStream` (same logic as `endGestureNow`) and posts
  the matching ended event inside the teardown block on the link thread (best-effort by design).
- LOW-4 ✅ `threadMain` guards nil `CFMachPortCreateRunLoopSource` with an NSLog + return.
- LOW-5 (NSScreen.main off-main-thread) left open — tracked as S4 in review-260707-0903.
- LOW-6 (benign write-once race on `tap`) accepted as-is.
Verified: 34/34 tests pass, app rebuilt + relaunched.
