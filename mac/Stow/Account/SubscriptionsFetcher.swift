import os
import WebKit

/// Loads https://www.youtube.com/feed/channels in a hidden WKWebView sharing
/// `WebDataStore.shared` and collects every page of subscriptions.
///
/// The first page comes from the page's `ytInitialData`. Further pages are requested the way
/// YouTube's own client does (InnerTube `browse` with the continuation token and a SAPISIDHASH
/// header computed from the page's cookies), so no scrolling or visible window is needed.
@MainActor
final class SubscriptionsFetcher: NSObject, WKNavigationDelegate {
    static let feedURL = URL(string: "https://www.youtube.com/feed/channels")!
    static let maxChannels = 500
    static let maxPages = 50

    private let logger = Logger(subsystem: "dev.stow.mac", category: "subscriptions")
    private let webView: WKWebView
    private var navigationWaiter: CheckedContinuation<Void, any Error>?

    override init() {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: WebDataStore.configuration())
        webView.customUserAgent = WebDataStore.userAgent
        super.init()
        webView.navigationDelegate = self
    }

    func fetch() async throws -> [ChannelInfo] {
        try await load(Self.feedURL, timeout: .seconds(45))
        if webView.url?.host()?.hasSuffix("youtube.com") != true { throw StowError.notSignedIn }

        guard let initial = try await webView.callAsyncJavaScript(
            "return window.ytInitialData ? JSON.stringify(window.ytInitialData) : null;",
            contentWorld: .page
        ) as? String else {
            throw StowError.parse("ytInitialData not found on \(Self.feedURL.absoluteString)")
        }

        var page = try SubscriptionsParser.parse(Data(initial.utf8))
        var channels = page.channels
        var seenIds = Set(channels.map(\.id))
        var usedTokens: Set<String> = []
        var pages = 1

        while let token = page.continuation, usedTokens.insert(token).inserted,
              channels.count < Self.maxChannels, pages < Self.maxPages {
            do {
                page = try SubscriptionsParser.parse(try await continuation(token))
            } catch {
                // The first page is still useful; channels can also be added by URL.
                logger.error("Subscriptions continuation failed after \(channels.count) channels: \(error.localizedDescription)")
                break
            }
            pages += 1
            channels += page.channels.filter { seenIds.insert($0.id).inserted }
        }
        return Array(channels.prefix(Self.maxChannels))
    }

    // MARK: Continuations

    private func continuation(_ token: String) async throws -> Data {
        let result = try await webView.callAsyncJavaScript(
            Self.continuationScript,
            arguments: ["token": token],
            contentWorld: .page
        )
        guard let text = result as? String else { throw StowError.parse("empty continuation response") }
        return Data(text.utf8)
    }

    /// Mirrors YouTube's web client: POST /youtubei/v1/browse with the page's INNERTUBE_CONTEXT
    /// and the SAPISIDHASH family of Authorization headers (sha1 of "ts sapisid origin").
    private static let continuationScript = #"""
    const cfg = window.ytcfg;
    if (!cfg) throw new Error('ytcfg missing');
    const origin = 'https://www.youtube.com';
    const jar = Object.fromEntries(document.cookie.split('; ').map(c => {
        const i = c.indexOf('=');
        return [c.slice(0, i), c.slice(i + 1)];
    }));
    const ts = Math.floor(Date.now() / 1000);
    const sha1 = async (text) => {
        const digest = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(text));
        return Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('');
    };
    const schemes = [
        ['SAPISIDHASH', jar['SAPISID'] || jar['__Secure-3PAPISID']],
        ['SAPISID1PHASH', jar['__Secure-1PAPISID']],
        ['SAPISID3PHASH', jar['__Secure-3PAPISID']],
    ];
    const auth = [];
    for (const [scheme, sid] of schemes) {
        if (sid) auth.push(`${scheme} ${ts}_${await sha1(`${ts} ${sid} ${origin}`)}`);
    }
    const headers = {
        'Content-Type': 'application/json',
        'X-Origin': origin,
        'X-Goog-AuthUser': String(cfg.get('SESSION_INDEX') ?? 0),
        'X-Youtube-Client-Name': String(cfg.get('INNERTUBE_CONTEXT_CLIENT_NAME') ?? 1),
        'X-Youtube-Client-Version': String(cfg.get('INNERTUBE_CLIENT_VERSION') ?? ''),
    };
    if (auth.length) headers['Authorization'] = auth.join(' ');
    const pageId = cfg.get('DELEGATED_SESSION_ID');
    if (pageId) headers['X-Goog-PageId'] = pageId;
    const response = await fetch('/youtubei/v1/browse?prettyPrint=false', {
        method: 'POST',
        credentials: 'include',
        headers,
        body: JSON.stringify({ context: cfg.get('INNERTUBE_CONTEXT'), continuation: token }),
    });
    if (!response.ok) throw new Error(`browse HTTP ${response.status}`);
    return await response.text();
    """#

    // MARK: Navigation

    private func load(_ url: URL, timeout: Duration) async throws {
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.finishNavigation(StowError.network("timed out loading \(url.absoluteString)"))
        }
        defer { timeoutTask.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            navigationWaiter = continuation
            webView.load(URLRequest(url: url))
        }
    }

    private func finishNavigation(_ error: (any Error)?) {
        guard let waiter = navigationWaiter else { return }
        navigationWaiter = nil
        if let error {
            webView.stopLoading()
            waiter.resume(throwing: error)
        } else {
            waiter.resume()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failNavigation(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failNavigation(error)
    }

    /// A cancelled navigation was replaced by a newer one (redirect), whose outcome we await.
    private func failNavigation(_ error: any Error) {
        if (error as? URLError)?.code == .cancelled { return }
        finishNavigation(StowError.network(error.localizedDescription))
    }
}
