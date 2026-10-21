import AppKit
import WebKit

/// Loads a service's page in a hidden web view that shares Headroom's sign-in
/// storage. The site's own scripts then renew the session and Cloudflare
/// cookies, the way an open browser tab keeps you signed in.
@MainActor
final class PageRefresh: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Never>?

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WebSession.store
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        webView.customUserAgent = WebSession.userAgent
        super.init()
        webView.navigationDelegate = self
    }

    /// Returns once the page has loaded and had a few seconds to run, or after `timeout`.
    static func load(_ url: URL, timeout: TimeInterval = 25) async {
        let refresh = PageRefresh()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            refresh.continuation = continuation
            refresh.webView.load(URLRequest(url: url))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                refresh.finish()
            }
        }
        refresh.webView.stopLoading()
        refresh.webView.navigationDelegate = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Let the page's scripts refresh the session before we use it.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            finish()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish()
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }
}
