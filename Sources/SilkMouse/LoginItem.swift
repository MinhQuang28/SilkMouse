import ServiceManagement

/// Launch-at-login via SMAppService (macOS 13+). SilkMouse is a single app, so we register the
/// main app bundle itself — no separate helper/daemon needed.
enum LoginItem {

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Register / unregister the app as a login item. Safe to call repeatedly.
    static func setEnabled(_ enabled: Bool) {
        do {
            switch (enabled, SMAppService.mainApp.status) {
            case (true, let s) where s != .enabled:  try SMAppService.mainApp.register()
            case (false, .enabled):                  try SMAppService.mainApp.unregister()
            default:                                  break
            }
        } catch {
            NSLog("SilkMouse: login-item toggle failed: \(error.localizedDescription)")
        }
    }
}
