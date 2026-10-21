import Foundation

/// Cursor usage for both plan generations, read with the cursor.com sign-in:
/// - Legacy plans: two monthly pools ("Cursor models", "Other models") from /api/usage-summary.
/// - New plans (membershipType "unified_…"): the weekly allowance from
///   /api/dashboard/get-sand-usage-status, plus any extra monthly spend.
@MainActor
final class CursorProvider: UsageProvider {
    let service = ServiceID.cursor
    let loginURL = URL(string: "https://cursor.com/dashboard?tab=usage")!
    let usagePageURL = URL(string: "https://cursor.com/dashboard?tab=usage")!
    let cookieDomains = ["cursor.com", "cursor.sh"]

    private let settings: AppSettings
    private var userId: String?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func reset() {
        userId = nil
    }

    private static let sessionCookieNames: Set<String> = [
        "WorkosCursorSessionToken", "__Secure-next-auth.session-token", "next-auth.session-token",
        "wos-session", "__Secure-wos-session", "authjs.session-token", "__Secure-authjs.session-token",
    ]

    func isSignedIn(cookies: [HTTPCookie]) -> Bool {
        cookies.contains { Self.sessionCookieNames.contains($0.name) && !$0.value.isEmpty }
    }

    func fetch() async throws -> ServiceSnapshot {
        let cookies = await WebSession.cookies(for: cookieDomains)
        guard isSignedIn(cookies: cookies) else { throw ProviderError.notSignedIn }
        let cookie = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

        let summaryData = try await get("/api/usage-summary", cookie: cookie)
        guard let summary = JSON.object(summaryData) else { throw ProviderError.unreadable }

        let membership = (summary["membershipType"] as? String ?? "").lowercased()
        let weekly = await weeklyAllowance(cookie: cookie)

        let useNew: Bool
        switch settings.cursorPlan {
        case .automatic: useNew = detectPlan(summary: summary, membership: membership, weekly: weekly)
        case .current: useNew = true
        case .legacy: useNew = false
        }

        let limits: [UsageLimit]
        if useNew {
            limits = try await newPlanLimits(summary: summary, weekly: weekly, cookie: cookie)
        } else {
            limits = try await legacyLimits(summary: summary, cookie: cookie)
        }
        guard !limits.isEmpty else { throw ProviderError.unreadable }
        return ServiceSnapshot(service: .cursor, plan: Self.planName(membership), limits: limits, fetchedAt: Date())
    }

    // MARK: Which plan?

    private static let rememberedPlanKey = "cursorDetectedNewPlan"

    /// The plan name alone isn't reliable, so this also looks at which pool is
    /// actually in use: the weekly allowance (new plan) or the monthly pools
    /// (legacy). The answer is remembered for when nothing is in use yet.
    private func detectPlan(summary: [String: Any], membership: String, weekly: WeeklyAllowance?) -> Bool {
        let limitType = (summary["limitType"] as? String ?? "").lowercased()
        let plan = (summary["individualUsage"] as? [String: Any])?["plan"] as? [String: Any]
        let legacyPercents = ["autoPercentUsed", "apiPercentUsed", "totalPercentUsed"]
            .compactMap { JSON.number(plan?[$0]) }
        let legacyInUse = legacyPercents.contains { $0 > 0 }
            || (JSON.number(plan?["used"]) ?? 0) > 0

        let isNew: Bool
        if limitType == "team" {
            isNew = false
        } else if membership.hasPrefix("unified_") || Self.newPlanTiers.contains(membership) {
            isNew = true
        } else if plan == nil, weekly != nil {
            isNew = true
        } else if let weekly = weekly, weekly.percent > 0, !legacyInUse {
            isNew = true
        } else if legacyInUse {
            isNew = false
        } else if let remembered = UserDefaults.standard.object(forKey: Self.rememberedPlanKey) as? Bool {
            isNew = remembered
        } else {
            isNew = weekly != nil
        }
        UserDefaults.standard.set(isNew, forKey: Self.rememberedPlanKey)
        return isNew
    }

