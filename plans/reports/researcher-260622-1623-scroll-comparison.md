# Scroll Logic Comparison: QmouseFix vs Mac Mouse Fix
**Reporter:** researcher | **Date:** 2026-06-22

## Summary
QmouseFix has a **solid, clean ease-to-target foundation** that already handles the core scroll-feel problem (khựng/giật + trễ in Chromium). MMF adds three layers: **acceleration curves** (consecutive-tick speedup), **sophisticated smoothing algorithms**, and **dual-event gesture fidelity**. Of these, only the acceleration curve is worth adopting for QmouseFix. The other two either lack user-visible payoff or add complexity outside the KISS principle.

---

## Detailed Comparison

### 1. Acceleration / Scroll-Speedup Curve

**MMF Implementation (ScrollSpeedupCurve.swift:14–43):**
- Exponential speedup curve: `f(x) = a × b^((x-t)×c) + 1 - a`
- Triggers AFTER `t` ticks (swipe threshold, ~4–6 ticks)
- Parameters: `t` = threshold, `p` = initial speedup, `c` = exponential exponent
- Example config: holding down wheel for 5+ quick ticks → 1.5× to 2.5× distance per notch
- Gated by `scrollSwipeThreshold_inTicks` and `consecutiveScrollSwipeCounter` (ScrollAnalyzer.m, line 70)

**QmouseFix Implementation (ScrollAnimator.swift):**
- Fixed: `pixelsPerNotch = 70.0` at all speeds
- NO per-tick speedup curve; acceleration only via `speed` slider scaling
- Each notch always adds the same distance (independent of previous ticks)

**User Impact:**
- MMF: Quick page-flip scrolls feel faster/snappier; sustained scrolls ramp up naturally
- QmouseFix: Feels **linear, not accelerating** — takes more "flicking" effort for large jumps

**Verdict: ADOPT**
- **Why:** Consecutive fast ticks = longer distances is a common expectation (trackpad behavior). Feels snappy without overshooting when leisurely scrolling.
- **Effort:** Moderate. Needs tick analyzer (track time between ticks, count consecutive direction changes) and a curve evaluator. ~60 LOC in Swift, simple math.
- **Implementation hint:** Add a `tickCounter` + `lastTickTime` to ScrollAnimator; if `time < threshold`, increment counter and evaluate curve. Reset on direction change or timeout (>0.5s idle).

---

### 2. Smoothing Model: Exponential vs MMF's Double-Exponential & Bezier

**MMF Smoothing (ExponentialSmoother.swift, DoubleExponentialSmoother.swift):**
- **ExponentialSmoother:** `L = a × Y + (1 - a) × L_prev`, where `a` is data-smoothing factor (0–1)
- **DoubleExponentialSmoother:** Adds trend tracking; extrapolates velocity
- Applied to `timeBetweenTicks` (NOT the delta itself) to stabilize the acceleration curve
- ScrollAnalyzer.m line 43–52: **Capacity-3 RollingAverage chosen over Exponential** because it's more responsive

**QmouseFix Smoothing (ScrollAnimator.swift:139–148):**
- Pure frame-rate-independent ease: `delta = remaining × (1 - exp(-dt / response))`
- Single response constant (0.07s smooth, 0.045s step)
- Achieves smooth feel via **ease-to-target accumulation**, not time smoothing

**User Impact:**
- QmouseFix already feels smooth due to the accumulator model (each notch adds distance, frame emits fraction)
- MMF's time-smoothing is an **orthogonal concern**: stabilizes the ANALYZER (tick speed detector), not the visual glide
- No perceptual difference in final scroll feel for typical usage

**Verdict: SKIP**
- **Why:** QmouseFix's ease-to-target is simpler and achieves the same visual smoothness. Time-smoothing helps MMF's acceleration curve be less jittery, but it's a secondary concern. Add it only AFTER adopting acceleration.
- **Complexity cost:** Extra state, extra constant tuning. Not needed for KISS.

---

### 3. Synthetic-Event Fidelity: Type 22 (scroll) + Type 29 (gesture) vs Type 22 only

**MMF Approach (GestureScrollSimulator.m:559–642):**
- Posts **BOTH**:
  - Type 22 (NSEventTypeScrollWheel): Standard scroll event with deltas
  - Type 29 (NSEventTypeGesture, subtype 6): Gesture event with gesture-specific fields
- Both at `kCGSessionEventTap` (post-HID, system-wide tap point)
- Gesture phases: MayBegin → Began → Changed → Ended (mimics real trackpad)
- Comment (line 604): Posting type 22 AFTER type 29 removed stutter in page-flip scenarios

**QmouseFix Approach (ScrollAnimator.swift:259–272, EventTapEngine.swift:261–271):**
- Posts only Type 22 at `cghidEventTap` (pre-HID, interceptor tap)
- Sets: `isContinuous = 1`, gesture phase (began/changed/ended), fixed-point deltas
- Already includes `eventSourceUserData` tag to prevent re-interception

**Practical Differences:**
- Type 29 is decoded by Chromium/Electron **gesture handlers**, not scroll handlers. Provides raw touch/gesture semantics for advanced apps.
- Most macOS apps (Safari, Mail, TextEdit) only read Type 22; they don't care about Type 29.
- **Safari specifically:** Uses gesture phase from Type 22 (field 99), not Type 29. QmouseFix already sets this (line 269).
- **Chromium bug:** Even MMF + Magic Mouse both fail on certain two-finger scroll detection (GestureScrollSimulator.m:22–23 comment). Type 29 doesn't fix it.

