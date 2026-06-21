import CoreGraphics
import Foundation

/// Owns the CGEventTap that intercepts mouse buttons and scroll, running on a dedicated
/// high-priority thread (never the main thread — a stalled main thread would time out the tap).
final class EventTapEngine {

    static let shared = EventTapEngine()
    private init() {}

    private var tap: CFMachPort?
    private var thread: Thread?

    // Snapshot read by the tap callback thread; guarded by `lock`.
    private let lock = NSLock()
    private var enabled = true
    private var reverseScroll = false
    private var smoothScroll = false
    private var spaceDragButton = 0
    private var spaceDragThreshold = 200.0
    private var mappingsByButton: [Int: RemapAction] = [:]

    /// Smooth scrolling + drag-to-switch-Spaces; only ever touched on the tap thread.
    private let scrollAnimator = ScrollAnimator()
    private let spaceDrag = SpaceDragGesture()

    /// Start the tap thread (idempotent). Apply `config`.
    func start(config: AppConfig) {
        reload(config)
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "com.qmousefix.event-tap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Update the live snapshot when config changes.
    func reload(_ config: AppConfig) {
        lock.lock()
        enabled = config.enabled
        reverseScroll = config.reverseScroll
        smoothScroll = config.smoothScroll
        spaceDragButton = config.spaceDragButton
        spaceDragThreshold = config.spaceDragThreshold
        mappingsByButton = Dictionary(config.mappings.map { ($0.buttonNumber, $0.action) },
                                      uniquingKeysWith: { first, _ in first })
        lock.unlock()
    }

    // MARK: - Tap thread

    private func threadMain() {
        let mask: CGEventMask =
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: eventTapCallback,
                                          userInfo: refcon) else {
            NSLog("QmouseFix: failed to create event tap — is Accessibility granted?")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }

    /// Called from the tap thread for every event of interest.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a slow/stalled tap — re-enable it (the classic event-tap gotcha).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        let on = enabled
        let maps = mappingsByButton
        let reverse = reverseScroll
        let smooth = smoothScroll
        spaceDrag.button = spaceDragButton
        spaceDrag.threshold = spaceDragThreshold
        lock.unlock()

        guard on else { return Unmanaged.passUnretained(event) }

        switch type {
        case .otherMouseDown, .otherMouseUp:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber)) + 1
            // The Space-drag gesture claims its button before any remap.
            if type == .otherMouseDown, spaceDrag.handleButtonDown(button) { return nil }
            if type == .otherMouseUp,   spaceDrag.handleButtonUp(button)   { return nil }
            if let action = maps[button] {
                if type == .otherMouseDown { action.post() }
                return nil // swallow the original button event
            }
            return Unmanaged.passUnretained(event)

        case .otherMouseDragged:
            // While the gesture is active, feed it the horizontal delta and swallow the drag
            // (this also freezes the cursor during the swipe).
            if spaceDrag.handleDrag(deltaX: event.getDoubleValueField(.mouseEventDeltaX)) { return nil }
            return Unmanaged.passUnretained(event)

        case .scrollWheel:
            // Let our own synthetic pixel events (from the animator) pass straight through.
            if event.getIntegerValueField(.eventSourceUserData) == ScrollAnimator.syntheticTag {
                return Unmanaged.passUnretained(event)
            }
            // Only transform a real mouse wheel (line-based). Leave trackpad/continuous scrolling alone.
            let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            guard !isContinuous else { return Unmanaged.passUnretained(event) }

            let dir = reverse ? -1.0 : 1.0
            let lineV = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * dir
            let lineH = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * dir

            if smooth {
                scrollAnimator.addTick(lineV: lineV, lineH: lineH)
                return nil // swallow; the animator drives a smooth pixel scroll
            }
            if reverse {
                // Integer line + pixel deltas...
                negate(event, .scrollWheelEventDeltaAxis1); negate(event, .scrollWheelEventPointDeltaAxis1)
                negate(event, .scrollWheelEventDeltaAxis2); negate(event, .scrollWheelEventPointDeltaAxis2)
                // ...and the fixed-point deltas, which AppKit actually reads for scrolling.
                negateDouble(event, .scrollWheelEventFixedPtDeltaAxis1)
                negateDouble(event, .scrollWheelEventFixedPtDeltaAxis2)
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// Flip the sign of an integer scroll field in place (used for reverse scrolling).
private func negate(_ event: CGEvent, _ field: CGEventField) {
    event.setIntegerValueField(field, value: -event.getIntegerValueField(field))
}

/// Flip the sign of a fixed-point (double) scroll field in place.
private func negateDouble(_ event: CGEvent, _ field: CGEventField) {
    event.setDoubleValueField(field, value: -event.getDoubleValueField(field))
}

/// Top-level C-compatible callback (CGEventTapCallBack). Forwards to the engine via `refcon`.
private func eventTapCallback(proxy: CGEventTapProxy,
                              type: CGEventType,
                              event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<EventTapEngine>.fromOpaque(refcon).takeUnretainedValue()
    return engine.handle(type: type, event: event)
}
