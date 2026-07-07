import SwiftUI
import AppKit

/// "Click here with a mouse button" field — captures which physical button you press (like MMF),
/// so you never have to guess button numbers. Reports the 1-based button number via `onCapture`.
struct ButtonCaptureField: View {
    var onCapture: (Int) -> Void

    @State private var capturing = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            HStack {
                Image(systemName: capturing ? "cursorarrow.click.badge.clock" : "plus.circle.fill")
                Text(capturing
                     ? "Now click the mouse button you want…  (⎋ cancels)"
                     : "Click here with a mouse button to add a mapping")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .foregroundStyle(capturing ? .orange : .accentColor)
        }
        .onDisappear { stop() }
    }

    private func toggle() { capturing ? stop() : start() }

    private func start() {
        capturing = true
        EventTapEngine.shared.setCaptureMode(true) // let the click reach this window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .keyDown]) { event in
            if event.type == .keyDown {
                if event.keyCode == 53 { stop(); return nil } // Esc cancels
                return event
            }
            let button = event.buttonNumber + 1 // 0-based → 1-based (middle = 3, side = 4/5…)
            stop()
            onCapture(button)
            return nil // swallow the captured click
        }
    }

    private func stop() {
        capturing = false
        EventTapEngine.shared.setCaptureMode(false)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
