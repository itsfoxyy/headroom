import Foundation
import Security
import WebKit

/// Something that can read one service's usage.
@MainActor
protocol UsageProvider: AnyObject {
    var service: ServiceID { get }
    /// The page the sign-in window opens.
    var loginURL: URL { get }
    /// The page "Open usage page" goes to.
    var usagePageURL: URL { get }
    /// Cookie domains the sign-in lives on (cleared on sign-out).
    var cookieDomains: [String] { get }
    /// True when the web sign-in looks complete.
    func isSignedIn(cookies: [HTTPCookie]) -> Bool
    func fetch() async throws -> ServiceSnapshot
    /// Drop anything cached about the account (org IDs, tokens).
    func reset()
}

// MARK: - Shared web session

/// All services share the app's own web storage, filled by the sign-in windows.
@MainActor
enum WebSession {
    /// Same user agent for the sign-in windows and for requests.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static var store: WKWebsiteDataStore { .default() }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    static func cookies(for domains: [String]) async -> [HTTPCookie] {
        let now = Date()
        return await store.httpCookieStore.allCookies().filter { cookie in
            (cookie.expiresDate ?? .distantFuture) > now
                && domains.contains { cookie.domain == $0 || cookie.domain.hasSuffix("." + $0) || cookie.domain == "." + $0 }
        }
    }

    static func cookieHeader(for domains: [String]) async -> String? {
        let cookies = await cookies(for: domains)
        guard !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    static func signOut(domains: [String]) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let matching = records.filter { record in
            domains.contains { record.displayName == $0 || record.displayName.hasSuffix("." + $0) }
        }
        await store.removeData(ofTypes: types, for: matching)
        // Cookies on parent domains aren't always grouped under the record name.
        let cookieStore = store.httpCookieStore
        for cookie in await cookies(for: domains) {
            await cookieStore.deleteCookie(cookie)
        }
    }

    /// GET (or POST) with the given headers; maps HTTP errors to ProviderError.
    static func request(_ url: URL,
                        method: String = "GET",
                        headers: [String: String],
                        body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.unreadable }
        await keepCookies(from: http, url: url)
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw ProviderError.notSignedIn
        case 403:
            if http.value(forHTTPHeaderField: "cf-mitigated") != nil { throw ProviderError.challenge }
            throw ProviderError.rejected
        default: throw ProviderError.http(http.statusCode)
        }
    }

    /// Sites renew sign-ins and Cloudflare cookies through Set-Cookie on their
    /// responses. Save them like a browser would, or the sign-in goes stale.
    private static func keepCookies(from response: HTTPURLResponse, url: URL) async {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { fields[key] = value }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: response.url ?? url)
        guard !cookies.isEmpty else { return }
        let cookieStore = store.httpCookieStore
        for cookie in cookies {
            await cookieStore.setCookie(cookie)
        }
    }
}

// MARK: - Keychain

/// Small secrets (a pasted Claude session key) live in the login Keychain.
enum Keychain {
    private static let service = "Headroom"
    /// Where the early "Claude Usage" builds kept the key; moved on first read.
    private static let legacyService = "ClaudeUsageBar"

    private static func query(_ account: String, service: String = Keychain.service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(_ account: String) -> String? {
        if let value = read(account, service: service) { return value }
        guard let legacy = read(account, service: legacyService) else { return nil }
        save(legacy, account: account)
        SecItemDelete(query(account, service: legacyService) as CFDictionary)
        return legacy
    }

    private static func read(_ account: String, service: String) -> String? {
        var q = query(account, service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String) {
        delete(account)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
