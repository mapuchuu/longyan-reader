import AppKit
import ServiceManagement

/// Open at Login, through SMAppService: macOS lists the app under Login Items in System
/// Settings, where the reader can also turn it off.
@MainActor
enum LoginItem {
    /// Only for the built app: run from the repo there's no bundle to open at login.
    static var available: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        guard available else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("login item: %@", error.localizedDescription)
        }
        // Turned off earlier in System Settings, it needs turning on there.
        if on && SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
