import SwiftUI

/// The Settings window (⌘,). Three tabs: General, Buttons, Scroll.
struct SettingsView: View {
    @EnvironmentObject var store: ConfigStore
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        TabView {
            generalTab.tabItem  { Label("General", systemImage: "gearshape") }
            buttonsTab.tabItem  { Label("Buttons", systemImage: "computermouse") }
            scrollTab.tabItem   { Label("Scroll", systemImage: "scroll") }
            gesturesTab.tabItem { Label("Gestures", systemImage: "hand.draw") }
        }
        .frame(width: 480, height: 360)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Toggle("Enable QmouseFix", isOn: $store.config.enabled)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    LoginItem.setEnabled(newValue)
                    launchAtLogin = LoginItem.isEnabled // resync to the real status
                }
            LabeledContent("Accessibility") {
                if AccessibilityPermission.isTrusted {
                    Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Grant…") { AccessibilityPermission.openSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var buttonsTab: some View {
        ButtonMappingsView()
    }

    private var scrollTab: some View {
        Form {
            Toggle("Smooth scrolling", isOn: $store.config.smoothScroll)
            Toggle("Reverse scroll direction", isOn: $store.config.reverseScroll)
            Text("Applies to a physical mouse wheel only — trackpad scrolling is left untouched.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var gesturesTab: some View {
        Form {
            Picker("Drag to switch Spaces", selection: $store.config.spaceDragButton) {
                Text("Off").tag(0)
                ForEach(3...9, id: \.self) { Text("Button \($0)").tag($0) }
            }
            if store.config.spaceDragButton != 0 {
                VStack(alignment: .leading) {
                    Text("Drag distance per Space: \(Int(store.config.spaceDragThreshold)) px")
                    Slider(value: $store.config.spaceDragThreshold, in: 100...400, step: 10)
                }
            }
            Text("Hold the chosen button and drag left/right to switch Spaces — one jump per drag distance. (macOS 26+ only supports discrete jumps, not a smooth follow-finger animation.)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
