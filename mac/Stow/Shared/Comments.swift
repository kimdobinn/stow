import Foundation

/// A YouTube comment (from yt-dlp's `comments` list), with its replies when it starts a thread.
struct Comment: Identifiable, Equatable, Sendable {
    var id: String
    var author: String
    var authorThumbnail: URL?
    var text: String
    var likes: Int
    var postedAt: Date?
    var isPinned = false
    /// Written by the video's channel.
    var byUploader = false
    /// The channel gave it a heart.
    var isHearted = false
    var replies: [Comment] = []
}

/// A video's top comments, in YouTube's "Top" order.
struct CommentsPage: Equatable, Sendable {
    var threads: [Comment]
    /// YouTube's count of all comments, when it gives one.
    var totalCount: Int?
    /// How many yt-dlp listed (replies whose thread it didn't list included).
    var fetchedCount = 0

    /// The total worth showing: with a limit on how many to fetch, yt-dlp reports just the number
    /// fetched, which would read as the total.
    var shownCount: Int? {
        totalCount.flatMap { $0 > max(fetchedCount, threads.count + threads.reduce(0) { $0 + $1.replies.count }) ? $0 : nil }
    }
}

enum CommentsParser {
    /// Reads yt-dlp's `-j --write-comments` answer: replies are grouped under their thread, in order.
    static func parse(json: Data) -> CommentsPage? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        var threads: [Comment] = []
        var threadIndex: [String: Int] = [:]
        var replies: [(parent: String, comment: Comment)] = []
        let entries = object["comments"] as? [[String: Any]] ?? []
        for entry in entries {
            guard let id = entry["id"] as? String, let text = entry["text"] as? String else { continue }
            let comment = Comment(
                id: id, author: entry["author"] as? String ?? "",
                authorThumbnail: (entry["author_thumbnail"] as? String).flatMap(URL.init(string:)),
                text: text, likes: (entry["like_count"] as? NSNumber)?.intValue ?? 0,
                postedAt: (entry["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                isPinned: entry["is_pinned"] as? Bool ?? false, byUploader: entry["author_is_uploader"] as? Bool ?? false,
                isHearted: entry["is_favorited"] as? Bool ?? false)
            let parent = entry["parent"] as? String ?? "root"
            if parent == "root" {
                threadIndex[id] = threads.count
                threads.append(comment)
            } else {
                replies.append((parent, comment))
            }
        }
        for reply in replies {
            if let index = threadIndex[reply.parent] { threads[index].replies.append(reply.comment) }
        }
        return CommentsPage(threads: threads, totalCount: (object["comment_count"] as? NSNumber)?.intValue, fetchedCount: entries.count)
    }
}
