import Foundation

/// A YouTube comment (from yt-dlp's `comments` list), with its replies when it starts a thread.
public struct Comment: Hashable, Sendable, Identifiable {
    public var id: String
    public var author: String
    public var authorThumbnail: String?
    public var text: String
    public var likes: Int
    public var postedAt: Date?
    public var isPinned: Bool
    /// Written by the video's channel.
    public var byUploader: Bool
    /// The channel gave it a heart.
    public var isHearted: Bool
    public var replies: [Comment]

    public init(id: String, author: String, authorThumbnail: String?, text: String, likes: Int, postedAt: Date?,
                isPinned: Bool = false, byUploader: Bool = false, isHearted: Bool = false, replies: [Comment] = []) {
        self.id = id
        self.author = author
        self.authorThumbnail = authorThumbnail
        self.text = text
        self.likes = likes
        self.postedAt = postedAt
        self.isPinned = isPinned
        self.byUploader = byUploader
        self.isHearted = isHearted
        self.replies = replies
    }
}

/// A video's top comments in YouTube's "Top" order, and YouTube's count of all of them.
public struct CommentsPage: Hashable, Sendable {
    public var threads: [Comment]
    public var totalCount: Int?
    public var fetchedCount: Int

    public init(threads: [Comment], totalCount: Int?, fetchedCount: Int = 0) {
        self.threads = threads
        self.totalCount = totalCount
        self.fetchedCount = fetchedCount
    }

    /// YouTube's count of all comments, when yt-dlp gave it. With a limit on how many to fetch it
    /// reports just the number fetched, which would read as the total.
    public var shownCount: Int? {
        guard let totalCount else { return nil }
        let fetched = max(fetchedCount, threads.count + threads.reduce(0) { $0 + $1.replies.count })
        return totalCount > fetched ? totalCount : nil
    }
}

public enum Comments {
    /// yt-dlp's max_comments: in all, top-level, replies in all, replies per thread.
    public static let limits = "80,40,60,6"

    /// Reads yt-dlp's `-j --write-comments` answer, or the trimmed copy `trim` saves. Replies are
    /// grouped under their thread in order; ones whose thread is missing are dropped.
    public static func parse(_ json: String) throws -> CommentsPage {
        let root = try JSONObject(parsing: json)
        let raw = root.array("comments") ?? []
        var threads: [Comment] = []
        var replies: [String: [Comment]] = [:]
        for entry in raw {
            guard let o = JSONObject(any: entry), let id = o.string("id") else { continue }
            guard o.has("text"), !o.isNull("text") else { continue }
            let comment = Comment(
                id: id,
                author: o.raw["author"] as? String ?? "",
                authorThumbnail: o.string("author_thumbnail"),
                text: o.raw["text"] as? String ?? "",
                likes: o.int("like_count") ?? 0,
                postedAt: o.number("timestamp").map(Date.init(epochSeconds:)),
                isPinned: o.bool("is_pinned"),
                byUploader: o.bool("author_is_uploader"),
                isHearted: o.bool("is_favorited")
            )
            let parent = o.isNull("parent") ? "root" : (o.raw["parent"] as? String ?? "root")
            if parent == "root" { threads.append(comment) } else { replies[parent, default: []].append(comment) }
        }
        let total = root.isNull("comment_count") ? nil : root.int("comment_count")
        return CommentsPage(threads: threads.map { thread in
            var thread = thread
            thread.replies = replies[thread.id] ?? []
            return thread
        }, totalCount: total, fetchedCount: raw.count)
    }

    /// Just the comments and their count from yt-dlp's answer (which also lists every format), to keep.
    public static func trim(_ json: String) throws -> String {
        let root = try JSONObject(parsing: json)
        var trimmed: [String: Any] = ["comments": root.array("comments") ?? []]
        if !root.isNull("comment_count"), let count = root.int("comment_count") { trimmed["comment_count"] = count }
        let data = try JSONSerialization.data(withJSONObject: trimmed)
        return String(decoding: data, as: UTF8.self)
    }
}
