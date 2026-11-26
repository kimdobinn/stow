import SwiftUI

/// The comments column beside the player: the video's top comments, each with its replies a
/// click away.
struct CommentsView: View {
    @Environment(AppModel.self) private var model
    let videoId: String
    var loader = CommentsLoader.shared

    var body: some View {
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
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .task(id: videoId) { loader.load(videoId: videoId, cookiesFile: model.playbackCookiesFile) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Comments").font(.headline)
            if case .loaded(let page) = loader.state, loader.videoId == videoId, let count = page.shownCount {
                Text(CommentText.count(count)).foregroundStyle(.secondary)
            }
            Spacer()
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
                Text(comment.text)
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

enum CommentText {
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
