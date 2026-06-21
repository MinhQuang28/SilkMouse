import CoreGraphics
import AppKit

/// What a remapped mouse button does. Keystroke actions cover spaces/Mission Control and any custom
/// shortcut; media keys cover volume/playback; `launchpad` opens Launchpad. All via public APIs.
enum RemapAction: Codable, Equatable, Hashable, Sendable {
    case keyStroke(keyCode: UInt16, control: Bool, option: Bool, command: Bool, shift: Bool)
    case mediaKey(MediaKey)
    case launchpad

    // Keystroke presets (macOS default shortcuts)
    static let spaceLeft      = keyStroke(keyCode: 0x7B, control: true, option: false, command: false, shift: false) // Ctrl+←
    static let spaceRight     = keyStroke(keyCode: 0x7C, control: true, option: false, command: false, shift: false) // Ctrl+→
    static let missionControl = keyStroke(keyCode: 0x7E, control: true, option: false, command: false, shift: false) // Ctrl+↑
    static let appExpose      = keyStroke(keyCode: 0x7D, control: true, option: false, command: false, shift: false) // Ctrl+↓

    /// Actions offered in the Settings picker.
    static var presets: [RemapAction] {
        [.spaceLeft, .spaceRight, .missionControl, .appExpose, .launchpad,
         .mediaKey(.volumeDown), .mediaKey(.volumeUp), .mediaKey(.mute),
         .mediaKey(.playPause), .mediaKey(.previous), .mediaKey(.next)]
    }

    /// Perform the action.
    func post() {
        switch self {
        case let .keyStroke(code, control, option, command, shift):
            let src = CGEventSource(stateID: .hidSystemState)
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
                  let up   = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else { return }
            var flags: CGEventFlags = []
            if control { flags.insert(.maskControl) }
            if option  { flags.insert(.maskAlternate) }
            if command { flags.insert(.maskCommand) }
            if shift   { flags.insert(.maskShift) }
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)

        case let .mediaKey(key):
            key.post()

        case .launchpad:
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Launchpad.app"))
            }
        }
    }

    /// Human-readable name for the UI.
    var displayName: String {
        switch self {
        case .keyStroke:
            if self == .spaceLeft      { return "Move Left a Space" }
            if self == .spaceRight     { return "Move Right a Space" }
            if self == .missionControl { return "Mission Control" }
            if self == .appExpose      { return "App Exposé" }
            guard case let .keyStroke(code, control, option, command, shift) = self else { return "—" }
            var s = ""
            if control { s += "⌃" }
            if option  { s += "⌥" }
            if shift   { s += "⇧" }
            if command { s += "⌘" }
            return s + KeyCodes.name(for: code)
        case let .mediaKey(key):
            return key.name
        case .launchpad:
            return "Launchpad"
        }
    }
}
