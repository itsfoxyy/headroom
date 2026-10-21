import AppKit
import Combine
import Sparkle

/// Automatic updates through Sparkle. Updates are only offered when the app was
/// built with an update feed and signing key (see Scripts/setup_updates.sh), so
/// local builds without them simply don't check.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController?
    private let driverDelegate = UpdateDriverDelegate()

    @Published var automaticallyChecks: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        if !key.isEmpty, !feed.isEmpty {
            let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                          userDriverDelegate: driverDelegate)
            self.controller = controller
            automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        } else {
            controller = nil
            automaticallyChecks = false
        }
    }

    var isAvailable: Bool { controller != nil }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}

/// Headroom has no Dock icon, so bring the update window forward when an
/// update is found in the background instead of leaving it behind other apps.
final class UpdateDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if handleShowingUpdate {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
