import SwiftUI

/// The comments column beside the player: the video's top comments, each with its replies a
/// click away.
struct CommentsView: View {
    @Environment(AppModel.self) private var model
    let videoId: String
    /// Clicking a timestamp ("7:15") in a comment.
    var onSeek: ((TimeInterval) -> Void)? = nil
    var loader = CommentsLoader.shared
    @AppStorage(CommentsPlacement.storageKey) private var placement: CommentsPlacement = .below

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
        .task(id: videoId) { loader.load(videoId: videoId, cookiesFile: model.playbackCookiesFile) }
        .environment(\.openURL, OpenURLAction { url in
            guard let seconds = CommentText.seconds(fromSeekURL: url) else { return .systemAction }
            onSeek?(seconds)
            return .handled
        })
    }

    @ViewBuilder
    private var list: some View {
        Group {
            switch loader.videoId == videoId ? loader.state : .loading {
            case .idle, .loading:
                ProgressView("Loading comments…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("No Comments", systemImage: "exclamationmark.bubble")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { loader.load(videoId: videoId, cookiesFile: model.playbackCookiesFile, retry: true) }
                }
            case .loaded(let page) where page.threads.isEmpty:
                ContentUnavailableView("No Comments", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Nobody has commented yet, or comments are off."))
            case .loaded(let page):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(page.threads) { CommentThreadRow(thread: $0) }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Comments").font(.headline)
            if case .loaded(let page) = loader.state, loader.videoId == videoId, let count = page.shownCount {
                Text(CommentText.count(count)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(.snappy(duration: 0.25)) { placement = placement == .below ? .beside : .below }
            } label: {
                Image(systemName: placement == .below ? "rectangle.righthalf.inset.filled" : "rectangle.bottomhalf.inset.filled")
            }
            .buttonStyle(.borderless)
            .help(placement == .below ? "Show the comments beside the video" : "Show the comments under the video")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// A comment and, once opened, its replies.
private struct CommentThreadRow: View {
    let thread: Comment
    @State private var showsReplies = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CommentRow(comment: thread, avatarSize: 28)
            if !thread.replies.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showsReplies.toggle() }
                } label: {
                    Label(thread.replies.count == 1 ? "1 reply" : "\(thread.replies.count) replies",
                          systemImage: showsReplies ? "chevron.up" : "chevron.down")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .padding(.leading, 38)
                if showsReplies {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(thread.replies) { CommentRow(comment: $0, avatarSize: 22) }
                    }
                    .padding(.leading, 38)
                }
            }
        }
    }
}

private struct CommentRow: View {
    let comment: Comment
    let avatarSize: CGFloat
    @State private var showsAll = false

    /// Long comments show their first lines until "Read more".
    private var isLong: Bool {
        comment.text.count > 320 || comment.text.filter(\.isNewline).count >= 6
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: comment.authorThumbnail) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(.quaternary)
            }
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                if comment.isPinned {
                    Label("Pinned", systemImage: "pin").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(comment.author)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, comment.byUploader ? 6 : 0)
                        .padding(.vertical, comment.byUploader ? 1 : 0)
                        .background(comment.byUploader ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
                    if let postedAt = comment.postedAt {
                        Text(postedAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(CommentText.linked(comment.text))
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(isLong && !showsAll ? 5 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                if isLong {
                    Button(showsAll ? "Show less" : "Read more") { showsAll.toggle() }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Label(comment.likes > 0 ? CommentText.count(comment.likes) : "", systemImage: "hand.thumbsup")
                    if comment.isHearted {
                        Image(systemName: "heart.fill").foregroundStyle(.red).help("Hearted by the channel")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
    }
}

/// Where the comments go in the player panel.
enum CommentsPlacement: String {
    case below, beside
    static let storageKey = "commentsPlacement"
}

enum CommentText {
    static let seekScheme = "stow-seek"

    /// The timestamps in a comment ("7:15", "1:02:03"), with their offsets in seconds.
    static func timestamps(in text: String) -> [(range: Range<String.Index>, seconds: TimeInterval)] {
        let ns = text as NSString
        return stampPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            func group(_ i: Int) -> Int? {
                let range = match.range(at: i)
                return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
            }
            guard let minutes = group(2), let seconds = group(3), seconds < 60,
                  let range = Range(match.range, in: text) else { return nil }
            let hours = group(1) ?? 0
            if hours > 0 && minutes >= 60 { return nil }
            return (range, TimeInterval(hours * 3600 + minutes * 60 + seconds))
        }
    }

    private static let stampPattern = try! NSRegularExpression(pattern: #"(?<![\d:])(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?![\d:])"#)

    /// The comment with its timestamps as links that seek the video.
    static func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for stamp in timestamps(in: text) {
            guard let lower = AttributedString.Index(stamp.range.lowerBound, within: result),
                  let upper = AttributedString.Index(stamp.range.upperBound, within: result) else { continue }
            result[lower..<upper].link = URL(string: "\(seekScheme):\(Int(stamp.seconds))")
        }
        return result
    }

    static func seconds(fromSeekURL url: URL) -> TimeInterval? {
        guard url.scheme == seekScheme else { return nil }
        return TimeInterval(url.absoluteString.dropFirst(seekScheme.count + 1))
    }

    /// 950, 1.2K, 34K, 1.5M: YouTube's short counts.
    static func count(_ value: Int) -> String {
        switch value {
        case ..<1_000: "\(value)"
        case ..<10_000: trimmed(Double(value) / 1_000) + "K"
        case ..<1_000_000: "\(value / 1_000)K"
        case ..<10_000_000: trimmed(Double(value) / 1_000_000) + "M"
        default: "\(value / 1_000_000)M"
        }
    }

    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded(.down) / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}
