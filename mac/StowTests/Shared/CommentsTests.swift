import Foundation
import Synchronization
import Testing
@testable import Stow

struct CommentsTests {
    @Test func threadsGatherTheirRepliesInOrder() throws {
        let json = """
        {"comment_count": 1234, "comments": [
          {"id": "a", "parent": "root", "text": "First!", "author": "@ann", "like_count": 1500,
           "timestamp": 1800000000, "is_pinned": true, "author_is_uploader": true, "is_favorited": true,
           "author_thumbnail": "https://yt3.ggpht.com/a.jpg"},
          {"id": "b", "parent": "root", "text": "Second", "author": "@bob"},
          {"id": "a.1", "parent": "a", "text": "reply one", "author": "@cat", "like_count": 3},
          {"id": "a.2", "parent": "a", "text": "reply two", "author": "@dan"},
          {"id": "x.1", "parent": "missing", "text": "orphan", "author": "@eve"},
          {"id": "c", "parent": "root", "author": "@no-text"}
        ]}
        """
        let page = try #require(CommentsParser.parse(json: Data(json.utf8)))
        #expect(page.totalCount == 1234 && page.shownCount == 1234)
        // yt-dlp's count when it's only the number fetched.
        #expect(CommentsParser.parse(json: Data(json.replacingOccurrences(of: "1234", with: "6").utf8))?.shownCount == nil)
        #expect(page.threads.map(\.id) == ["a", "b"])
        let first = page.threads[0]
        #expect(first.replies.map(\.id) == ["a.1", "a.2"])
        #expect(first.likes == 1500 && first.isPinned && first.byUploader && first.isHearted)
        #expect(first.postedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(first.authorThumbnail?.host() == "yt3.ggpht.com")
        #expect(page.threads[1].likes == 0 && page.threads[1].replies.isEmpty && !page.threads[1].isPinned)
    }

    @Test func noCommentsIsAnEmptyPage() throws {
        let page = try #require(CommentsParser.parse(json: Data(#"{"id": "v"}"#.utf8)))
        #expect(page.threads.isEmpty && page.totalCount == nil)
        #expect(CommentsParser.parse(json: Data("not json".utf8)) == nil)
    }

    @Test func countsReadLikeYouTubes() {
        #expect(CommentText.count(950) == "950")
        #expect(CommentText.count(1_000) == "1K")
        #expect(CommentText.count(1_250) == "1.2K")
        #expect(CommentText.count(34_900) == "34K")
        #expect(CommentText.count(1_560_000) == "1.5M")
        #expect(CommentText.count(23_000_000) == "23M")
    }

    @Test func theFetchKeepsTheWorkaroundAndSignsInWhenAsked() {
        let arguments = CommentsFetcher.arguments(videoId: "abc", cookies: URL(filePath: "/tmp/c.txt"))
        let extractor = arguments[arguments.firstIndex(of: "--extractor-args")! + 1]
        #expect(extractor.hasPrefix(YTDLP.youTubeExtractorArgs + ";"))
        #expect(extractor.contains("comment_sort=top"))
        #expect(arguments.contains("--write-comments") && arguments.contains("--skip-download"))
        #expect(arguments.suffix(2) == ["--", "https://www.youtube.com/watch?v=abc"])
        #expect(arguments[arguments.firstIndex(of: "--cookies")! + 1] == "/tmp/c.txt")
        #expect(!CommentsFetcher.arguments(videoId: "abc", cookies: nil).contains("--cookies"))
    }

    @MainActor @Test func theLoaderKeepsPagesAndRetriesFailures() async {
        let calls = Mutex(0)
        let loader = CommentsLoader()
        loader.fetch = { id, _ in
            let call = calls.withLock { $0 += 1; return $0 }
            if id == "bad" && call == 2 { throw StowError.network("offline") }
            return CommentsPage(threads: [Comment(id: "\(id)-1", author: "@a", text: "hi", likes: 1)], totalCount: 1)
        }
        loader.load(videoId: "v1", cookiesFile: nil)
        await loader.settle()
        #expect(loader.state == .loaded(CommentsPage(threads: [Comment(id: "v1-1", author: "@a", text: "hi", likes: 1)], totalCount: 1)))
        loader.load(videoId: "bad", cookiesFile: nil)
        await loader.settle()
        guard case .failed(let message) = loader.state else { Issue.record("expected a failure"); return }
        #expect(message.contains("connection"))
        // Back to the first video: no new fetch.
        loader.load(videoId: "v1", cookiesFile: nil)
        #expect(calls.withLock { $0 } == 2)
        loader.load(videoId: "bad", cookiesFile: nil, retry: true)
        await loader.settle()
        #expect(calls.withLock { $0 } == 3)
        if case .loaded = loader.state {} else { Issue.record("expected comments after retrying") }
    }
}
