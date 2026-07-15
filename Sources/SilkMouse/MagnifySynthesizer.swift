import AppKit
import CoreGraphics

/// Synthesizes trackpad pinch-zoom (magnification) gestures from Cmd+scroll-wheel ticks — a real
/// pinch, so it zooms anything a trackpad pinch zooms (browsers, Preview, Maps…), unlike Cmd+"+"
/// key presses.
///
/// Mechanism (mirrors Mac Mouse Fix's TouchSimulator): a type-29 CGEvent (NSEventTypeGesture)
/// whose undocumented fields carry subtype 8 (kIOHIDEventTypeZoom), an IOHIDEvent gesture phase
/// (field 132), and the magnification delta (field 113).
///
/// Stream shape: the first tick opens the gesture (began carries its delta), further ticks are
/// `changed`, and the gesture closes with an empty `ended` after the wheel has been quiet for
/// `endTimeout` (we can't see the Cmd key-up — the tap only listens to mouse events).
///
/// Threading: `feed` runs on the event-tap thread; the end-timeout fires on the main queue.
/// State is guarded by `lock`; CGEventPost is thread-safe.
final class MagnifySynthesizer {

    private let lock = NSLock()
    private var active = false
    private var generation = 0          // invalidates stale end-timeouts
    private let endTimeout = 0.25       // s of wheel silence before the pinch ends

    private let phaseBegan: Int64 = 1   // IOHIDEventPhaseBits
    private let phaseChanged: Int64 = 2
    private let phaseEnded: Int64 = 4

    /// Feed one wheel tick's worth of zoom. `magnification` is the signed pinch delta
    /// (positive = zoom in); `chromiumBoost` should be true when the app under the cursor is a
    /// Chromium browser — they swallow small pinch deltas, so the gesture opens with a big first
    /// step to feel responsive (MMF's long-standing workaround).
    func feed(magnification: Double, chromiumBoost: Bool) {
        guard magnification != 0 else { return }

        lock.lock()
        let opening = !active
        active = true
        generation += 1
        let gen = generation
        lock.unlock()

        var delta = magnification
        if opening {
            if chromiumBoost {
                // Chromium needs a pile of deltas before it starts zooming; front-load them.
                post(phase: phaseBegan, magnification: 0)
                delta += delta > 0 ? 380.0 / 800.0 : -250.0 / 800.0
                post(phase: phaseChanged, magnification: delta)
            } else {
                post(phase: phaseBegan, magnification: delta)
            }
        } else {
            post(phase: phaseChanged, magnification: delta)
        }

        // (Re)arm the end-of-gesture timeout.
        DispatchQueue.main.asyncAfter(deadline: .now() + endTimeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillCurrent = self.generation == gen && self.active
            if stillCurrent { self.active = false }
            self.lock.unlock()
            if stillCurrent { self.post(phase: self.phaseEnded, magnification: 0) }
        }
    }

    /// Close any open pinch immediately (wake/space-switch teardowns).
    func endNow() {
        lock.lock()
        let wasActive = active
        active = false
        generation += 1
        lock.unlock()
        if wasActive { post(phase: phaseEnded, magnification: 0) }
    }

    private func post(phase: Int64, magnification: Double) {
        guard let e = CGEvent(source: nil) else { return }
        e.setDoubleValueField(CGEventField(rawValue: 55)!, value: 29)  // NSEventTypeGesture
        e.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8) // kIOHIDEventTypeZoom
        e.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        e.setDoubleValueField(CGEventField(rawValue: 113)!, value: magnification)
        e.post(tap: .cghidEventTap)
    }
}
