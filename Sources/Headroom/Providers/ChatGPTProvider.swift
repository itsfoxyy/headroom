import Foundation

/// ChatGPT's Codex limits (the 5-hour and weekly windows), read with the
/// chatgpt.com sign-in, the same data its Codex usage page uses.
@MainActor
final class ChatGPTProvider: UsageProvider {
    let service = ServiceID.chatgpt
    let loginURL = URL(string: "https://chatgpt.com/auth/login")!
    let usagePageURL = URL(string: "https://chatgpt.com/codex/cloud/settings/analytics#usage")!
    let cookieDomains = ["chatgpt.com"]

    private var accessToken: String?

    func reset() {
        accessToken = nil
    }

    func isSignedIn(cookies: [HTTPCookie]) -> Bool {
        cookies.contains { cookie in
            let name = cookie.name.lowercased()
            return !cookie.value.isEmpty && name.contains("session-token")
        }
    }

    func fetch() async throws -> ServiceSnapshot {
        let cookies = await WebSession.cookies(for: cookieDomains)
        guard isSignedIn(cookies: cookies) else { throw ProviderError.notSignedIn }
        let cookie = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

        let data: Data
        do {
            data = try await usage(cookie: cookie)
        } catch ProviderError.notSignedIn {
            // Some accounts need a bearer token from the web session as well.
            accessToken = try await sessionToken(cookie: cookie)
            data = try await usage(cookie: cookie)
        }

        guard let root = JSON.object(data) else { throw ProviderError.unreadable }
        let limits = Self.parse(root)
        guard !limits.isEmpty else { throw ProviderError.unreadable }
        let plan = (root["plan_type"] as? String).map(Self.planName)
        return ServiceSnapshot(service: .chatgpt, plan: plan, limits: limits, fetchedAt: Date())
    }

    // MARK: Parsing
    //
    // GET https://chatgpt.com/backend-api/wham/usage
    //   { "plan_type": "plus",
    //     "rate_limit": { "primary_window":   { "used_percent": 22, "reset_at": 1766948068, "limit_window_seconds": 18000 },
    //                     "secondary_window": { "used_percent": 43, "reset_at": 1767407914, "limit_window_seconds": 604800 } },
    //     "credits": { "has_credits": true, "unlimited": false, "balance": 150.0 },
    //     "additional_rate_limits": [ { "limit_name": "…", "rate_limit": { "primary_window": {…}, "secondary_window": {…} } } ] }
    // Windows are told apart by length, not by primary/secondary.

    static func parse(_ root: [String: Any]) -> [UsageLimit] {
        var limits: [UsageLimit] = []
        let windows = Self.windows(root["rate_limit"] as? [String: Any])
        if let session = windows.first(where: { $0.seconds <= 6 * 3600 }) {
            limits.append(UsageLimit(id: "codex_5h", title: "Codex · 5-hour", shortTitle: "5-hour",
                                     percent: session.percent, resetsAt: session.resetsAt))
        }
        if let weekly = windows.first(where: { $0.seconds > 6 * 3600 }) {
            limits.append(UsageLimit(id: "codex_weekly", title: "Codex · weekly", shortTitle: "Weekly",
                                     percent: weekly.percent, resetsAt: weekly.resetsAt))
        }
        // A response without window lengths: keep the order the server gave.
        if limits.isEmpty {
            for (index, window) in windows.enumerated() {
                limits.append(UsageLimit(id: "codex_\(index)", title: index == 0 ? "Codex · 5-hour" : "Codex · weekly",
                                         shortTitle: index == 0 ? "5-hour" : "Weekly",
                                         percent: window.percent, resetsAt: window.resetsAt))
            }
        }

        if let extra = root["additional_rate_limits"] as? [[String: Any]] {
            for item in extra {
                guard let name = item["limit_name"] as? String, !name.isEmpty else { continue }
                let found = Self.windows(item["rate_limit"] as? [String: Any])
                guard let tightest = found.max(by: { $0.percent < $1.percent }) else { continue }
                limits.append(UsageLimit(id: "extra_" + name, title: name, shortTitle: name,
                                         percent: tightest.percent, resetsAt: tightest.resetsAt))
            }
        }

        if let credits = root["credits"] as? [String: Any],
           (credits["has_credits"] as? Bool) == true,
           (credits["unlimited"] as? Bool) != true,
           let balance = JSON.number(credits["balance"]), balance > 0 {
            let text = balance.rounded() == balance ? String(Int(balance)) : String(format: "%.1f", balance)
            limits.append(UsageLimit(id: "credits", title: "Codex credits", shortTitle: "Credits",
                                     percent: nil, valueText: text))
        }
        return limits
    }

    private struct Window {
        let percent: Double
        let resetsAt: Date?
        let seconds: Double
    }

    private static func windows(_ rateLimit: [String: Any]?) -> [Window] {
        guard let rateLimit = rateLimit else { return [] }
        return ["primary_window", "secondary_window"].compactMap { key in
            guard let w = rateLimit[key] as? [String: Any], let percent = JSON.number(w["used_percent"]) else { return nil }
            return Window(percent: percent,
                          resetsAt: JSON.date(w["reset_at"]),
                          seconds: JSON.number(w["limit_window_seconds"]) ?? 0)
        }
    }

    private static func planName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "go": return "Go"
        case "free": return "Free"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu", "education": return "Edu"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: Requests

    private func usage(cookie: String) async throws -> Data {
        var headers = [
            "Cookie": cookie,
            "Accept": "application/json",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        if let token = accessToken { headers["Authorization"] = "Bearer \(token)" }
        return try await WebSession.request(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers)
    }

    private func sessionToken(cookie: String) async throws -> String {
        let data = try await WebSession.request(URL(string: "https://chatgpt.com/api/auth/session")!, headers: [
            "Cookie": cookie,
            "Accept": "application/json",
        ])
        guard let token = JSON.object(data)?["accessToken"] as? String,
              !token.isEmpty, !token.contains(" ") else { throw ProviderError.notSignedIn }
        return token
    }
}
