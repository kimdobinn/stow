import os
import StowKit
import SwiftUI
import WebKit

/// "Sign in to YouTube": Google's own login in a web view that keeps nothing on disk. Once
/// youtube.com has a session (LOGIN_INFO and a SAPISID cookie, as on the Mac), its cookies are
/// exported, checked with YouTube, and kept in the Keychain; the web view's store goes with it.
struct SignInScreen: View {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @State private var blocked = false
    @State private var verifying = false
    @State private var failure: String?
    /// Bumped when YouTube refused a sign-in: the web view starts again from Google's login.
    @State private var restart = 0

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                SignInView(restart: restart, onBlocked: { blocked = true }, onSignedIn: signedIn)
                    .ignoresSafeArea(edges: .bottom)
                if blocked {
                    BlockedBanner { useFile() }
                        .padding(12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if verifying {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("Checking the sign-in with YouTube…").foregroundStyle(colors.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(colors.background.opacity(0.92))
                    .transition(.opacity)
                }
            }
            .animation(Motion.standard, value: blocked)
            .animation(Motion.fade, value: verifying)
            .safeAreaInset(edge: .bottom) {
                Button { useFile() } label: {
                    Text("Trouble signing in? Use a cookies.txt file instead")
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .background(colors.raised)
            }
            .navigationTitle("Sign in to YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("Couldn't sign in", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        }
    }

    private func useFile() {
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            shell.importingCookies = true
        }
    }

    private func signedIn(_ cookies: String) {
        guard let standalone = repository.standalone, !verifying else { return }
        verifying = true
        Task {
            defer { verifying = false }
            do {
                try await standalone.signIn(cookies: cookies, source: .web)
                dismiss()
                shell.notify("Signed in to YouTube")
            } catch is CancellationError {
                restart += 1
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "YouTube didn't accept this sign-in."
                // A fresh login behind the alert, so signing in again works without leaving.
                blocked = false
                restart += 1
            }
        }
    }
}

/// Over the web view when Google refuses sign-in in an app.
private struct BlockedBanner: View {
    let useFile: () -> Void
    @Environment(\.stowColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Google won't sign in inside apps on this phone. Use a cookies.txt file instead.")
                .font(.subheadline)
                .foregroundStyle(colors.text)
            PillButton(label: "Use a cookies.txt file", systemImage: "doc.text", filled: true, action: useFile)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

/// The WKWebView: a non-persistent store (nothing reaches disk) and Mobile Safari's exact user
/// agent. WKWebView's own lacks the "Version/… Safari/…" part, which is what Google blocks.
struct SignInView: UIViewRepresentable {
    static let loginURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://www.youtube.com/")!

    /// A new value clears the web view's cookies and opens the login again (after a refused sign-in).
    var restart = 0
    let onBlocked: () -> Void
    let onSignedIn: (String) -> Void

    /// "Version/26.1 Mobile/15E148 Safari/604.1": WebKit puts it after its own part.
    static func applicationName(systemVersion: String) -> String {
        let parts = systemVersion.split(separator: ".")
        let major = parts.first.map(String.init) ?? "17"
        let minor = parts.count > 1 ? String(parts[1]) : "0"
        return "Version/\(major).\(minor) Mobile/15E148 Safari/604.1"
    }

    /// The Mac's done rule: on youtube.com, done loading, and a session whose fingerprint isn't the
    /// one there before (nothing at the start; after a refused sign-in, that one's).
    static func isSignedIn(host: String?, isLoading: Bool, fingerprint: String?, before: String?) -> Bool {
        guard !isLoading, host?.hasSuffix("youtube.com") == true, let fingerprint else { return false }
        return fingerprint != before
    }

    /// Google's "This browser or app may not be secure" page.
    static func isBlocked(url: URL?, title: String?) -> Bool {
        (url?.path.contains("/signin/rejected") ?? false) || (title?.localizedCaseInsensitiveContains("may not be secure") ?? false)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = Self.applicationName(systemVersion: UIDevice.current.systemVersion)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
        webView.load(URLRequest(url: Self.loginURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if restart != context.coordinator.restarted {
            context.coordinator.restarted = restart
            Task { await context.coordinator.startAgain() }
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
        coordinator.closed = true
        // Nothing of the session stays in the web view.
        let store = webView.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        var parent: SignInView
        weak var webView: WKWebView?
        var closed = false
        var restarted = 0
        private var done = false
        /// The session already exported (and refused): only a different one counts as signed in.
        private var exported: String?
        private var loggedAgent = false
        private let log = Logger(subsystem: "dev.stow.ios", category: "sign-in")

        init(_ parent: SignInView) {
            self.parent = parent
            restarted = parent.restart
        }

        /// After a refused sign-in: Google's login again in an emptied store.
        func startAgain() async {
            guard let webView, !closed else { return }
            webView.stopLoading()
            let store = webView.configuration.websiteDataStore
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            guard !closed else { return }
            done = false
            log.info("Sign-in refused: starting again")
            webView.load(URLRequest(url: SignInView.loginURL))
        }

        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in await self.finishIfSignedIn() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if SignInView.isBlocked(url: webView.url, title: webView.title) { parent.onBlocked() }
            #if DEBUG
            if !loggedAgent {
                loggedAgent = true
                webView.evaluateJavaScript("navigator.userAgent") { [log] value, _ in
                    log.info("Sign-in user agent: \(String(describing: value ?? ""), privacy: .public)")
                }
            }
            #endif
            Task { await finishIfSignedIn() }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if SignInView.isBlocked(url: webView.url, title: webView.title) { parent.onBlocked() }
        }

        /// The Mac's rule: on youtube.com, done loading, and a session that wasn't there at the
        /// start (the store starts empty). Then a second for the last redirect's cookies.
        private func finishIfSignedIn() async {
            guard !done, !closed, let webView, !webView.isLoading,
                  webView.url?.host()?.hasSuffix("youtube.com") == true else { return }
            let store = webView.configuration.websiteDataStore.httpCookieStore
            let cookies = await store.allCookies().map(NetscapeCookie.init)
            let fingerprint = NetscapeCookies.sessionFingerprint(cookies)
            guard !done, SignInView.isSignedIn(host: webView.url?.host(), isLoading: webView.isLoading,
                                               fingerprint: fingerprint, before: exported) else { return }
            done = true
            exported = fingerprint
            try? await Task.sleep(for: .seconds(1))
            guard !closed else { return }
            let all = await store.allCookies()
            let text = NetscapeCookies.format(httpCookies: all)
            log.info("Signed in: \(all.count) cookies exported")
            parent.onSignedIn(text)
        }
    }
}
