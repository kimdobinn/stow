import Foundation
import os

@MainActor
final class AccountManager: AccountService {
    private let cookiesFile: URL
    private let logger = Logger(subsystem: "dev.stow.mac", category: "account")
    private var signInWindow: SignInWindowController?

    init(cookiesFile: URL = AppPaths.cookiesFile) {
        self.cookiesFile = cookiesFile
    }

    /// Re-exports cookies.txt from the data store. YouTube rotates cookies, so Core calls this
    /// (via the protocol) right before every check that runs yt-dlp.
    func refresh() async -> SignInState {
        await exportCookies()
    }

    func signIn() async -> Bool {
        let window = signInWindow ?? SignInWindowController()
        signInWindow = window
        let didSignIn = await window.run()
        if signInWindow === window { signInWindow = nil }
        return await exportCookies() == .signedIn && didSignIn
    }

    func signOut() async {
        signInWindow?.close()
        await WebDataStore.removeAll()
        removeCookiesFile()
        CookieCopy.removeAll(for: cookiesFile)
        // Videos looked up ahead were looked up as the signed-in account.
        StreamCache.removeAll()
    }

    func fetchSubscriptions() async throws -> [ChannelInfo] {
        guard CookieExporter.isSignedIn(await WebDataStore.cookies()) else { throw StowError.notSignedIn }
        return try await SubscriptionsFetcher().fetch()
    }

    /// Writes cookies.txt when signed in; deletes it otherwise so yt-dlp never sees stale cookies.
    @discardableResult
    func exportCookies() async -> SignInState {
        let cookies = await WebDataStore.cookies()
        guard CookieExporter.isSignedIn(cookies) else {
            removeCookiesFile()
            return .signedOut
        }
        do {
            try CookieExporter.write(cookies, to: cookiesFile)
        } catch {
            logger.error("Could not write cookies.txt: \(error.localizedDescription)")
        }
        return .signedIn
    }

    private func removeCookiesFile() {
        try? FileManager.default.removeItem(at: cookiesFile)
    }
}
