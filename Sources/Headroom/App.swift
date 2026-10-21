import AppKit
import Combine
import SwiftUI
import UserNotifications

@main
enum HeadroomMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var store = UsageStore(settings: settings)
    private var statusController: StatusItemController?
    private let notificationPresenter = NotificationPresenter()
    private let hotKey = HotKey()
    private let shortcutStatus = ShortcutStatus()
    private lazy var updater = Updater()
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var signInWindows: [ServiceID: SignInWindowController] = [:]
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        _ = updater // starts the update checks
        if Notifier.canNotify {
            UNUserNotificationCenter.current().delegate = notificationPresenter
        }

        let actions = PopoverActions(
            openUsagePage: { [weak self] service in
                guard let self = self else { return }
                NSWorkspace.shared.open(self.store.provider(service).usagePageURL)
            },
            openSettings: { [weak self] in self?.showSettings() },
            openHistory: { [weak self] in self?.showHistory() },
            signIn: { [weak self] service in self?.showSignIn(service) },
            quit: { NSApp.terminate(nil) }
        )
        let controller = StatusItemController(store: store, settings: settings, actions: actions)
        statusController = controller

        hotKey.onPress = { [weak controller] in controller?.shortcutPressed() }
        hotKey.onRelease = { [weak controller] in controller?.shortcutReleased() }
        settings.$shortcut
            .combineLatest(settings.$shortcutEnabled)
            .sink { [weak self] shortcut, enabled in self?.registerShortcut(shortcut, enabled: enabled) }
            .store(in: &cancellables)

        store.start()

        if !UserDefaults.standard.bool(forKey: "welcomeShown") {
            showWelcome()
        }
    }

    private func showWelcome() {
        if welcomeWindow == nil {
            let view = WelcomeView(
                store: store, settings: settings,
                signIn: { [weak self] service in self?.showSignIn(service) },
                done: { [weak self] in self?.welcomeWindow?.close() }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Welcome to Headroom"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            welcomeWindow = window
        }
        // Shown once, however it gets closed.
        UserDefaults.standard.set(true, forKey: "welcomeShown")
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    private func registerShortcut(_ shortcut: Shortcut, enabled: Bool) {
        guard enabled else {
            hotKey.unregister()
            shortcutStatus.problem = nil
            return
        }
        do {
            try hotKey.register(shortcut)
            shortcutStatus.problem = nil
        } catch HotKey.RegistrationError.inUse {
            shortcutStatus.problem = "\(shortcut.display) is already used by another app. Pick a different one."
        } catch {
            shortcutStatus.problem = "Couldn't set \(shortcut.display). Pick a different one."
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, store: store, shortcutStatus: shortcutStatus, updater: updater,
                                    signIn: { [weak self] service in self?.showSignIn(service) })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Headroom Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showHistory() {
        if historyWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: HistoryView(history: store.history)))
            window.title = "Headroom History"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            historyWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    private func showSignIn(_ service: ServiceID) {
        if let open = signInWindows[service] {
            NSApp.activate(ignoringOtherApps: true)
            open.window?.makeKeyAndOrderFront(nil)
            return
        }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Start from a clean sign-in, so an old or expired one can't
            // close the window before you've signed in again.
            let provider = self.store.provider(service)
            await WebSession.signOut(domains: provider.cookieDomains)
            let controller = SignInWindowController(
                provider: provider,
                onSuccess: { [weak self] in self?.store.didSignIn(service) },
                onClose: { [weak self] in self?.signInWindows[service] = nil }
            )
            signInWindows[service] = controller
            NSApp.activate(ignoringOtherApps: true)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
    }
}

/// Shows alerts as banners even while the app is active; a click opens that service's usage page.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let raw = response.notification.request.content.userInfo["service"] as? String
        DispatchQueue.main.async {
            let urls: [ServiceID: String] = [
                .claude: "https://claude.ai/settings/usage",
                .chatgpt: "https://chatgpt.com/codex/cloud/settings/analytics#usage",
                .cursor: "https://cursor.com/dashboard",
            ]
            let service = raw.flatMap(ServiceID.init(rawValue:)) ?? .claude
            if let url = URL(string: urls[service] ?? "https://claude.ai/settings/usage") {
                NSWorkspace.shared.open(url)
            }
        }
        completionHandler()
    }
}
