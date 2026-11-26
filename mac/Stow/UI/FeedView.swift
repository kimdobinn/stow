import SwiftUI

/// YouTube's Home (all its recommendations, followed channels or not) or Subscriptions (its feed
/// plus every followed channel's videos), for the signed-in account. No Shorts, nothing live now.
struct FeedView: View {
    enum Kind { case home, subscriptions }

    @Environment(AppModel.self) private var model
    let kind: Kind

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 20, alignment: .top)]

    private var videos: [Video] { kind == .home ? model.homeVideos : model.subscriptionVideos }

    var body: some View {
        content
            .toolbar {
                ToolbarItem {
                    Button("Refresh", systemImage: "arrow.trianglehead.2.clockwise") {
                        Task { await model.loadAccountFeeds(force: true) }
                    }
                    .help("Read YouTube's \(kind == .home ? "Home" : "Subscriptions") again")
                    .disabled(model.isLoadingAccountFeeds || model.signInState != .signedIn)
                }
            }
            .task { await model.loadAccountFeeds() }
    }

    @ViewBuilder
    private var content: some View {
        if videos.isEmpty {
            if model.isLoadingAccountFeeds {
                ProgressView("Reading YouTube…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.signInState != .signedIn && (kind == .home || model.channels.isEmpty) {
                ContentUnavailableView("Sign In to See \(kind == .home ? "Home" : "Subscriptions")", systemImage: "person.crop.circle",
                                       description: Text("Sign in to YouTube under Account."))
            } else {
                ContentUnavailableView("Nothing Here Yet", systemImage: kind == .home ? "house" : "play.square.stack",
                                       description: Text("Try Refresh in a moment."))
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(videos) { video in
                        VideoCard(video: video,
                                  isWatched: model.isWatched(videoId: video.id),
                                  onOpen: { model.watch(video) },
                                  onToggleWatched: {
                                      withAnimation(.snappy) { model.setWatched(!model.isWatched(videoId: video.id), videoId: video.id) }
                                  },
                                  onDismiss: nil)
                    }
                }
                .padding(24)
            }
        }
    }
}
