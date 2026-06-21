import Foundation

/// A single mouse-button → action mapping.
struct ButtonMapping: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var buttonNumber: Int   // 1-based: 1=left, 2=right, 3=middle, 4/5=side buttons, ...
    var action: RemapAction
}

/// The whole persisted configuration. Plain Codable value stored as JSON — no keychain,
/// no license, survives rebuilds.
struct AppConfig: Codable, Sendable {
    var enabled: Bool = true
    var reverseScroll: Bool = false
    var smoothScroll: Bool = false
    var spaceDragButton: Int = 0        // 0 = off; else button held to drag-switch Spaces
    var spaceDragThreshold: Double = 200 // pixels of horizontal drag per Space switch
    var mappings: [ButtonMapping] = AppConfig.defaultMappings

    /// Sensible defaults so the app is useful on first launch.
    static let defaultMappings: [ButtonMapping] = [
        ButtonMapping(buttonNumber: 4, action: .spaceLeft),
        ButtonMapping(buttonNumber: 5, action: .spaceRight),
    ]
}