**User Impact:**
- **Safari, Mail, most apps:** No visible difference
- **Chromium/VS Code:** Type 29 helps some gesture detectors but doesn't fix fundamental two-finger issues. QmouseFix's Type 22 is already sufficient for these.
- The Type 22 _after_ Type 29 comment suggests a timing issue, not fidelity; QmouseFix avoids this by posting only Type 22.

**Verdict: SKIP**
- **Why:** No concrete user-visible benefit for QmouseFix's target (mouse wheel smoothing). Type 29 is a Chromium gesture-detection detail that MMF added for completeness, but it doesn't fix the core issue. Adds 80+ LOC and extra event posting (CPU cost).
- **Trade-off:** If a user reports Chromium multi-touch confusion, revisit. For now, YAGNI.

---

### 4. Direction/Axis Handling, Horizontal Scroll, Modifier Keys

**QmouseFix (EventTapEngine.swift, AppConfig.swift):**
- Axis support: Both vertical (wheel1) and horizontal (wheel2) ✅
- Reverse scroll: Full support (applies to both axes) ✅
- Modifier-key scrolling: **NOT implemented** — no shift-to-scroll, option-to-scroll, etc.
- High-res mice: Supported via `smoothHighRes` flag (continuous pixels → ease-to-target) ✅

**MMF (ScrollConfig.swift, ScrollModifiers.swift):**
- Axis support: Both vertical and horizontal ✅
- Reverse scroll: Full support ✅
- Modifier-key scrolling: **YES** — Shift = quick scroll, Option = precise scroll (ScrollModifiers.swift:64–84)
- High-res mice: Supported ✅

**User Impact:**
- QmouseFix: No way to rebind modifier scroll behavior (shift-scroll, etc.)
- Most users don't change this, but power users may expect it (especially if coming from MMF)

**Verdict: MAYBE**
- **Why:** Not critical for core scroll feel, but common in mature mouse utilities. Low effort (~30 LOC to gate modifiers in tap callback).
- **How to apply:** Add optional modifier-remap config (e.g., `shiftScrollMode: ScrollMode?`). In tap handler, check `CGEventGetFlags()` before routing to animator. 
- **Priority:** After acceleration curve; only if user requests it.

---

### 5. Stability & Recovery Mechanisms

**QmouseFix (EventTapEngine.swift:40–127):**
- **Tap watchdog:** 2s poll for silent disable (line 131) ✅
- **Wake recovery:** Re-enable tap + rebuild animator (line 114–117) ✅
- **Display change:** Rebuilds animator CADisplayLink (line 60) ✅
- **Space/app switch:** Closes gesture immediately (line 64–75) ✅
- **Device connect/disconnect:** Detects via IOKit, re-enables tap (line 81–110) ✅

**MMF (Scroll.m, GestureScrollSimulator.m):**
- Tap monitoring: Active (line 82–89)
- Wake recovery: Present
- Device monitoring: Present
- Momentum scroll cancellation: Explicit (GestureScrollSimulator.m:926–936)
- Comment (Scroll.m:36–37): Notes ongoing issue with intermittent scroll stops (Apr 2025)

**User Impact:**
- Both are **equivalently robust** for tap lifecycle
- QmouseFix is actually _cleaner_: single-threaded animator thread vs MMF's dual dispatch queues
- MMF's momentum-cancel code is overkill for QmouseFix's ease-to-target (which doesn't coast)

**Verdict: ALREADY GOOD**
- QmouseFix's recovery is solid. No changes needed.
- The `endGestureNow()` pattern (line 119–137) is the key; it's already in place.

---

## Ranked Action List

### **Top 3 Worth Doing**

1. **Add acceleration curve (ADOPT)**
   - Tick-speed acceleration: fast consecutive notches → farther distance
   - Effort: ~60 LOC, simple math
   - Impact: Scroll feels snappier, matches trackpad/browser expectations
   - Do FIRST: Foundation for future feature parity

2. **Optional: Modifier-key scroll rebinding (MAYBE)**
   - Shift/Option → different scroll modes (quick/precise)
   - Effort: ~30 LOC (gate modifiers in tap)
   - Impact: Power users benefit; casual users unaffected
   - Do SECOND: Only if user requests

3. **Document current design strengths (SKIP code, DO docs)**
   - QmouseFix's ease-to-target is **actually cleaner** than MMF's impulse model
   - Single animator thread is more maintainable
   - Frame-rate-independent easing eliminates jitter without extra smoothing
   - Do NOW: Add comments in ScrollAnimator explaining why this works

### **Explicitly Skip**

- **Double-exponential smoothing:** MMF uses it to stabilize tick-time analyzer; QmouseFix's fixed response is simpler and sufficient
- **Type 29 gesture events:** No user-visible gain for mouse wheel use; adds event-posting overhead
- **Momentum-scroll cancellation logic:** QmouseFix doesn't coast; ease-to-target settles automatically
- **Bezier acceleration curves:** Overkill; simple exponential (ScrollSpeedupCurve style) is enough

---

## Unresolved Questions

1. **What is the user's expected scroll feel?** If they primarily use browsers and want "infinite scroll on hold," acceleration is critical. If they prefer deliberate, controlled scrolling (e.g., code editors), flat response is fine. Clarify priority.

2. **Is the animator response time (0.07s / 0.045s) tuned to user preference?** These constants are load-bearing for feel. Does scroll feel "floaty" or "crisp" currently? If floaty, lower response; if too snappy, raise it. The acceleration curve will amplify these differences.

3. **Do any users report scroll stopping intermittently?** MMF has known issues (Scroll.m:36–37, Apr 2025). QmouseFix's design is simpler, but if stops occur, check CADisplayLink invalidation edge cases (sleep/wake/display change).
