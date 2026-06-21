import QuartzCore

/// Hold a mouse button and drag horizontally to switch Spaces — one discrete jump per `threshold`
/// pixels of drag. Driven by the Ctrl+←/→ shortcut, so no private API is needed.
///
/// Why discrete (not follow-finger): macOS 26+ blocks synthetic dock-swipe gestures in WindowServer,
/// so a smooth 1:1 animation isn't possible from a 3rd-party app — discrete jumps are the supported
/// behaviour (the same conclusion Mac Mouse Fix reached for macOS 26/27).
///
/// State here is touched only on the event-tap thread; `button`/`threshold` are set from the same
/// thread at the top of each callback, so no locking is needed.
final class SpaceDragGesture {

    var button = 0          // 0 = disabled, else the 1-based button that triggers the gesture
    var threshold = 200.0   // pixels of horizontal drag per Space switch

    private let cooldown = 0.28 // seconds between switches — roughly the slide-animation duration
    private var active = false
    private var accumX = 0.0
    private var lastSwitch = 0.0

    var isActive: Bool { active }

    /// Returns true if the gesture consumed this button-down.
    func handleButtonDown(_ buttonNumber: Int) -> Bool {
        guard button != 0, buttonNumber == button else { return false }
        active = true
        accumX = 0
        return true
    }

    /// Returns true if the gesture consumed this button-up.
    func handleButtonUp(_ buttonNumber: Int) -> Bool {
        guard active, buttonNumber == button else { return false }
        active = false
        return true
    }

    /// Returns true if a drag was consumed (i.e. the gesture is active).
    func handleDrag(deltaX: Double) -> Bool {
        guard active else { return false }
        accumX += deltaX

        let now = CACurrentMediaTime()
        if abs(accumX) >= threshold, now - lastSwitch >= cooldown {
            (accumX < 0 ? RemapAction.spaceLeft : RemapAction.spaceRight).post()
            accumX = 0
            lastSwitch = now
        } else if abs(accumX) > threshold {
            accumX = accumX < 0 ? -threshold : threshold // clamp while waiting out the cooldown
        }
        return true
    }
}
