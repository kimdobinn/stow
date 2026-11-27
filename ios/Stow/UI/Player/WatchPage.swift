import StowKit
import SwiftUI

/// The watch page, over the whole app while it's open: the video, its title and channel, the
/// actions (watched, download, save, speed, delete), the comments and Up next. Drag the video
/// down (or tap the chevron) to shrink it into the mini player; turn the phone, drag the video
/// up or tap the full screen button for full screen.
struct WatchPage: View {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(PlaybackController.self) private var controller
    @Environment(\.stowColors) private var colors
    @State private var pull: CGFloat = 0
    @State private var confirmDelete = false

    var body: some View {
        GeometryReader { proxy in
            let fullScreen = proxy.size.width > proxy.size.height
            Group {
                if fullScreen {
                    video(fullScreen: true)
                        .ignoresSafeArea()
                } else {
                    VStack(spacing: 0) {
                        video(fullScreen: false)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .zIndex(1)
                        details
                    }
                    .background(colors.background)
                }
            }
            .background((fullScreen ? Color.black : colors.background).ignoresSafeArea())
            .offset(y: pull)
            .animation(.interactiveSpring, value: pull)
        }
        .onAppear { Orientation.allowLandscape(true) }
        .onDisappear { Orientation.allowLandscape(false) }
        .confirmationDialog("Delete from downloads?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let item = controller.current { shell.actions.delete(item) }
            }
        }
    }

    private func video(fullScreen: Bool) -> some View {
        PlayerVideoArea(
            controller: controller,
            fullScreen: fullScreen,
            onCollapse: collapse,
            onFullScreen: { Orientation.setFullScreen($0) },
            onPull: { pull = $0 },
            onPullEnd: { distance, velocity in
                if distance > 120 || velocity > 900 { collapse() } else { pull = 0 }
            }
        )
    }

    private func collapse() {
        withAnimation(.spring(duration: 0.35, bounce: 0)) {
            shell.playerExpanded = false
        }
        pull = 0
    }

    // MARK: - Under the video

    @ViewBuilder private var details: some View {
        if let item = controller.current {
            // Up next plays within the same queue; opening a channel shrinks the player first.
            let actions = shell.actions.playing { controller.jump(to: $0.id) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header(item)
                    channelRow(item)
                    actionPills(item)
                    CommentsCard(video: item.video).id(item.id)
                    let upNext = controller.upNext
                    if !upNext.isEmpty {
                        SectionHeader("Up next")
                        ForEach(upNext) { VideoRow(item: $0, actions: actions) }
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        } else {
            Spacer()
        }
    }

    private func header(_ item: VideoItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.video.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(colors.text)
                .textSelection(.enabled)
            // The player knows the length once it loads, when the listing didn't say.
            let length = item.durationMs > 0 ? item.durationMs : Int(controller.duration * 1000)
            Text([Format.whenText(item), length > 0 ? Format.duration(ms: length) : "",
                  item.video.isMembersOnly ? "Members only" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(colors.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func channelRow(_ item: VideoItem) -> some View {
        let channel = repository.channel(item.video.channelId)
        return Button {
            shell.openChannel(item.video.channelId)
        } label: {
            HStack(spacing: 12) {
                ChannelAvatar(url: channel?.avatarURL ?? repository.avatars[item.video.channelId], name: item.video.channelTitle, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.video.channelTitle)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(colors.text)
                        .lineLimit(1)
                    if let channel {
                        Text(Format.count(channel.recent.count, "recent video"))
                            .font(.footnote)
                            .foregroundStyle(colors.secondaryText)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.video.channelId.isEmpty)
    }

    private func actionPills(_ item: VideoItem) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                PillButton(label: item.watched ? "Watched" : "Mark watched", systemImage: item.watched ? "checkmark" : nil) {
                    shell.actions.setWatched(item, !item.watched)
                }
                if item.isDownloading {
                    PillButton(label: downloadingLabel(item), systemImage: "arrow.down.circle") {
                        shell.actions.delete(item)
                    }
                    .accessibilityHint("Stops the download")
                } else if !item.isPlayable {
                    PillButton(label: item.state == .failed ? "Retry download" : "Download", systemImage: "arrow.down.to.line", filled: true) {
                        shell.actions.download(item)
                    }
                }
                PillButton(label: "Save", systemImage: "text.badge.plus") { shell.actions.saveToPlaylist(item) }
                SpeedMenu(controller: controller) {
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                        Text(controller.speed == 1 ? "Speed" : SpeedMenu<EmptyView>.name(controller.speed))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colors.text)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 40)
                    .background(colors.chip, in: Capsule())
                }
                if item.isPlayable {
                    PillButton(label: "Delete", systemImage: "trash") { confirmDelete = true }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func downloadingLabel(_ item: VideoItem) -> String {
        item.state == .downloading ? "Downloading \(item.local?.progress ?? 0)%" : DownloadText.waiting(item, hold: repository.downloads.hold)
    }
}
