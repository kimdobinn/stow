import StowKit
import SwiftUI

/// The channel's picture, or its initial on a colored circle until (or unless) one loads.
struct ChannelAvatar: View {
    let url: String?
    let name: String
    var size: CGFloat = 36

    var body: some View {
        Circle()
            .fill(Self.color(for: name))
            .overlay {
                Text(name.first.map { String($0).uppercased() } ?? "")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white)
            }
            .overlay { if url != nil { RemoteImage(url, maxPixels: Int(size * 3)) } }
            .clipShape(Circle())
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// The same color as on Android for the same name (Java's String.hashCode, HSL 45%, 50%).
    static func color(for name: String) -> Color {
        var hash: Int32 = 0
        for unit in name.utf16 { hash = hash &* 31 &+ Int32(unit) }
        let hue = Double(Int(hash & 0x7fff_ffff) % 360)
        let saturation = 0.45, lightness = 0.5
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let x = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - chroma / 2
        let (r, g, b): (Double, Double, Double) = switch hue {
        case ..<60: (chroma, x, 0)
        case ..<120: (x, chroma, 0)
        case ..<180: (0, chroma, x)
        case ..<240: (0, x, chroma)
        case ..<300: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        return Color(.sRGB, red: r + m, green: g + m, blue: b + m)
    }
}

/// A thumbnail with the length and the "how far you got" bar.
struct Thumbnail: View {
    let item: VideoItem
    var cornerRadius: CGFloat = 0
    @Environment(\.stowColors) private var colors

    var body: some View {
        Rectangle()
            .fill(colors.chip)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { RemoteImage(item.video.thumbnailURL) }
            .overlay(alignment: .bottomTrailing) {
                if item.durationMs > 0 {
                    Text(Format.duration(ms: item.durationMs))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.progress > 0.01 {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.35))
                            Rectangle().fill(colors.accent).frame(width: proxy.size.width * item.progress)
                        }
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Stow's download control: one disc that tells the whole story. An arrow to keep the video on
/// the phone; a ring in the icon's colors while it downloads (tap to stop); a filled disc with a
/// check once it's here. `onMedia` draws it dimmed, for sitting on a thumbnail.
struct DownloadDisc: View {
    let item: VideoItem
    let actions: VideoActions
    var onMedia = true
    var size: CGFloat = 40
    @Environment(\.stowColors) private var colors

    private enum DiscState { case idle, loading, failed, done }

    private var state: DiscState {
        if item.isPlayable { return .done }
        if item.isDownloading { return .loading }
        if item.state == .failed { return .failed }
        return .idle
    }

    private var label: String {
        switch state {
        case .idle: "Download"
        case .loading: "Stop download"
        case .failed: "Retry download"
        case .done: "Downloaded"
        }
    }

    var body: some View {
        Button {
            switch state {
            case .idle, .failed: actions.download(item)
            case .loading: actions.delete(item)
            case .done: break
            }
        } label: {
            disc
                .frame(width: max(size, 44), height: max(size, 44))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(state == .done)
        .accessibilityLabel(label)
        .animation(.spring(duration: 0.25), value: state)
    }

    @ViewBuilder private var disc: some View {
        let face: Color = onMedia ? .white : colors.text
        switch state {
        case .done:
            Circle().fill(StowGradient.linear)
                .overlay { Image(systemName: "checkmark").font(.system(size: size * 0.36, weight: .bold)).foregroundStyle(.white) }
                .frame(width: size * 0.78, height: size * 0.78)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
        case .idle, .failed:
            background
                .overlay {
                    Image(systemName: state == .failed ? "arrow.clockwise" : "arrow.down")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(face)
                }
                .frame(width: size, height: size)
        case .loading:
            let percent = item.local?.progress ?? 0
            background
                .overlay {
                    DownloadRing(fraction: item.state == .downloading && percent > 0 ? Double(percent) / 100 : nil,
                                 track: face.opacity(0.25))
                        .padding(3)
                }
                .overlay { RoundedRectangle(cornerRadius: 2).fill(face).frame(width: size * 0.24, height: size * 0.24) }
                .frame(width: size, height: size)
        }
    }

    private var background: some View {
        Circle()
            .fill(onMedia ? Color.black.opacity(0.45) : colors.chip)
            .overlay { if onMedia { Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1) } }
    }
}

/// The ring around the stop square: how much is down, or a turning arc while it waits to start.
private struct DownloadRing: View {
    let fraction: Double?
    let track: Color

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: 3)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(fraction, 0.02))
                    .stroke(StowGradient.angular, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: fraction)
            } else {
                TimelineView(.animation) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1 * 360
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(StowGradient.angular, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(turn))
                }
            }
        }
    }
}

