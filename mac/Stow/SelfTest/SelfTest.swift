import Foundation

/// `Stow --selftest`: a headless end-to-end check against real YouTube. It resolves the test
/// channels, reads their public and members-only feeds, then runs Core's add/seed/check pipeline.
/// Everything it writes goes to a temporary directory; the user's Application Support files are
/// only read (cookies.txt, copied when present).
@MainActor
enum SelfTest {
    static let argument = "--selftest"
    static let channelInputs = ["@JackhopkinsCEO", "@TQQQCRAZY"]

    /// Prints a summary to stdout. Returns false when anything other than the sign-in is broken.
    static func run() async -> Bool {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "stow-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var ok = true
        func fail(_ message: String) {
            ok = false
            print("  FAIL \(message)")
        }

        print("Stow self-test, \(Date.now.formatted(.iso8601))")
        print("Scratch directory: \(scratch.path)")
        do {
            print("yt-dlp: \(try ToolLocator.url(for: "yt-dlp").path)")
        } catch {
            fail(error.logDescription)
        }

        let cookies = scratch.appending(path: "cookies.txt")
        let signedIn: Bool
        do {
            signedIn = try prepareCookies(at: cookies)
        } catch {
            print("Couldn't prepare cookies: \(error.logDescription)")
            return false
        }
        print(signedIn
              ? "Sign-in: using a copy of \(AppPaths.cookiesFile.path)"
              : "Sign-in: not signed in; members feeds are read with an empty cookie jar")

        let youtube = YouTubeClient()
        for input in channelInputs {
            print("\n\(input)")
            let info: ChannelInfo
            do {
                info = try await youtube.resolveChannel(input: input)
            } catch {
                fail("resolve: \(error.logDescription)")
                continue
            }
            print("  id      \(info.id)")
            print("  title   \(info.title)  \(info.handle ?? "")")
            print("  avatar  \(info.avatarURL?.absoluteString ?? "none")")

            do {
                let videos = try await youtube.fetchPublicVideos(channelId: info.id)
                printVideos("public", videos)
                if videos.isEmpty { fail("public feed returned no videos") }
            } catch {
                fail("public feed: \(error.logDescription)")
            }

            do {
                let feed = try await youtube.fetchMembersVideos(channelId: info.id, cookiesFile: cookies)
                if feed.videos.isEmpty {
                    print("  members no members-only playlist")
                } else {
                    printVideos("members", feed.videos)
                }
                if feed.cookiesRejected { print("  members YouTube rejected the cookies (sign-in expired); videos kept") }
            } catch StowError.authExpired {
                print("  members sign-in expired (YouTube rejected the cookies); handled")
            } catch {
                fail("members feed: \(error.logDescription)")
            }
        }

        if !(await checkPipeline(directory: scratch.appending(path: "support"), cookies: cookies, signedIn: signedIn)) {
            ok = false
        }
        print("\nSelf-test \(ok ? "PASSED" : "FAILED")")
        return ok
    }

    /// Adds the test channels to an AppModel backed by `directory`, then runs a check.
    private static func checkPipeline(directory: URL, cookies: URL, signedIn: Bool) async -> Bool {
        print("\nCore pipeline (store: \(directory.path))")
        let store = Store(directory: directory)
        let model = AppModel(
            youtube: YouTubeClient(), account: FixedAccount(state: signedIn ? .signedIn : .signedOut),
            store: store, notifier: SilentNotifier(), cookiesFile: cookies)
        model.load()
        await model.check(.launch)
        var ok = true
        for input in channelInputs {
            do {
                let channel = try await model.addChannel(input: input)
                let seeded = model.inbox.filter { $0.video.channelId == channel.id }
                print("  added \(channel.title): \(seeded.count) videos seeded to the Inbox")
                if seeded.isEmpty { ok = false }
            } catch {
                print("  FAIL add \(input): \(error.logDescription)")
                ok = false
            }
        }
        await model.checkNow()
        if let check = model.lastCheck {
            print("  check: \(check.channelsChecked) channels, \(check.newVideos) new, \(check.errors.count) errors")
            check.errors.forEach { print("    \($0)") }
            if !check.isOK || check.channelsChecked != channelInputs.count { ok = false }
        } else {
            print("  FAIL no check result")
            ok = false
        }
        do {
            let settings = try store.loadSettings()
            let state = try store.loadState()
            print("  saved settings.json (\(settings.channels.count) channels) and state.json (\(state.inbox.count) Inbox items, signed in: \(model.signInState.rawValue))")
            if settings.channels.count != channelInputs.count || state.inbox.count != model.inbox.count { ok = false }
        } catch {
            print("  FAIL reading saved files: \(error.logDescription)")
            ok = false
        }
        return ok
    }

    /// Copies the real cookies.txt when there is one; otherwise writes an empty cookie jar.
    private static func prepareCookies(at url: URL) throws -> Bool {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: AppPaths.cookiesFile.path) {
            try FileManager.default.copyItem(at: AppPaths.cookiesFile, to: url)
            return true
        }
        try CookieExporter.netscapeFormat([]).write(to: url, atomically: true, encoding: .utf8)
        return false
    }

    private static func printVideos(_ label: String, _ videos: [Video]) {
        print("  \(label.padding(toLength: 7, withPad: " ", startingAt: 0)) \(videos.count) videos")
        for video in videos.prefix(2) {
            let date = video.publishedAt?.formatted(.iso8601.year().month().day()) ?? "undated"
            print("          \(date)  \(video.title)  [\(video.id)]")
        }
    }
}

/// An account whose state never changes; the self-test must not touch the real web data store.
@MainActor
final class FixedAccount: AccountService {
    let state: SignInState

    init(state: SignInState) {
        self.state = state
    }

    func refresh() async -> SignInState { state }
    func signIn() async -> Bool { false }
    func signOut() async {}
    func fetchSubscriptions() async throws -> [ChannelInfo] { throw StowError.notSignedIn }
}

@MainActor
final class SilentNotifier: UserNotifying {
    func requestAuthorization() async -> Bool { true }
    func notifyNewVideos(_ videos: [Video]) {}
    func notifyProblem(title: String, body: String) {}
}
