import StowKit
import SwiftUI

/// YouTube's comments teaser under the watch page's actions: the count and the top comment; tap
/// for all of them in a sheet. Saved comments show at once (downloaded videos keep theirs).
struct CommentsCard: View {
    let video: Video
    @Environment(Repository.self) private var repository
    @Environment(\.stowColors) private var colors
    @State private var state: LoadState = .loading
    @State private var attempt = 0
    @State private var open = false

    enum LoadState: Equatable {
        case loading
        case loaded(CommentsPage)
        case failed
    }

    var body: some View {
        Button(action: tapped) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Comments").font(.subheadline.weight(.semibold)).foregroundStyle(colors.text)
                    if case .loaded(let page) = state, let count = page.shownCount {
                        Text(Format.shortCount(count)).font(.subheadline).foregroundStyle(colors.secondaryText)
                    }
                }
                switch state {
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("Loading comments…").font(.footnote).foregroundStyle(colors.secondaryText)
                    }
                case .failed:
                    Text("Couldn't load the comments. Tap to try again.").font(.footnote).foregroundStyle(colors.secondaryText)
                case .loaded(let page):
                    if let top = page.threads.first {
                        HStack(spacing: 10) {
                            ChannelAvatar(url: top.authorThumbnail, name: top.author.trimmingPrefix("@").description, size: 24)
                            Text(top.text)
                                .font(.footnote)
                                .foregroundStyle(colors.text)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    } else {
                        Text("No comments yet, or they're turned off.").font(.footnote).foregroundStyle(colors.secondaryText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(colors.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .task(id: "\(video.id)/\(attempt)") {
            state = .loading
            do {
                state = .loaded(try await repository.comments(video, fresh: attempt > 0))
            } catch is CancellationError {
            } catch {
                state = .failed
            }
        }
        .sheet(isPresented: $open) {
            if case .loaded(let page) = state {
                CommentsSheet(page: page, onRefresh: { attempt += 1 }).sheetTheme(repository)
            }
        }
    }

    private func tapped() {
        switch state {
        case .loaded(let page): if !page.threads.isEmpty { open = true }
        case .failed: attempt += 1
        case .loading: break
        }
    }
}

/// Every comment fetched, in YouTube's "Top" order, with their replies folded.
struct CommentsSheet: View {
    let page: CommentsPage
    let onRefresh: () -> Void
    @Environment(\.stowColors) private var colors
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(page.threads) { thread in
                CommentThread(thread: thread)
                    .listRowBackground(colors.raised)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(colors.raised)
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(page.shownCount.map(Format.shortCount) ?? "Top")
                        .font(.subheadline)
                        .foregroundStyle(colors.secondaryText)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") {
                        onRefresh()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(colors.raised)
    }
}

private struct CommentThread: View {
    let thread: Comment
    @State private var showReplies = false
    @Environment(\.stowColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CommentRow(comment: thread, avatar: 32)
            if !thread.replies.isEmpty {
                Button {
                    withAnimation(.snappy) { showReplies.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showReplies ? "chevron.up" : "chevron.down").font(.caption.weight(.bold))
                        Text(thread.replies.count == 1 ? "1 reply" : "\(thread.replies.count) replies")
                            .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(colors.accent)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 42)
                .padding(.top, 4)
                if showReplies {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(thread.replies) { CommentRow(comment: $0, avatar: 24) }
                    }
                    .padding(.leading, 42)
                    .padding(.top, 8)
                }
            }
        }
    }
}

private struct CommentRow: View {
    let comment: Comment
    let avatar: CGFloat
    @State private var showAll = false
    @Environment(\.stowColors) private var colors

    private var isLong: Bool {
        comment.text.count > 300 || comment.text.filter { $0 == "\n" }.count >= 5
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ChannelAvatar(url: comment.authorThumbnail, name: comment.author.trimmingPrefix("@").description, size: avatar)
            VStack(alignment: .leading, spacing: 2) {
                if comment.isPinned {
                    Label("Pinned", systemImage: "pin")
                        .font(.caption2)
                        .foregroundStyle(colors.secondaryText)
                }
                HStack(spacing: 0) {
                    Text(comment.author)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(colors.text)
                        .padding(.horizontal, comment.byUploader ? 6 : 0)
                        .background(comment.byUploader ? colors.chip : .clear, in: Capsule())
                    if let posted = comment.postedAt {
                        Text("  ·  " + Format.ago(posted))
                            .font(.caption)
                            .foregroundStyle(colors.secondaryText)
                    }
                }
                .lineLimit(1)
                Text(comment.text)
                    .font(.subheadline)
                    .foregroundStyle(colors.text)
                    .lineLimit(isLong && !showAll ? 5 : nil)
                    .textSelection(.enabled)
                if isLong {
                    Button(showAll ? "Show less" : "Read more") { showAll.toggle() }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(colors.secondaryText)
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                }
                HStack(spacing: 5) {
                    Image(systemName: "hand.thumbsup").accessibilityLabel("Likes")
                    if comment.likes > 0 { Text(Format.shortCount(comment.likes)) }
                    if comment.isHearted {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(Color(hex: 0xFF3B30))
                            .padding(.leading, 8)
                            .accessibilityLabel("Hearted by the channel")
                    }
                }
                .font(.caption)
                .foregroundStyle(colors.secondaryText)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
