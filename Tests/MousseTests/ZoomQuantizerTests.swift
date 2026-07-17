import XCTest
@testable import Mousse

/// Guards the macOS 27+ zoom-fallback quantizer: notch parity, storm rate-limiting, bounded
/// backlog, and carry hygiene (direction flips, idle gaps).
final class ZoomQuantizerTests: XCTestCase {

    /// One ratchet notch's magnification — must match the engine's non-continuous zoom tick.
    private let notch = 60.0 / 800.0

    func testSingleNotchFiresImmediately() {
        var q = ZoomQuantizer()
        XCTAssertEqual(q.feed(notch, at: 0), 1)
    }

    func testZoomOutSign() {
        var q = ZoomQuantizer()
        XCTAssertEqual(q.feed(-notch, at: 0), -1)
    }

    func testZeroDeltaIsInert() {
        var q = ZoomQuantizer()
        XCTAssertEqual(q.feed(0, at: 0), 0)
    }

    /// Slow ratchet zooming stays exactly one step per notch.
    func testSlowRatchetIsOneToOne() {
        var q = ZoomQuantizer()
        var fired = 0
        for i in 0..<5 { fired += q.feed(notch, at: 0.2 * Double(i)) }
        XCTAssertEqual(fired, 5)
    }

    /// A continuous-mouse flick (200 tiny ticks ≈ 27 notches' worth in 1 s) must be rate-limited
    /// to ~1 step per minInterval, not fire per event.
    func testContinuousStormIsRateLimited() {
        var q = ZoomQuantizer()
        var fired = 0
        for i in 0..<200 { fired += abs(q.feed(0.01, at: 0.005 * Double(i))) }
        XCTAssertLessThanOrEqual(fired, 11)    // ≈ 1 s / 0.1 s minInterval
        XCTAssertGreaterThanOrEqual(fired, 8)  // but it must still zoom steadily
    }

    /// Hammering many notches inside one rate-limit window owes at most the small bounded
    /// backlog — never one step per notch.
    func testBacklogIsBounded() {
        var q = ZoomQuantizer()
        var fired = 0
        for i in 0..<50 { fired += q.feed(notch, at: 0.001 * Double(i)) } // 50 notches in 50 ms
        // Drain whatever is owed with a trickle of negligible same-direction deltas.
        for k in 1...10 { fired += q.feed(0.0001, at: 0.05 + 0.1 * Double(k)) }
        XCTAssertLessThanOrEqual(fired, 5) // 1 immediate + ≤ maxPendingSteps backlog (+ dust)
        XCTAssertGreaterThanOrEqual(fired, 3)
    }

    /// Reversing direction discards the opposite carry instead of it swallowing the new motion.
    func testDirectionFlipResetsCarry() {
        var q = ZoomQuantizer()
        XCTAssertEqual(q.feed(notch * 0.7, at: 0), 0)      // sub-step zoom-in carry
        XCTAssertEqual(q.feed(-notch, at: 0.2), -1)        // flip fires immediately
    }

    /// Carry left over from an abandoned zoom must not leak into the next one.
    func testIdleGapDiscardsStaleCarry() {
        var q = ZoomQuantizer()
        XCTAssertEqual(q.feed(notch * 0.9, at: 0), 0)      // almost a step, no fire
        XCTAssertEqual(q.feed(notch * 0.2, at: 1.0), 0)    // 1 s later: stale carry is gone
    }

    /// Notches faster than minInterval queue up and drain one per window.
    func testRapidNotchesRespectMinInterval() {
        var q = ZoomQuantizer()
        XCTAssertEqual(q.feed(notch, at: 0), 1)
        XCTAssertEqual(q.feed(notch, at: 0.02), 0)  // too soon — queued
        XCTAssertEqual(q.feed(notch, at: 0.12), 1)  // drains at the next window
    }
}
