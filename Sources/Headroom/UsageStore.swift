import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var states: [ServiceID: ServiceState] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    /// The compact row that's expanded, if any. Kept here so the dropdown resizes.
    @Published var expandedService: ServiceID?

    let settings: AppSettings
    let claude = ClaudeProvider()
    let chatgpt = ChatGPTProvider()
    let cursor: CursorProvider
    private let notifier = Notifier()
    private var timer: Timer?
    private var lastAttempt: Date?
    private var wakeObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings
        cursor = CursorProvider(settings: settings)
        for service in ServiceID.allCases {
            states[service] = settings.connected.contains(service) ? .loading : .notConnected
        }

        settings.$refreshMinutes
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.schedule() } }
            .store(in: &cancellables)
        settings.$notificationsEnabled
            .dropFirst()
            .sink { enabled in if enabled { Notifier.requestPermission() } }
            .store(in: &cancellables)
        settings.$cursorPlan
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.cursor.reset()
                    await self?.refresh(.cursor)
                }
            }
            .store(in: &cancellables)
    }

    func provider(_ service: ServiceID) -> UsageProvider {
        switch service {
        case .claude: return claude
        case .chatgpt: return chatgpt
        case .cursor: return cursor
        }
    }

    // MARK: Reading state

    var connected: [ServiceID] { settings.connected }

    /// Connected services with numbers, the one closest to a limit first.
    var ranked: [ServiceSnapshot] {
        connected.compactMap { states[$0]?.snapshot }
            .sorted { ($0.tightest?.percent ?? 0) > ($1.tightest?.percent ?? 0) }
    }

    /// The single limit closest to running out, across all services.
    var closest: (ServiceSnapshot, UsageLimit)? {
        for snapshot in ranked {
            if let limit = snapshot.tightest { return (snapshot, limit) }
        }
        return nil
    }

    var anyError: String? {
        for service in connected {
            if let message = states[service]?.errorMessage { return "\(service.name): \(message)" }
        }
        return nil
    }

    // MARK: Refreshing

    func start() {
        schedule()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Give Wi-Fi a moment to reconnect after sleep.
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await self?.refreshAll()
            }
        }
        if settings.notificationsEnabled { Notifier.requestPermission() }
        Task { await refreshAll() }
    }

    func refreshIfStale() {
        if let last = lastAttempt, Date().timeIntervalSince(last) < 30 { return }
        Task { await refreshAll() }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastAttempt = Date()
        await withTaskGroup(of: Void.self) { group in
            for service in connected {
                group.addTask { await self.refresh(service) }
            }
        }
        lastRefresh = Date()
        isRefreshing = false
    }

    func refresh(_ service: ServiceID) async {
        guard connected.contains(service) else {
            states[service] = .notConnected
            return
        }
        let previous = states[service]?.snapshot
        if previous == nil { states[service] = .loading }
        do {
            let snapshot = try await fetchRecovering(service)
            states[service] = .ok(snapshot)
            if settings.notificationsEnabled { notifier.check(snapshot) }
        } catch let error as ProviderError {
            switch error {
            case .notSignedIn:
                states[service] = .signedOut(nil)
            case .rejected:
                states[service] = .signedOut("Your \(service.name) sign-in expired. Sign in again.")
            case .planMoved(let message):
                states[service] = .signedOut(message)
            case .challenge:
                states[service] = .failed("\(service.name) is asking for a browser check. Retrying shortly", previous)
            default:
                states[service] = .failed(error.localizedDescription, previous)
            }
        } catch {
            let offline = (error as? URLError)?.code == .notConnectedToInternet
            states[service] = .failed(offline ? "You're offline" : "Couldn't reach \(service.name)", previous)
        }
    }

    /// If a service refuses the request, let its website renew the sign-in in a
    /// hidden page (as an open browser tab would), then try once more.
    private func fetchRecovering(_ service: ServiceID) async throws -> ServiceSnapshot {
        let p = provider(service)
        do {
            return try await p.fetch()
        } catch let error as ProviderError where error.mightRecover {
            let cookies = await WebSession.cookies(for: p.cookieDomains)
            guard p.isSignedIn(cookies: cookies) else { throw error }
            await PageRefresh.load(p.usagePageURL)
            p.reset()
            return try await p.fetch()
        }
    }

    // MARK: Connecting

    func didSignIn(_ service: ServiceID) {
        if service == .claude, claude.usesManualKey { claude.setManualKey(nil) }
        provider(service).reset()
        settings.connect(service)
        Task { await refresh(service) }
    }

    func signOut(_ service: ServiceID) async {
        let p = provider(service)
        if service == .claude { claude.setManualKey(nil) }
        await WebSession.signOut(domains: p.cookieDomains)
        p.reset()
        settings.disconnect(service)
        states[service] = .notConnected
    }

    func setClaudeKey(_ key: String?) {
        claude.setManualKey(key)
        if claude.usesManualKey { settings.connect(.claude) }
        Task { await refresh(.claude) }
    }

    private func schedule() {
        timer?.invalidate()
        let interval = TimeInterval(max(1, settings.refreshMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
        timer?.tolerance = 10
    }
}

// MARK: - Notifications

final class Notifier {
    private let defaultsKey = "sentAlerts2"
    private var sent: [String]

    init() {
        sent = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    static var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// One alert per threshold per limit window; re-arms when the window resets.
    func check(_ snapshot: ServiceSnapshot) {
        let thresholds = [95, 80]
        for limit in snapshot.limits {
            guard let percent = limit.percent else { continue }
            let window = Int((limit.resetsAt?.timeIntervalSince1970 ?? 0) / 3600)
            guard let threshold = thresholds.first(where: { percent >= Double($0) }) else { continue }
            let base = "\(snapshot.service.rawValue)|\(limit.id)"
            if sent.contains("\(base)|\(threshold)|\(window)") { continue }
            for t in thresholds where t <= threshold {
                sent.append("\(base)|\(t)|\(window)")
            }
            post(snapshot.service, limit, percent: percent, threshold: threshold)
        }
        if sent.count > 300 { sent.removeFirst(sent.count - 300) }
        UserDefaults.standard.set(sent, forKey: defaultsKey)
    }

    private func post(_ service: ServiceID, _ limit: UsageLimit, percent: Double, threshold: Int) {
        guard Self.canNotify else { return }
        let content = UNMutableNotificationContent()
        let value = Format.percent(percent)
        content.title = threshold >= 95
            ? "\(service.name) · \(limit.title): almost used up"
            : "\(service.name) · \(limit.title): \(value) used"
        let reset = Format.resetText(limit.resetsAt)
        content.body = reset.isEmpty ? "\(value) used" : "\(value) used · \(reset)"
        content.sound = .default
        content.userInfo = ["service": service.rawValue]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
