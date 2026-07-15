import AppKit
import CoreGraphics

/// Synthesizes the private "dock swipe" events that drive the real WindowServer Space-slide
/// transition (what a three-finger trackpad swipe produces), so Space-drag can FOLLOW the pointer
/// instead of jumping discretely.
///

/// Threading: gesture state (`originOffset`, `lastDelta`) is touched only on the event-tap thread
/// (same contract as SpaceDragGesture); the end-event re-send bookkeeping lives on the main queue.
final class DockSwipeSynthesizer {

    enum SwipeType: Int64 { case horizontal = 1, vertical = 2 }          // MFDockSwipeType
    enum Phase: Int64 { case began = 1, changed = 2, ended = 4, cancelled = 8 } // IOHIDEventPhaseBits

    /// Field-based synthesis works through macOS 26; macOS 27 ignores the fields.
    static let isSupported = ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27

    private let dockSwipeSubtype: Double = 23 // kIOHIDEventTypeDockSwipe

    // Per-gesture state — tap thread only.
    private var originOffset = 0.0 // cumulative progress; the OS animates the transition from this
    private var lastDelta = 0.0    // release direction + exit speed come from the final movement

    // Re-send bookkeeping — main queue only (see `scheduleEndResends`).
    private var resendGeneration = 0

    /// originOffset units per pixel of horizontal drag, so one screen-width of drag ≈ one Space —
    /// 's empirically-derived scaling. More Spaces need less progress each; 63 px is the
    /// inter-Space separator width. Thread-safe (CoreGraphics + SkyLight SPI only, no AppKit).
    static func horizontalScale() -> Double {
        let width = CGDisplayBounds(CGMainDisplayID()).width
        let n = spaceCount()
        let perSpace = n <= 1 ? 2.0 : 1.0 + 1.0 / Double(n - 1)
        return perSpace / (width + 63)
    }

    /// Number of Spaces via the CGSCopySpaces SPI (fullscreen Spaces appear twice — deduped).
    /// Falls back to 3 (scale ≈1.5/screen-width) if the private symbols ever disappear.
    private static func spaceCount() -> Int {
        typealias MainConnectionID = @convention(c) () -> Int32
        typealias CopySpaces = @convention(c) (Int32, Int32) -> Unmanaged<CFArray>?
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let cidSym = dlsym(rtldDefault, "CGSMainConnectionID"),
              let copySym = dlsym(rtldDefault, "CGSCopySpaces") else { return 3 }
        let cid = unsafeBitCast(cidSym, to: MainConnectionID.self)()
        let mask: Int32 = 0b111 // current | others | user
        guard let spaces = unsafeBitCast(copySym, to: CopySpaces.self)(cid, mask)?
            .takeRetainedValue() as? [AnyObject] else { return 3 }
        return max(1, NSSet(array: spaces).count)
    }

    /// Feed one gesture step. `delta` is progress (already scaled/signed by the caller);
    /// began carries the first movement, ended/cancelled carry 0.
    func post(delta: Double, type: SwipeType, phase: Phase) {
        var phase = phase
        switch phase {
        case .began:
            originOffset = delta
            lastDelta = delta
            DispatchQueue.main.async { self.resendGeneration += 1 } // kill pending end re-sends
        case .changed:
            guard delta != 0 else { return }
            originOffset += delta
            lastDelta = delta
        case .ended:
            // Released while moving back toward the start → cancel, so the OS snaps back instead
            // of completing the switch (same "undo" a real trackpad swipe reversal gets).
            if (lastDelta > 0) != (originOffset > 0) { phase = .cancelled }
        case .cancelled:
            break
        }
        let exitSpeed = (phase == .ended || phase == .cancelled) ? lastDelta * 100 : 0

        guard let e30 = makeSwipeEvent(phase: phase, type: type, exitSpeed: exitSpeed),
              let e29 = makeCompanionEvent() else { return }
        e30.post(tap: .cgSessionEventTap)
        e29.post(tap: .cgSessionEventTap)

        if phase == .ended || phase == .cancelled {
            // WindowServer under load drops end events, leaving the transition stuck mid-slide;
            // re-sending them at +0.2 s and +0.5 s unsticks it (a long-standing upstream workaround).
            DispatchQueue.main.async { self.scheduleEndResends(e30, e29) }
        }
    }

    /// Main queue only: re-post the end events unless a newer gesture began meanwhile.
    private func scheduleEndResends(_ e30: CGEvent, _ e29: CGEvent) {
        resendGeneration += 1
        let generation = resendGeneration
        for delay in [0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.resendGeneration == generation else { return }
                e30.post(tap: .cgSessionEventTap)
                e29.post(tap: .cgSessionEventTap)
            }
        }
    }

    /// The type-30 event carrying the DockSwipe payload in undocumented value fields. Every field
    /// number/encoding is copied verbatim from 's TouchSimulator (its comments admit several
    /// are cargo-culted from captured real events — they are what WindowServer accepts).
    private func makeSwipeEvent(phase: Phase, type: SwipeType, exitSpeed: Double) -> CGEvent? {
        guard let e = CGEvent(source: nil) else { return nil }
        func setD(_ field: UInt32, _ value: Double) { e.setDoubleValueField(CGEventField(rawValue: field)!, value: value) }
        func setI(_ field: UInt32, _ value: Int64) { e.setIntegerValueField(CGEventField(rawValue: field)!, value: value) }
        setD(55, 30)                    // event type
        setD(110, dockSwipeSubtype)     // subtype: this is a dock swipe
        setD(132, Double(phase.rawValue))
        setD(134, Double(phase.rawValue))
        setD(124, originOffset)
        setI(135, Int64(Float32(originOffset).bitPattern)) // same offset, float32 bits in an int64
        setD(41, 33231)
        // Fields 119/139 hold the swipe type as a float32 BIT PATTERN read as a float ('s
        // "weird constants" 1.4e-45 / 2.8e-45 are exactly bitPattern 1 / 2).
        let typeFloat = Double(Float32(bitPattern: UInt32(type.rawValue)))
        setD(119, typeFloat)
        setD(139, typeFloat)
        setD(123, Double(type.rawValue))
        setD(165, Double(type.rawValue))
        setI(136, 0) // invertedFromDevice: direction is handled by the caller's delta sign
        if phase == .ended || phase == .cancelled {
            setD(129, exitSpeed) // the OS finishes the slide with this momentum
            setD(130, exitSpeed)
        }
        return e
    }

    /// The bare type-29 (NSEventTypeGesture) companion  posts alongside every swipe event.
    private func makeCompanionEvent() -> CGEvent? {
        guard let e = CGEvent(source: nil) else { return nil }
        e.setDoubleValueField(CGEventField(rawValue: 55)!, value: 29)
        e.setDoubleValueField(CGEventField(rawValue: 41)!, value: 33231)
        return e
    }
}
