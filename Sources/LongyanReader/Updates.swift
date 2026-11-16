import AppKit
import Sparkle

/// Updates through Sparkle. The feed (SUFeedURL in Info.plist) is appcast.xml on the latest
/// GitHub release, and every update is checked against the EdDSA key in SUPublicEDKey before
/// it's installed. Sparkle asks on the second launch whether to check automatically; until the
/// reader says yes, the app only goes online for an update when they choose Check for Updates.
@MainActor
enum Updates {
    /// Only in a built app: run from the repo there's no bundle to replace and no feed key.
    static let available = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil

    private static let delegate = Delegate()
    private static let controller: SPUStandardUpdaterController? = available
        ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: delegate)
        : nil

    static func start() { _ = controller }

    static func checkNow() {
        // A menu-bar app isn't frontmost; the update window should be.
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    private final class Delegate: NSObject, SPUStandardUserDriverDelegate {
        // A menu-bar app has no Dock icon to badge, so a scheduled check that finds an update
        // waits for a moment the reader isn't busy instead of jumping in front of their reading.
        var supportsGentleScheduledUpdateReminders: Bool { true }

        func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                       state: SPUUserUpdateState) {
            if !state.userInitiated { NSApp.activate() }
        }
    }
}