    /// Tier names used by the new subscription.
    private static let newPlanTiers: Set<String> = ["plus", "premium", "super", "x_plus", "x_premium", "x_super"]

    // MARK: New plan (weekly)

    private struct WeeklyAllowance {
        let percent: Double
        let resetsAt: Date?
    }

    // POST /api/dashboard/get-sand-usage-status
    //   { "usagePercent": 62, "nextResetTimestampUtc": "…", "includedLimitZero": false,
    //     "hasNonZeroIncludedLimit": true, … }
    private func weeklyAllowance(cookie: String) async -> WeeklyAllowance? {
        guard let data = try? await post("/api/dashboard/get-sand-usage-status", cookie: cookie),
              let status = JSON.object(data),
              let percent = JSON.number(status["usagePercent"]) else { return nil }
        let available: Bool
        if let zero = status["includedLimitZero"] as? Bool {
            available = !zero
        } else {
            available = (status["hasNonZeroIncludedLimit"] as? Bool) ?? false
        }
        guard available else { return nil }
        return WeeklyAllowance(percent: min(max(percent, 0), 100),
                               resetsAt: JSON.date(status["nextResetTimestampUtc"]))
    }

    private func newPlanLimits(summary: [String: Any], weekly: WeeklyAllowance?, cookie: String) async throws -> [UsageLimit] {
        var limits: [UsageLimit] = []

        if let weekly = weekly {
            limits.append(UsageLimit(id: "weekly_pool", title: "Weekly pool", shortTitle: "Weekly",
                                     percent: weekly.percent, resetsAt: weekly.resetsAt,
                                     note: "Shared with Grok"))
        }

        // Included quota, when the summary still reports one.
        if let percent = Self.totalPercent(summary), limits.isEmpty {
            limits.append(UsageLimit(id: "included", title: "Included usage", shortTitle: "Included",
                                     percent: percent, resetsAt: JSON.date(summary["billingCycleEnd"])))
        }

        // GET /api/dashboard/v2/usage-status?scope=user
        //   { "availability": "available", "monthlyUsage": { "usedCents": 725, "limitCents": 1000, "resetsAt": "…" } }
        if let data = try? await get("/api/dashboard/v2/usage-status?scope=user", cookie: cookie),
           let status = JSON.object(data),
           (status["availability"] as? String) == "available",
           let monthly = status["monthlyUsage"] as? [String: Any],
           let used = JSON.number(monthly["usedCents"]),
           let limit = JSON.number(monthly["limitCents"]), limit > 0 {
            limits.append(UsageLimit(id: "extra_spend", title: "Extra usage this month", shortTitle: "Extra",
                                     percent: nil,
                                     valueText: "\(Format.money(used / 100)) of \(Format.money(limit / 100))",
                                     resetsAt: JSON.date(monthly["resetsAt"])))
        }
        return limits
    }

    // MARK: Legacy plans (monthly)

    // GET /api/usage-summary
    //   { "billingCycleEnd": "…", "membershipType": "pro",
    //     "individualUsage": { "plan": { "used": 1500, "limit": 5000,
    //        "autoPercentUsed": 48.0, "apiPercentUsed": 71.0, "totalPercentUsed": 60.0 }, "onDemand": {…} } }
    // Amounts are in cents; *PercentUsed are already percentages.
    private func legacyLimits(summary: [String: Any], cookie: String) async throws -> [UsageLimit] {
        let reset = JSON.date(summary["billingCycleEnd"])
        let plan = (summary["individualUsage"] as? [String: Any])?["plan"] as? [String: Any]
        var pools: [UsageLimit] = []

        if let api = JSON.number(plan?["apiPercentUsed"]) {
            pools.append(UsageLimit(id: "other_models", title: "Other models", shortTitle: "Other",
                                    percent: Self.clamp(api), resetsAt: reset))
        }
        if let auto = JSON.number(plan?["autoPercentUsed"]) {
            pools.append(UsageLimit(id: "cursor_models", title: "Cursor models", shortTitle: "Cursor",
                                    percent: Self.clamp(auto), resetsAt: reset))
        }
        // The fuller pool leads.
        pools.sort { ($0.percent ?? 0) > ($1.percent ?? 0) }

        if pools.isEmpty, let total = Self.totalPercent(summary) {
            pools.append(UsageLimit(id: "included", title: "Included usage", shortTitle: "Included",
                                    percent: total, resetsAt: reset))
        }

        // Older request-based plans: GET /api/usage?user=ID → { "gpt-4": { "numRequests", "maxRequestUsage" } }
        if pools.isEmpty, let requests = try? await requestUsage(cookie: cookie) {
            pools.append(requests)
        }

        if let onDemand = (summary["individualUsage"] as? [String: Any])?["onDemand"] as? [String: Any],
           (onDemand["enabled"] as? Bool) == true,
           let used = JSON.number(onDemand["used"]), used > 0 {
            let limit = JSON.number(onDemand["limit"]) ?? 0
            let text = limit > 0 ? "\(Format.money(used / 100)) of \(Format.money(limit / 100))" : Format.money(used / 100)
            pools.append(UsageLimit(id: "on_demand", title: "On-demand spend", shortTitle: "On-demand",
                                    percent: nil, valueText: text, resetsAt: reset))
        }
        return pools
    }

