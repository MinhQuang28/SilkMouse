# MMF PR #1912 analysis + how MMF solves QmouseFix's scroll issues

Clone: `/private/tmp/claude-501/-Users-minhquang-Desktop-code-myproject-QmouseFix/ce7120f1-da87-4122-8505-e03bffcfd33f/scratchpad/mac-mouse-fix` (checked out at `pr-1912`). Scratchpad = session-temp; re-clone if needed later.

## PR #1912 — NOT about scroll. Fixes dock-swipe (Mission Control/Spaces/Show Desktop) on macOS 27

- Author: Nothing1024 (AI-assisted, not core contributor), open, unmerged, +5/-8, 1 file.
- Root cause: macOS 27 changed CGEvent internal struct layout → MMF's custom `CGEventSetIOHIDEvent` (hard-coded ptr offsets `0x18` deref `0xd0`) writes to wrong location → Dock can't read gesture payload.
- Fix: call private `SLEventSetIOHIDEvent(cgEvent, iohidEvent)` from SkyLight.framework instead (SkyLight already linked; linker finds it). File: `Shared/IOKit/CGEventHIDEventBridge.m`.

## Full dock-swipe mechanism (from `Tests/FixDockSwipes.m` + `TouchSimulator.m` + `ModifiedDragOutputThreeFingerSwipe.m`)

Two eras:
- **≤ macOS 26**: synthesize via CGEvent value fields on a type-30 CGEvent: f55=30(type), f110=kIOHIDEventTypeDockSwipe, f132/f134=phase, f124+f135=originOffset (f135 = float32 bits in int64!), f119/f139=weird float-encoded type, f123/f165=MFDockSwipeType (horizontal/vertical/pinch), f136=invertedFromDevice, f129/f130=exitSpeed on end. WORKS on current user OS (Darwin 25 = macOS 26).
- **macOS 27+**: WindowServer ignores value fields; reads IOHIDEvent payload attached to CGEvent. Minimal recreation: `HIDEvent(type: kIOHIDEventTypeDockSwipe)` + options=(phase << kIOHIDEventEventOptionPhaseShift) + fields DockSwipeMotion (h/v/pinch), DockSwipeFlavor (kIOHIDGestureFlavorDockPrimary), DockSwipeProgress (cumulative originOffset). On Ended/Cancelled append child `HIDEvent(type: kIOHIDEventTypeVelocity)` with VelocityX=VelocityY=exitSpeed. Wrap: CGEventCreate → CGEventSetType(30) → SLEventSetIOHIDEvent → CGEventPost(kCGSessionEventTap).

Driving logic (follow-finger, `ModifiedDragOutputThreeFingerSwipe.m:47`):
- progress scale = originOffsetForOneSpace / (screenWidth + 63px separator), where originOffsetForOneSpace = nSpaces==1 ? 2.0 : 1 + 1/(nSpaces-1). Space count via `CGSCopySpaces` SPI.
- phase began on first callback, changed per delta, ended/cancelled on release; **cancelled when sign(lastDelta) != sign(originOffset)** → snaps back (undo swipe).
- exitSpeed = lastDelta*100 → OS finishes transition with momentum.
- "Stuck bug" mitigation: re-send end event at +0.2s and +0.5s (double/triple-send timers) — WindowServer under load drops end events. Known remaining macOS 27 issue: transitions still occasionally stick.
- Pointer frozen during drag (`PointerFreeze`).

## Implication for QmouseFix

`SpaceDragGesture.swift` comment claims "macOS 26+ blocks synthetic dock-swipe gestures in WindowServer — same conclusion MMF reached" → **misdiagnosis**. MMF ships follow-finger dock swipes on 26 (CGEvent fields) and fixes 27 via SkyLight SPI. QmouseFix could upgrade Space-drag from discrete SymbolicHotKey jumps to real follow-finger:
- On user's macOS 26: only CGEvent field method needed (no SkyLight, no HIDEvent headers).
- Cost: private/undocumented API, breaks with OS updates (this PR is the proof), needs stuck-bug double-send workaround. Discrete jumps = simpler & robust; follow-finger = MMF feel.

## Bonus: MMF's answers to our scroll review findings (verified in source)

- **S1 velocity continuity**: `Scroll.m:~705` — new tick mid-animation builds Bezier whose initial slope = current animation speed ("make the initial speed of the baseCurve equal to the current speed", speedSmoothing param) → no velocity jump per notch.
- **S2 momentum tail**: `Shared/Math/Curves/HybridCurves.swift` — BezierHybridCurve = Bezier head (control) + DragCurve tail (friction: dragCoefficient/dragExponent/stopSpeed) → natural deceleration; plus `sendMomentumScrolls` mode emits real momentum-phase events via GestureScrollSimulator.
- **S3 frame timing**: `Shared/Animation/DisplayLink.m` — CVDisplayLink; dt computed from CVTimeStamp `outFrame` (presentation time), NOT wall-clock in callback.
- **S4 display**: `DisplayLink.m:466 linkToDisplayUnderMousePointerWithEvent:` — links to display under mouse pointer, re-links when pointer changes display.
- Fun: `Helper/Core/Scroll/Bug Log [Aug 2025] - Scroll Stopped Working.md` — MMF fought the same "scroll dies" bug class as our B1.

## Unresolved questions
- Does QmouseFix want follow-finger Space-drag (private API risk) or keep discrete jumps?
- macOS 26 field-based dock swipe: verify on user's exact build (26.5?) before building on it.
- PR unmerged/unreviewed by Noah — watch for follow-ups.
