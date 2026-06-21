import ApplicationServices
import AppKit

/// Thin wrapper over the Accessibility (AX) trust API. A mouse event tap requires this permission.
enum AccessibilityPermission {

    /// Whether the app currently has Accessibility permission.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask the system to prompt the user for permission (no-op if already granted).
    @discardableResult
    static func request() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Open System Settings directly to the Accessibility pane.
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
