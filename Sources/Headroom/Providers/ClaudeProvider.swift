import Foundation

/// claude.ai, read with the same data its Settings › Usage page uses.
@MainActor
final class ClaudeProvider: UsageProvider {
    let service = ServiceID.claude
    let loginURL = URL(string: "https://claude.ai/login")!
    let usagePageURL = URL(string: "https://claude.ai/settings/usage")!
    let cookieDomains = ["claude.ai"]

    private(set) var manualKey: String?
    private var orgId: String?
    private var plan: String?
    private var orgsLoaded = false

    init() {
        manualKey = Keychain.read("sessionKey")
    }

    var usesManualKey: Bool { !(manualKey ?? "").isEmpty }

    func setManualKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            Keychain.delete("sessionKey")
            manualKey = nil
        } else {
            Keychain.save(trimmed, account: "sessionKey")
            manualKey = trimmed
        }
        reset()
    }

    func reset() {
        orgId = nil
        plan = nil
        orgsLoaded = false
    }

    func isSignedIn(cookies: [HTTPCookie]) -> Bool {
        cookies.contains { $0.name == "sessionKey" && !$0.value.isEmpty }
    }

    func fetch() async throws -> ServiceSnapshot {
        guard let cookie = await cookieHeader() else { throw ProviderError.notSignedIn }

        if orgId == nil { orgId = Self.cookieValue(named: "lastActiveOrg", in: cookie) }
        if !orgsLoaded { await loadOrganizations(cookie: cookie) }
        guard let org = orgId else { throw ProviderError.noAccount }

        let data: Data
        do {
            data = try await get("/api/organizations/\(org)/usage", cookie: cookie)
        } catch ProviderError.http(let code) where code == 404 {
            reset()
            await loadOrganizations(cookie: cookie)
            guard let retry = orgId, retry != org else { throw ProviderError.noAccount }
            data = try await get("/api/organizations/\(retry)/usage", cookie: cookie)
        }

        guard let root = JSON.object(data) else { throw ProviderError.unreadable }
        let limits = Self.parse(root)
        guard !limits.isEmpty else { throw ProviderError.unreadable }
        return ServiceSnapshot(service: .claude, plan: plan, limits: limits, fetchedAt: Date())
    }

    // MARK: Parsing
    //
    // GET /api/organizations/{org}/usage:
    //   { "five_hour": { "utilization": 2.0, "resets_at": "…" },
    //     "seven_day": { "utilization": 3.0, "resets_at": "…" },
    //     "seven_day_opus" / "seven_day_sonnet": { … } | null,
    //     "limits": [ { "scope": { "model": { "display_name": "Fable" } }, "percent": 0, "resets_at": "…" } ] }

    static func parse(_ root: [String: Any]) -> [UsageLimit] {
        var limits: [UsageLimit] = []
        var seen = Set<String>()

        func add(_ limit: UsageLimit) {
            let key = limit.title.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            limits.append(limit)
        }

        if let o = root["five_hour"] as? [String: Any], let p = JSON.number(o["utilization"]) {
            add(UsageLimit(id: "five_hour", title: "Current session", shortTitle: "Session",
                           percent: p, resetsAt: JSON.date(o["resets_at"])))
        }
        if let o = root["seven_day"] as? [String: Any], let p = JSON.number(o["utilization"]) {
            add(UsageLimit(id: "seven_day", title: "Weekly · all models", shortTitle: "Weekly",
                           percent: p, resetsAt: JSON.date(o["resets_at"])))
        }

        // Model-scoped weekly limits (e.g. Fable) — shown even at 0%, like claude.ai does.
        if let entries = root["limits"] as? [[String: Any]] {
            for entry in entries {
                guard let p = JSON.number(entry["percent"]) ?? JSON.number(entry["utilization"]) else { continue }
                let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
                guard let name = model?["display_name"] as? String, !name.isEmpty else { continue }
                let note = (entry["description"] as? String)
                    ?? (entry["subtitle"] as? String)
                add(UsageLimit(id: "model_" + name.lowercased(), title: "Weekly · " + name, shortTitle: name,
                               percent: p, resetsAt: JSON.date(entry["resets_at"]), note: note))
            }
        }

        // Older per-model keys, only while in use.
        for key in root.keys.filter({ $0.hasPrefix("seven_day_") && !$0.contains("oauth") }).sorted() {
            guard let o = root[key] as? [String: Any], let p = JSON.number(o["utilization"]), p >= 1 else { continue }
            let name = key.replacingOccurrences(of: "seven_day_", with: "").capitalized
            add(UsageLimit(id: key, title: "Weekly · " + name, shortTitle: name,
                           percent: p, resetsAt: JSON.date(o["resets_at"])))
        }
        return limits
    }

    // MARK: Private

    private func loadOrganizations(cookie: String) async {
        guard let data = try? await get("/api/organizations", cookie: cookie),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        let chosen = list.first { ($0["uuid"] as? String) == orgId }
            ?? list.first { (($0["capabilities"] as? [String]) ?? []).contains("chat") }
            ?? list.first
        if let chosen = chosen, let uuid = chosen["uuid"] as? String {
            orgId = uuid
            let caps = chosen["capabilities"] as? [String] ?? []
            plan = caps.contains("claude_max") ? "Max" : caps.contains("claude_pro") ? "Pro" : nil
        }
        orgsLoaded = true
    }

    private func cookieHeader() async -> String? {
        if let key = manualKey, !key.isEmpty {
            return key.contains("=") ? key : "sessionKey=\(key)"
        }
        let cookies = await WebSession.cookies(for: cookieDomains)
        guard isSignedIn(cookies: cookies) else { return nil }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func get(_ path: String, cookie: String) async throws -> Data {
        guard let url = URL(string: "https://claude.ai" + path) else { throw ProviderError.unreadable }
        return try await WebSession.request(url, headers: [
            "Cookie": cookie,
            "Accept": "application/json",
            "Referer": usagePageURL.absoluteString,
        ])
    }

    private static func cookieValue(named name: String, in header: String) -> String? {
        for part in header.components(separatedBy: ";") {
            let pieces = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if pieces.count == 2, pieces[0] == name, !pieces[1].isEmpty { return String(pieces[1]) }
        }
        return nil
    }
}