/// What the phone has of a video: downloading %, downloaded, failed, or what it waits for.
struct DownloadStatus: View {
    let item: VideoItem
    @Environment(\.stowColors) private var colors
    @Environment(\.downloadHold) private var hold

    var body: some View {
        switch item.state {
        case .downloaded:
            Label {
                Text(["Downloaded", (item.local?.sizeBytes ?? 0) > 0 ? Format.bytes(item.local!.sizeBytes) : nil]
                    .compactMap { $0 }.joined(separator: " · "))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .labelStyle(StatusLabelStyle())
            .font(.caption)
            .foregroundStyle(colors.secondaryText)
            .lineLimit(1)
        case .downloading, .queued:
            let percent = item.local?.progress ?? 0
            HStack(spacing: 6) {
                if item.state == .downloading && percent > 0 {
                    ProgressRing(fraction: Double(percent) / 100, color: colors.accent, track: colors.chip)
                        .frame(width: 12, height: 12)
                } else {
                    ProgressView().controlSize(.mini).tint(colors.secondaryText)
                        .frame(width: 12, height: 12)
                }
                Text(item.state == .downloading ? "Downloading · \(percent)%" : DownloadText.waiting(item, hold: hold))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(colors.accent)
                    .lineLimit(1)
            }
        case .failed:
            Label("Download failed", systemImage: "exclamationmark.circle")
                .labelStyle(StatusLabelStyle())
                .font(.caption)
                .foregroundStyle(colors.destructive)
                .lineLimit(1)
        case .deleted, nil:
            EmptyView()
        }
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// A small determinate ring.
struct ProgressRing: View {
    let fraction: Double
    let color: Color
    let track: Color

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: 2)
            Circle().trim(from: 0, to: fraction).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// The ⋯ menu's (and the long press's) items.
struct VideoMenuItems: View {
    let item: VideoItem
    let actions: VideoActions

    var body: some View {
        if item.isPlayable {
            Button("Play", systemImage: "play") { actions.play(item) }
        }
        if !item.isPlayable && !item.isDownloading {
            Button(item.state == .failed ? "Retry download" : "Download",
                   systemImage: item.state == .failed ? "arrow.clockwise" : "arrow.down.circle") { actions.download(item) }
        }
        Button("Save to playlist", systemImage: "text.badge.plus") { actions.saveToPlaylist(item) }
        if item.sent != nil {
            Button(item.watched ? "Mark as unwatched" : "Mark as watched",
                   systemImage: item.watched ? "eye.slash" : "eye") { actions.setWatched(item, !item.watched) }
        }
        if !item.video.channelId.isEmpty {
            Button("Go to channel", systemImage: "person.crop.square") { actions.openChannel(item.video.channelId) }
            if let add = actions.addToGroup {
                Button("Add channel to a group", systemImage: "square.stack") { add(item) }
            }
        }
        if let move = actions.move {
            Button("Move up", systemImage: "arrow.up") { move(item, -1) }
            Button("Move down", systemImage: "arrow.down") { move(item, 1) }
        }
        if let remove = actions.removeFromPlaylist {
            Button("Remove from playlist", systemImage: "minus.circle") { remove(item) }
        }
        if item.isPlayable || item.isDownloading {
            Button(item.isPlayable ? "Delete from downloads" : "Cancel download",
                   systemImage: item.isPlayable ? "trash" : "xmark.circle", role: .destructive) { actions.delete(item) }
        }
    }
}

/// "⋯", opening the video's menu.
struct VideoMoreButton: View {
    let item: VideoItem
    let actions: VideoActions
    @Environment(\.stowColors) private var colors

    var body: some View {
        Menu {
            VideoMenuItems(item: item, actions: actions)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(colors.secondaryText)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }
}

/// Home and Subscriptions: a rounded thumbnail with the download disc, the channel and title below.
struct VideoCard: View {
    let item: VideoItem
    let actions: VideoActions
    @Environment(\.calm) private var calm
    @Environment(\.stowColors) private var colors
    @Environment(\.channelAvatars) private var avatars

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !calm {
                Thumbnail(item: item, cornerRadius: 14)
                    .overlay(alignment: .topTrailing) { DownloadDisc(item: item, actions: actions).padding(4) }
                    .padding(.top, 8)
            }
            HStack(alignment: .top, spacing: 12) {
                Button { actions.openChannel(item.video.channelId) } label: {
                    ChannelAvatar(url: avatars[item.video.channelId], name: item.video.channelTitle, size: 36)
                }
                .buttonStyle(.plain)
                .disabled(item.video.channelId.isEmpty)
                .accessibilityLabel("Go to \(item.video.channelTitle)")
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.video.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(colors.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(Format.meta(item, withDuration: calm))
                        .font(.footnote)
                        .foregroundStyle(colors.secondaryText)
                        .lineLimit(1)
                    if item.isDownloading || item.state == .failed {
                        DownloadStatus(item: item)
                    }
                    if calm && item.progress > 0.01 { WatchedLine(fraction: item.progress) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if calm { DownloadDisc(item: item, actions: actions, onMedia: false, size: 34).padding(.top, -6) }
                VideoMoreButton(item: item, actions: actions).padding(.top, -10)
            }
            .padding(.top, 12)
            .padding(.bottom, calm ? 12 : 20)
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture { actions.play(item) }
        .contextMenu { VideoMenuItems(item: item, actions: actions) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Play") { actions.play(item) }
    }
}

/// Picking several from a list, like Photos: a long press starts picking with that row, then
/// taps pick and unpick.
struct RowSelection {
    var active: Bool
    var selected: Bool
    var toggle: () -> Void
}

/// Downloads, channel pages, playlists: the thumbnail on the left, the text on the right.
struct VideoRow: View {
    let item: VideoItem
    let actions: VideoActions
    var showChannel = true
    var selection: RowSelection?
    @Environment(\.calm) private var calm
    @Environment(\.stowColors) private var colors

    @Environment(\.dynamicTypeSize) private var typeSize

    private var selecting: Bool { selection?.active == true }

    var body: some View {
        Group {
            // At the largest text sizes the text gets the whole width, under the thumbnail.
            if typeSize.isAccessibilitySize && !calm {
                VStack(alignment: .leading, spacing: 8) {
                    thumbnail.padding(.trailing, 12)
                    HStack(alignment: .top, spacing: 0) {
                        text
                        trailing
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    if calm && selecting {
                        SelectionMark(selected: selection!.selected).padding(.top, 2).padding(.trailing, 12)
                    }
                    if !calm {
                        thumbnail.frame(width: 156).padding(.trailing, 12)
                    }
                    text
                    trailing
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .background(selection?.selected == true ? colors.accent.opacity(0.10) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting { selection!.toggle() } else { actions.play(item) }
        }
        .modifier(RowLongPress(item: item, actions: actions, selection: selection))
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: selecting ? "Select" : "Play") {
            if selecting { selection!.toggle() } else { actions.play(item) }
        }
    }
}

extension VideoRow {
    fileprivate var thumbnail: some View {
        Thumbnail(item: item, cornerRadius: 10)
            .overlay(alignment: .topLeading) {
                if selecting { SelectionMark(selected: selection!.selected, onImage: true).padding(6) }
            }
    }

    fileprivate var text: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.video.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(showChannel ? Format.meta(item, withDuration: calm) : Format.metaWithoutChannel(item, withDuration: calm))
                .font(.footnote)
                .foregroundStyle(colors.secondaryText)
                .lineLimit(2)
            DownloadStatus(item: item)
            if calm && item.progress > 0.01 { WatchedLine(fraction: item.progress) }
        }
        .padding(.top, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder fileprivate var trailing: some View {
        if !selecting {
            if !item.isPlayable { DownloadDisc(item: item, actions: actions, onMedia: false, size: 34).padding(.top, -6) }
            VideoMoreButton(item: item, actions: actions).padding(.top, -8)
        }
    }
}

/// A long press: starts picking in a list you can pick from, else the video's menu.
private struct RowLongPress: ViewModifier {
    let item: VideoItem
    let actions: VideoActions
    let selection: RowSelection?

    func body(content: Content) -> some View {
        if let selection {
            content.onLongPressGesture {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                selection.toggle()
            }
        } else {
            content.contextMenu { VideoMenuItems(item: item, actions: actions) }
        }
    }
}

/// The round check on a picked (filled) or pickable (outlined) row; white over a thumbnail.
struct SelectionMark: View {
    let selected: Bool
    var onImage = false
    @Environment(\.stowColors) private var colors

    var body: some View {
        Circle()
            .fill(selected ? colors.accent : onImage ? .black.opacity(0.25) : .clear)
            .overlay { Circle().strokeBorder(selected ? colors.accent : onImage ? .white : colors.secondaryText, lineWidth: 2) }
            .overlay { if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) } }
            .frame(width: 24, height: 24)
            .accessibilityLabel(selected ? "Selected" : "Not selected")
    }
}

/// In calm mode, how far you got shows as a thin line under the text.
struct WatchedLine: View {
    let fraction: Double
    @Environment(\.stowColors) private var colors

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(colors.chip)
            Rectangle().fill(colors.accent).frame(width: 120 * fraction)
        }
        .frame(width: 120, height: 3)
        .padding(.top, 6)
    }
}