    private func requestUsage(cookie: String) async throws -> UsageLimit? {
        if userId == nil {
            let me = try await get("/api/auth/me", cookie: cookie)
            if let sub = JSON.object(me)?["sub"] as? String {
                userId = sub.split(separator: "|").last.map(String.init)
            }
        }
        guard let user = userId,
              let encoded = user.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let data = try await get("/api/usage?user=\(encoded)", cookie: cookie)
        guard let root = JSON.object(data),
              let gpt4 = root["gpt-4"] as? [String: Any],
              let cap = JSON.number(gpt4["maxRequestUsage"]), cap > 0 else { return nil }
        let used = JSON.number(gpt4["numRequestsTotal"]) ?? JSON.number(gpt4["numRequests"]) ?? 0
        var reset: Date?
        if let start = JSON.date(root["startOfMonth"]) ?? Self.dayDate(root["startOfMonth"]) {
            reset = Calendar.current.date(byAdding: .month, value: 1, to: start)
        }
        return UsageLimit(id: "requests", title: "Requests", shortTitle: "Requests",
                          percent: Self.clamp(used / cap * 100),
                          valueText: "\(Int(used)) of \(Int(cap))", resetsAt: reset)
    }

    // MARK: Helpers

    private static func totalPercent(_ summary: [String: Any]) -> Double? {
        let individual = summary["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]
        if let total = JSON.number(plan?["totalPercentUsed"]) { return clamp(total) }
        if let used = JSON.number(plan?["used"]), let limit = JSON.number(plan?["limit"]), limit > 0 {
            return clamp(used / limit * 100)
        }
        let overall = individual?["overall"] as? [String: Any]
        if let used = JSON.number(overall?["used"]), let limit = JSON.number(overall?["limit"]), limit > 0 {
            return clamp(used / limit * 100)
        }
        return nil
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 100) }

    private static func dayDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }

    private static func planName(_ membership: String) -> String? {
        guard !membership.isEmpty else { return nil }
        let base = membership.hasPrefix("unified_") ? String(membership.dropFirst("unified_".count)) : membership
        switch base {
        case "pro": return "Pro"
        case "pro_plus": return "Pro+"
        case "ultra": return "Ultra"
        case "express": return "Start"
        case "hobby": return "Hobby"
        case "free_trial": return "Pro Trial"
        case "pro_student": return "Pro Student"
        default: return base.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func get(_ path: String, cookie: String) async throws -> Data {
        try await WebSession.request(URL(string: "https://cursor.com" + path)!, headers: [
            "Cookie": cookie,
            "Accept": "application/json",
        ])
    }

    private func post(_ path: String, cookie: String) async throws -> Data {
        try await WebSession.request(URL(string: "https://cursor.com" + path)!, method: "POST", headers: [
            "Cookie": cookie,
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Origin": "https://cursor.com",
        ], body: Data("{}".utf8))
    }
}
