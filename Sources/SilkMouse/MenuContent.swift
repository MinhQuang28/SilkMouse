import SwiftUI

/// The dropdown shown from the menu-bar icon.
struct MenuContent: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        Toggle("Enabled", isOn: $store.config.enabled)

        Divider()

        if !AccessibilityPermission.isTrusted {
            Button("⚠️ Grant Accessibility…") { AccessibilityPermission.openSettings() }
            Divider()
        }

        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")

        Button("Quit SilkMouse") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
