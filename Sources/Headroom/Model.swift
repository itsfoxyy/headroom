import AppKit
import Foundation

// MARK: - Services

enum ServiceID: String, CaseIterable, Identifiable, Codable {
    case claude, chatgpt, cursor

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .cursor: return "Cursor"
        }
    }

    /// Service colors from the design (light, dark).
    var color: NSColor {
        switch self {
        case .claude: return Palette.dynamic(light: 0xD97757, dark: 0xE08A6B)
        case .chatgpt: return Palette.dynamic(light: 0x1F8A70, dark: 0x3FB28F)
        case .cursor: return Palette.dynamic(light: 0x5B7BEA, dark: 0x7D97F2)
        }
    }
}

// MARK: - Limits

struct UsageLimit: Identifiable, Equatable {
    let id: String
    /// "Current session", "Weekly · all models", "Codex 5-hour", "Prepaid credit"…
    let title: String
    /// Short form for compact rows: "Session", "Weekly", "5-hour", "Credit".
    let shortTitle: String
    /// 0–100. nil for value-only rows such as a credit balance.
    let percent: Double?
    /// Shown instead of a percentage, e.g. "$8.20".
    let valueText: String?
    let resetsAt: Date?
    /// Extra line, e.g. "Up to 50% of your weekly limit".
    let note: String?

    init(id: String, title: String, shortTitle: String? = nil, percent: Double?, valueText: String? = nil,
         resetsAt: Date? = nil, note: String? = nil) {
        self.id = id
        self.title = title
        self.shortTitle = shortTitle ?? title
        self.percent = percent
        self.valueText = valueText
        self.resetsAt = resetsAt
        self.note = note
    }

    var level: UsageLevel { UsageLevel(percent: percent ?? 0) }
    var isExhausted: Bool { (percent ?? 0) >= 100 }

    var displayValue: String {
        if let value = valueText { return value }
        return Format.percent(percent ?? 0)
    }
}

enum UsageLevel: Equatable {
    case normal, warning, critical

    init(percent: Double) {
        if percent >= 95 {
            self = .critical
        } else if percent >= 80 {
            self = .warning
        } else {
            self = .normal
        }
    }
}

struct ServiceSnapshot: Equatable {
    let service: ServiceID
    /// "Max", "Plus", "Premium"…
    let plan: String?
    /// First limit is the headline one (session, 5-hour, weekly pool).
    let limits: [UsageLimit]
    let fetchedAt: Date

    var primary: UsageLimit? { limits.first }
    /// The line shown under the main bar in the compact layout.
    var secondary: UsageLimit? { limits.count > 1 ? limits[1] : nil }
    /// Everything else; shown when a compact row is expanded.
    var extras: [UsageLimit] { limits.count > 2 ? Array(limits[2...]) : [] }

    /// The highest percentage across this service's limits.
    var tightest: UsageLimit? {
        limits.filter { $0.percent != nil }.max { ($0.percent ?? 0) < ($1.percent ?? 0) }
    }
}

enum ServiceState: Equatable {
    case notConnected
    case loading
    case ok(ServiceSnapshot)
    case signedOut(String?)
    /// Keeps the last good numbers when a refresh fails.
    case failed(String, ServiceSnapshot?)

    var snapshot: ServiceSnapshot? {
        switch self {
        case .ok(let snapshot): return snapshot
        case .failed(_, let snapshot): return snapshot
        default: return nil
        }
    }

    var errorMessage: String? {
        if case .failed(let message, _) = self { return message }
        return nil
    }
}

// MARK: - Errors

enum ProviderError: LocalizedError {
    case notSignedIn
    case rejected
    case http(Int)
    case noAccount
    case unreadable
    case planMoved(String)
    /// Cloudflare asked for a browser check; usually clears after a page refresh.
    case challenge

    /// Errors that a quiet page refresh can often fix.
    var mightRecover: Bool {
        switch self {
        case .notSignedIn, .rejected, .challenge: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in"
        case .rejected: return "Sign-in expired"
        case .http(let code): return "Server error (\(code))"
        case .noAccount: return "Couldn't find your account"
        case .unreadable: return "Couldn't read the usage data"
        case .planMoved(let message): return message
        case .challenge: return "Blocked by a Cloudflare check"
        }
    }
}

// MARK: - Formatting

enum Format {
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// Compact: "2 h 14 m", "14 m", "3 d 2 h".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded(.up)))
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let mins = minutes % 60
        if days > 0 { return hours > 0 ? "\(days) d \(hours) h" : "\(days) d" }
        if hours > 0 { return "\(hours) h \(mins) m" }
        return "\(mins) m"
    }

    static func longDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded(.up)))
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 { return mins > 0 ? "\(hours) h \(mins) min" : "\(hours) h" }
        return "\(mins) min"
    }

    /// "Resets in 2 h 14 min" / "Resets Tue 1:00 PM".
    static func resetText(_ date: Date?, now: Date = Date()) -> String {
        guard let date = date else { return "" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 60 { return "Resets in a moment" }
        if seconds < 12 * 3600 { return "Resets in " + longDuration(seconds) }
        return "Resets " + dayTime(date)
    }

    /// Short form for compact rows: "2 h 14 m" or "Tue 1:00 PM".
    static func shortReset(_ date: Date?, now: Date = Date()) -> String {
        guard let date = date else { return "" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 60 { return "now" }
        if seconds < 12 * 3600 { return duration(seconds) }
        return dayTime(date)
    }

    static func dayTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        formatter.setLocalizedDateFormatFromTemplate(days > 6 ? "dMMM" : "EEEjmm")
        return formatter.string(from: date)
    }

    static func updatedText(_ date: Date?, now: Date = Date()) -> String {
        guard let date = date else { return "Not updated yet" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 10 { return "Updated just now" }
        if seconds < 60 { return "Updated \(Int(seconds)) s ago" }
        if seconds < 3600 { return "Updated \(Int(seconds / 60)) min ago" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "Updated at " + formatter.string(from: date)
    }

    static func money(_ amount: Double, currency: String = "USD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "$%.2f", amount)
    }
}

// MARK: - JSON helpers

enum JSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// Accepts ISO 8601 strings (any fraction length) and epoch seconds or milliseconds.
    static func date(_ value: Any?) -> Date? {
        if let n = value as? NSNumber { return epoch(n.doubleValue) }
        guard let string = value as? String, !string.isEmpty else { return nil }
        if let n = Double(string) { return epoch(n) }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: string) { return d }
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return plain.date(from: trimmed)
    }

    private static func epoch(_ n: Double) -> Date? {
        if n > 1_000_000_000_000 { return Date(timeIntervalSince1970: n / 1000) }
        if n > 1_000_000_000 { return Date(timeIntervalSince1970: n) }
        return nil
    }
}
