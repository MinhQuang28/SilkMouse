import SwiftUI

/// QmouseFix — a lean, single-process menu-bar mouse utility for macOS 15+.
/// Original codebase (not derived from any other app); uses only public macOS APIs.
@main
struct QmouseFixApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ConfigStore.shared

    var body: some Scene {
        MenuBarExtra("QmouseFix", systemImage: "computermouse.fill") {
            MenuContent().environmentObject(store)
        }
        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

/// App lifecycle: run as a menu-bar accessory (no Dock icon), ensure Accessibility,
/// and bring up the event-tap engine.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Held for the app's lifetime: exempts the process from App Nap and timer coalescing. A napped
    /// (windowless, "idle-looking") agent gets its run-loop timers coalesced to ~1 s, so after an
    /// idle period the scroll animator's display link can lag a full second behind the first wheel
    /// tick — the wheel input is consumed but nothing moves until the nap lifts. Latency-critical is
    /// the right class for real-time input synthesis; allowing idle system sleep means this never
    /// keeps the Mac awake.
    private var noNapActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
        noNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Real-time mouse input processing")

        if !AccessibilityPermission.isTrusted {
            AccessibilityPermission.request() // shows the system prompt once
        }
        EventTapEngine.shared.start(config: ConfigStore.shared.config)
    }
}
