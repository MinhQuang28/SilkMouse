import AppKit
import CoreGraphics

/// Resolves which app owns the window under the mouse pointer — the app that will RECEIVE a scroll
/// event (macOS routes scrolling to the window under the cursor, not the focused app), so the
/// scroll-exclusion list must match against this, not the frontmost app.
///
/// Tap-thread only (called from the event-tap callback for scroll events), so no locking: the short
/// result cache and the pid→bundle-ID cache are single-threaded by construction.
final class CursorAppResolver {

    // Window lookup via CGWindowListCopyWindowInfo costs a fraction of a millisecond but scroll
    // ticks arrive at up to display rate — cache the answer briefly. 0.2 s is far shorter than a
    // human moving the cursor from one app's window into another's and starting to scroll.
    private var cachedBundleID: String?
    private var cachedAt = 0.0
    private var cachedPoint = CGPoint.zero
    private let cacheWindow = 0.2   // s a resolution stays valid
    private let cacheRadius = 16.0  // px the cursor may drift before we re-resolve

    // pid → bundle ID never changes for a live process; NSRunningApplication lookup is the pricey
    // part, so memoize it. Stale entries for exited pids are harmless (pids recycle slowly and a
    // wrong hit only mislabels one gesture) and the map stays tiny.
    private var bundleIDByPID: [pid_t: String] = [:]

    /// Bundle ID of the app owning the topmost normal window containing `point`
    /// (CG global coordinates, as `CGEvent.location` reports). `nil` when nothing matches.
    func bundleID(at point: CGPoint) -> String? {
        let now = CFAbsoluteTimeGetCurrent()
        if now - cachedAt < cacheWindow,
           abs(point.x - cachedPoint.x) < cacheRadius, abs(point.y - cachedPoint.y) < cacheRadius {
            return cachedBundleID
        }
        cachedBundleID = resolve(at: point)
        cachedAt = now
        cachedPoint = point
        return cachedBundleID
    }

    private func resolve(at point: CGPoint) -> String? {
        // Front-to-back on-screen windows; kCGWindowBounds is in the same top-left-origin global
        // space as CGEvent.location, so plain rect containment is the full hit test.
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            // Layer 0 = ordinary app windows; skips the menu bar, Dock, and overlay layers, whose
            // huge transparent windows would otherwise shadow the real target.
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point),
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t
            else { continue }
            return bundleID(for: pid)
        }
        return nil
    }

    private func bundleID(for pid: pid_t) -> String? {
        if let known = bundleIDByPID[pid] { return known }
        guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return nil }
        bundleIDByPID[pid] = id
        return id
    }
}
