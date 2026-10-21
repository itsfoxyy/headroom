import AppKit
import WebKit

/// A small browser window showing a service's own login page. The sign-in is
/// kept in the app's private web storage, which the providers then reuse.
@MainActor
final class SignInWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    let service: ServiceID
    private let webView: WKWebView
    private let provider: UsageProvider
    private let onSuccess: () -> Void
    private let onClose: () -> Void
    private var pollTimer: Timer?
    private var finished = false

    init(provider: UsageProvider, onSuccess: @escaping () -> Void, onClose: @escaping () -> Void) {
        service = provider.service
        self.provider = provider
        self.onSuccess = onSuccess
        self.onClose = onClose

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WebSession.store
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = WebSession.userAgent
        web.translatesAutoresizingMaskIntoConstraints = false
        webView = web

        let hint = NSTextField(wrappingLabelWithString:
            "Passkeys and some Google sign-ins don't work in this window. Use email sign-in if they fail.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(web)
        container.addSubview(hint)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hint.topAnchor.constraint(equalTo: web.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            hint.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to \(provider.service.name)"
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: provider.loginURL))

        // Logins often finish inside the page without a reload, so also poll.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSignedIn() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        onClose()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkSignedIn()
    }

    /// Pop-ups (some sign-in providers open one) load in this same window.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    private func checkSignedIn() {
        guard !finished, window?.isVisible == true else { return }
        Task { @MainActor in
            let cookies = await WebSession.cookies(for: provider.cookieDomains)
            guard provider.isSignedIn(cookies: cookies), !finished else { return }
            finished = true
            pollTimer?.invalidate()
            onSuccess()
            close()
        }
    }
}
