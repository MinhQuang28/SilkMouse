import AppKit

/// System media/volume keys, posted as NSSystemDefined events (subtype 8) — the standard way to
/// synthesize the hardware media keys. Raw values are the NX_KEYTYPE_* constants.
enum MediaKey: Int, Codable, Hashable, Sendable {
    case volumeUp   = 0   // NX_KEYTYPE_SOUND_UP
    case volumeDown = 1   // NX_KEYTYPE_SOUND_DOWN
    case mute       = 7   // NX_KEYTYPE_MUTE
    case playPause  = 16  // NX_KEYTYPE_PLAY
    case next       = 17  // NX_KEYTYPE_NEXT
    case previous   = 18  // NX_KEYTYPE_PREVIOUS

    var name: String {
        switch self {
        case .volumeUp:   return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute:       return "Mute"
        case .playPause:  return "Play / Pause"
        case .next:       return "Next Track"
        case .previous:   return "Previous Track"
        }
    }

    /// Press + release of the media key.
    func post() {
        postEvent(keyDown: true)
        postEvent(keyDown: false)
    }

    private func postEvent(keyDown: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: keyDown ? 0xA00 : 0xB00)
        let data1 = (rawValue << 16) | ((keyDown ? 0xA : 0xB) << 8)
        guard let event = NSEvent.otherEvent(with: .systemDefined,
                                             location: .zero,
                                             modifierFlags: flags,
                                             timestamp: 0,
                                             windowNumber: 0,
                                             context: nil,
                                             subtype: 8,
                                             data1: data1,
                                             data2: -1) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
