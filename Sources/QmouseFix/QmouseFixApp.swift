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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar only, no Dock icon

        if !AccessibilityPermission.isTrusted {
            AccessibilityPermission.request() // shows the system prompt once
        }
        EventTapEngine.shared.start(config: ConfigStore.shared.config)
    }
}
