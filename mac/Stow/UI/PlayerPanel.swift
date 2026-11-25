import AppKit
import SwiftUI

/// The player panel beside the current section (or filling the window): the video with
/// YouTube-style controls over it, and the title and actions underneath.
struct PlayerPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let dock: PlayerDock
    let screen: PlaybackScreen
    /// Reports the height of the title and buttons under the video, so the panel can be sized
    /// for the video and them to fill the height.
    var onDetailsHeight: (CGFloat) -> Void = { _ in }
    /// The spot (0–1) on the timeline under the pointer, for the preview above it.
    @State private var scrub: Double?
    @AppStorage(PlaybackScreen.seekStepKey) private var storedSeekStep = PlaybackScreen.defaultSeekStep
    private var seekStep: Int { PlaybackScreen.seekStep(stored: storedSeekStep) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            video
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: dock.isExpanded ? .infinity : nil)
                .background(.black)
            if !dock.isExpanded, let nowPlaying = screen.nowPlaying {
                details(nowPlaying)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onDetailsHeight($0) }
            }
        }
        // The video gets the height the details leave (it shrinks rather than pushing them off).
        .frame(maxHeight: .infinity, alignment: .top)
        .background(dock.isExpanded ? Color.black : Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: [])
        .task(id: screen.nowPlaying?.video.id) {
            guard let videoId = screen.nowPlaying?.video.id else { return }
            StoryboardLoader.shared.load(videoId: videoId, cookiesFile: model.playbackCookiesFile)
        }
    }

    // MARK: Video

    private var video: some View {
        ZStack {
            if let layer = dock.videoLayer {
                VideoSurface(layer: layer)
            }
            Color.black.opacity(0.001)
                .onTapGesture(count: 2) { dock.toggleExpanded() }
                .onTapGesture { screen.togglePause() }
            center
            controls
                .opacity(screen.showsChrome ? 1 : 0)
                .allowsHitTesting(screen.showsChrome)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onContinuousHover { phase in
            if case .active = phase { screen.revealChrome() }
        }
        .animation(.easeInOut(duration: 0.25), value: screen.showsChrome)
        .clipped()
    }

    @ViewBuilder
    private var center: some View {
        if let nowPlaying = screen.nowPlaying, nowPlaying.isLoading {
            Spinner().scaleEffect(0.7)
        } else if screen.nowPlaying?.isPaused == true {
            Image(systemName: "play.fill")
                .font(.system(size: 30, weight: .bold))
                .offset(x: 2)
                .frame(width: 72, height: 72)
                .background(.ultraThinMaterial, in: Circle())
                .allowsHitTesting(false)
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let nowPlaying = screen.nowPlaying {
                VStack(spacing: 2) {
                    PlaybackProgressBar(position: nowPlaying.position, duration: nowPlaying.duration, height: 4,
                                        onScrub: { scrub = $0 }) {
                        screen.perform(.seekTo($0))
                    }
                    .overlay(alignment: .topLeading) {
                        if let scrub, let duration = nowPlaying.duration, duration > 0 {
                            ScrubPreview(fraction: scrub, duration: duration)
                        }
                    }
                    controlRow(nowPlaying)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .background(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 110)
                        .allowsHitTesting(false)
                }
                .onHover { screen.isPointerOverControls = $0 }
            }
        }
    }

    private func controlRow(_ nowPlaying: NowPlaying) -> some View {
        HStack(spacing: 4) {
            PanelButton(systemImage: nowPlaying.isPaused ? "play.fill" : "pause.fill",
                        help: nowPlaying.isPaused ? "Play (space)" : "Pause (space)") { screen.togglePause() }
            PanelButton(systemImage: "gobackward.\(seekStep)", help: "Back \(seekStep) seconds (←)") {
                screen.perform(.seekBy(-TimeInterval(seekStep)))
            }
            PanelButton(systemImage: "goforward.\(seekStep)", help: "Forward \(seekStep) seconds (→)") {
                screen.perform(.seekBy(TimeInterval(seekStep)))
            }
            PanelButton(systemImage: volumeSymbol(nowPlaying), help: nowPlaying.isMuted ? "Unmute (M)" : "Mute (M)") {
                screen.toggleMute()
            }
            Slider(value: Binding(get: { nowPlaying.isMuted ? 0 : nowPlaying.volume },
                                  set: { level in
                                      if nowPlaying.isMuted { screen.perform(.setMuted(false)) }
                                      screen.perform(.setVolume(level))
                                  }), in: 0...100)
                .controlSize(.mini)
                .frame(width: 70)
                .help("Volume (↑ ↓)")
            Text(timeText(nowPlaying))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .padding(.leading, 6)
                .lineLimit(1)
            Spacer(minLength: 4)
            PanelButton(systemImage: dock.isExpanded ? "rectangle.righthalf.inset.filled" : "rectangle.inset.filled",
                        help: dock.isExpanded ? "Back to the side panel (esc)" : "Fill the window") { dock.toggleExpanded() }
            PanelButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Full screen (F)") { dock.toggleFullScreen() }
            PanelButton(systemImage: "xmark", help: "Close (esc)") { dock.stop() }
        }
    }

    private func volumeSymbol(_ nowPlaying: NowPlaying) -> String {
        let level = nowPlaying.isMuted ? 0 : nowPlaying.volume
        switch level {
        case 0: return "speaker.slash.fill"
        case ..<34: return "speaker.wave.1.fill"
        case ..<67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private func timeText(_ nowPlaying: NowPlaying) -> String {
        let position = AlarmText.playbackTime(nowPlaying.position)
        guard let duration = nowPlaying.duration else { return position }
        return "\(position) / \(AlarmText.playbackTime(duration))"
    }

    // MARK: Details

    private func details(_ nowPlaying: NowPlaying) -> some View {
        let video = nowPlaying.video
        let isWatched = model.isWatched(videoId: video.id)
        return VStack(alignment: .leading, spacing: 8) {
            Text(video.title)
                .font(.title3.weight(.semibold))
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if let channel = model.channels.first(where: { $0.id == video.channelId }) {
                    ChannelAvatar(url: channel.avatarURL, size: 24)
                }
                Text(video.channelTitle).font(.headline)
                if video.isMembersOnly {
                    MembersBadge(access: model.memberAccess(videoId: video.id))
                }
            }
            HStack(spacing: 8) {
                Button(isWatched ? "Mark as Unwatched" : "Mark as Watched",
                       systemImage: isWatched ? "eye.slash" : "checkmark.circle") {
                    model.setWatched(!isWatched, videoId: video.id)
                }
                PhoneButton(videoId: video.id, isMembersOnly: video.isMembersOnly)
                Button("Open on YouTube", systemImage: "safari") {
                    dock.stop()
                    openURL(video.watchURL)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Sends the video to the phone, or says where it is on the way there.
private struct PhoneButton: View {
    @Environment(AppModel.self) private var model
    let videoId: String
    let isMembersOnly: Bool

    var body: some View {
        let phone = model.phone
        let allowed = model.canSendToPhone(videoId: videoId, isMembersOnly: isMembersOnly)
        if let download = phone.download(videoId: videoId), download.state != .deleted, download.state != .failed {
            Label(status(download.state), systemImage: download.state == .downloaded ? "iphone" : "arrow.down.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        } else if phone.isSent(videoId: videoId), phone.download(videoId: videoId) == nil {
            Label("Sent to phone", systemImage: "arrow.down.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        } else {
            Button(phone.download(videoId: videoId) == nil ? "Send to Phone" : "Send to Phone Again", systemImage: "iphone.and.arrow.forward") {
                phone.send(videoId: videoId)
            }
            .disabled(!phone.isPaired || !allowed)
            .help(!phone.isPaired ? "Pair a phone under Phone first"
                  : !allowed ? (model.isLocked(videoId: videoId) ? "Your membership level can't watch this video"
                                : "Checking whether your membership level can watch this video")
                  : "Download this video on the phone")
        }
    }

    private func status(_ state: PhoneDownloadState) -> String {
        switch state {
        case .queued: "Waiting on phone"
        case .downloading: "Downloading on phone"
        case .downloaded: "On phone"
        case .failed, .deleted: ""
        }
    }
}

/// A small white control over the video.
private struct PanelButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(isHovered ? 0.18 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Hosts mpv's video layer.
private struct VideoSurface: NSViewRepresentable {
    let layer: MPVVideoLayer

    func makeNSView(context: Context) -> VideoLayerView {
        let view = VideoLayerView()
        view.show(layer)
        return view
    }

    func updateNSView(_ view: VideoLayerView, context: Context) {
        view.show(layer)
    }
}

private final class VideoLayerView: NSView {
    func show(_ videoLayer: MPVVideoLayer) {
        guard layer !== videoLayer else { return }
        layer = videoLayer
        wantsLayer = true
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }
}

/// Reports the window the view is in.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}
