import SwiftUI
import AppKit

/// Shows a mapping's action and lets the user either pick a preset or record a custom shortcut.
/// Recording uses a local key-down monitor so the captured combo never leaks to other UI.
struct ShortcutControl: View {
    @Binding var action: RemapAction
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Group {
            if recording {
                Button("Press keys…  (⎋ cancels)") { stopRecording() }
                    .foregroundStyle(.orange)
            } else {
                Menu(action.displayName) {
                    Section("Presets") {
                        ForEach(RemapAction.presets, id: \.self) { preset in
                            Button(preset.displayName) { action = preset }
                        }
                    }
                    Divider()
                    Button("Record Custom Shortcut…") { startRecording() }
                }
            }
        }
        .frame(width: 190)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil } // Esc cancels
            let mods = event.modifierFlags
            action = .keyStroke(keyCode: event.keyCode,
                                control: mods.contains(.control),
                                option:  mods.contains(.option),
                                command: mods.contains(.command),
                                shift:   mods.contains(.shift))
            stopRecording()
            return nil // swallow the captured key so it doesn't trigger anything
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
