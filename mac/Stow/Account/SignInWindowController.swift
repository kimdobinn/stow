import AppKit
import WebKit

/// Window with a WKWebView on the YouTube/Google login, backed by `WebDataStore.shared`.
/// Closes itself once a new youtube.com session appears and YouTube has loaded.
@MainActor
final class SignInWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKHTTPCookieStoreObserver {
    static let loginURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://www.youtube.com/")!

    private let webView: WKWebView
    private var closeWaiters: [CheckedContinuation<Bool, Never>] = []
    /// The session the window opened with. Only a different session counts as a sign-in, so a
    /// stale (expired) session neither closes the window nor reports success.
    private var initialSession: String?
    private var didSignIn = false
    private var isStarted = false
    private var isClosing = false

    init() {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 720), configuration: WebDataStore.configuration())
        webView.customUserAgent = WebDataStore.userAgent
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to YouTube"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Shows the window, activates the app, and returns when the window closes: true when the
    /// user signed in while it was open.
    func run() async -> Bool {
        if !isStarted {
            isStarted = true
            initialSession = CookieExporter.sessionFingerprint(await WebDataStore.cookies())
            WebDataStore.shared.httpCookieStore.add(self)
            webView.load(URLRequest(url: Self.loginURL))
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return await withCheckedContinuation { closeWaiters.append($0) }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        WebDataStore.shared.httpCookieStore.remove(self)
        webView.stopLoading()
        let waiters = closeWaiters
        closeWaiters = []
        waiters.forEach { $0.resume(returning: didSignIn) }
    }

    // MARK: Sign-in detection

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { await closeIfSignedIn() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await closeIfSignedIn() }
    }

    /// Waits until YouTube itself has loaded so every cookie of the sign-in redirect is stored.
    private func closeIfSignedIn() async {
        guard !isClosing, !webView.isLoading, webView.url?.host()?.hasSuffix("youtube.com") == true,
              let session = CookieExporter.sessionFingerprint(await WebDataStore.cookies()),
              session != initialSession
        else { return }
        isClosing = true
        didSignIn = true
        try? await Task.sleep(for: .seconds(1))
        close()
    }
}
