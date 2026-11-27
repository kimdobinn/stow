import StowKit
import SwiftUI

/// The video with YouTube-style controls: tap to show or hide them, double-tap a side to skip
/// 5 s (taps in a row add up), hold for 2×, drag the bar to seek (with the frame there, for a
/// downloaded video), drag the video down to shrink it, up for full screen.
struct PlayerVideoArea: View {
    let controller: PlaybackController
    let fullScreen: Bool
    var onCollapse: () -> Void
    var onFullScreen: (Bool) -> Void
    /// The drag that shrinks the watch page, while it moves (0 when let go).
    var onPull: (CGFloat) -> Void
    var onPullEnd: (CGFloat, CGFloat) -> Void
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors

    @State private var visible = true
    @State private var touches = 0
    @State private var skip: Skip?
    @State private var lastTap: (at: Date, forward: Bool)?
    @State private var visibleBeforeTap = true
    @State private var scrubbing: Double?
    @State private var frames = ScrubFrames()

    /// A run of double-taps on one side.
    private struct Skip: Equatable {
        var forward: Bool
        var seconds: Int
        var at: Date
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                VideoSurface(controller: controller)
                VideoGestures(onTap: { tapped($0, $1) }, onHold: held, onDrag: dragged, onDragEnd: dragEnded)
                if let skip { skipBadge(skip, width: proxy.size.width) }
                if controller.isHolding { holdBadge }
                if controller.isBuffering, !controller.isResolving, scrubbing == nil {
                    ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
                }
                if controller.isPictureInPictureActive { pictureInPictureNote }
                if controller.isResolving || controller.error != nil {
                    statusOverlay
                } else {
                    if visible, scrubbing == nil, !controller.ended { controls }
                    if controller.ended, scrubbing == nil { doneOverlay }
                    if let scrubbing { scrubPreview(scrubbing, width: proxy.size.width) }
                    seekBar(width: proxy.size.width)
                }
            }
        }
        .task(id: touches) {
            // Controls hide after 3 s of playing untouched.
            try? await Task.sleep(for: .seconds(3))
            if controller.isPlaying, scrubbing == nil { withAnimation(.easeOut(duration: 0.16)) { visible = false } }
        }
        .task(id: skip) {
            guard skip != nil else { return }
            try? await Task.sleep(for: .milliseconds(800))
            withAnimation(.easeOut(duration: 0.2)) { skip = nil }
        }
        .onChange(of: controller.fileURL, initial: true) { _, file in frames.use(file) }
        .onChange(of: controller.isPlaying) { _, playing in if !playing { visible = true } }
        .statusBarHidden(fullScreen)
        .persistentSystemOverlays(fullScreen ? .hidden : .automatic)
    }

    // MARK: - Touches

    private func tapped(_ point: CGPoint, _ size: CGSize) {
        guard !controller.isResolving, controller.error == nil, !controller.ended else { return }
        let now = Date.now
        let forward = point.x > size.width / 2
        let skipping = skip.map { $0.forward == forward && now.timeIntervalSince($0.at) < 0.8 } ?? false
        let doubleTap = lastTap.map { $0.forward == forward && now.timeIntervalSince($0.at) < 0.3 } ?? false
        if skipping || doubleTap {
            // The first tap of the pair showed or hid the controls: put them back as they were.
            if doubleTap && !skipping { visible = visibleBeforeTap }
            controller.skip(forward: forward)
            let previous = skipping ? skip?.seconds ?? 0 : 0
            skip = Skip(forward: forward, seconds: previous + Int(PlaybackController.skipSeconds), at: now)
            lastTap = nil
        } else {
            visibleBeforeTap = visible
            withAnimation(.easeOut(duration: visible ? 0.16 : 0.09)) { visible.toggle() }
            lastTap = (now, forward)
        }
        touches += 1
    }

    private func held(_ down: Bool) {
        if down {
            guard !controller.isResolving, controller.error == nil, !controller.ended else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            visible = false
            controller.beginHold()
        } else {
            controller.endHold()
            lastTap = nil
        }
    }

    private func dragged(_ distance: CGFloat) {
        guard !fullScreen else { return }
        onPull(max(distance, 0))
    }

    private func dragEnded(_ distance: CGFloat, _ velocity: CGFloat) {
        if fullScreen {
            if distance > 80 || velocity > 1500 { onFullScreen(false) }
        } else if distance < -60 || velocity < -1500 {
            onPull(0)
            onFullScreen(true)
        } else {
            onPullEnd(max(distance, 0), velocity)
        }
    }

    private func touched() {
        touches += 1
    }

    // MARK: - Controls

    private var controls: some View {
        ZStack {
            Color.black.opacity(0.45).allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    VideoButton(fullScreen ? "chevron.down" : "chevron.down", label: "Minimize") {
                        if fullScreen { onFullScreen(false) } else { onCollapse() }
                    }
                    Spacer()
                    if controller.pictureInPicture.isSupported {
                        VideoButton("pip.enter", label: "Picture in Picture") { controller.pictureInPicture.toggle() }
                    }
                    SpeedMenu(controller: controller) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Playback speed")
                }
                .padding(.horizontal, fullScreen ? 16 : 4)
                .padding(.top, fullScreen ? 8 : 2)
                Spacer()
                HStack(spacing: 0) {
                    Text("\(Format.duration(ms: Int(controller.position * 1000))) / \(Format.duration(ms: Int(controller.duration * 1000)))")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.white)
                    Spacer()
                    VideoButton(fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                label: fullScreen ? "Exit full screen" : "Full screen") {
                        onFullScreen(!fullScreen)
                    }
                }
                .padding(.leading, fullScreen ? 24 : 14)
                .padding(.trailing, fullScreen ? 16 : 4)
                .padding(.bottom, fullScreen ? 34 : 10)
            }
            HStack(spacing: 40) {
                RoundControl("backward.end.fill", label: "Previous", size: 46, enabled: controller.hasPrevious) {
                    controller.previous()
                    touched()
                }
                RoundControl(controller.isPlaying ? "pause.fill" : "play.fill", label: controller.isPlaying ? "Pause" : "Play", size: 64) {
                    controller.togglePlay()
                    touched()
                }
                RoundControl("forward.end.fill", label: "Next", size: 46, enabled: controller.hasNext) {
                    controller.next()
                    touched()
                }
            }
        }
        .transition(.opacity)
    }

    private var statusOverlay: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 12) {
                if let error = controller.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                    DarkPill("Try again", systemImage: "arrow.clockwise") { controller.retry() }
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Getting the video from YouTube…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VideoButton("chevron.down", label: "Minimize") {
                if fullScreen { onFullScreen(false) } else { onCollapse() }
            }
            .padding(4)
        }
    }

    /// The end of a video: no countdown into the next one, just a calm stop.
    private var doneOverlay: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark").font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
            Text("You're done").font(.callout.weight(.medium)).foregroundStyle(.white).padding(.top, 6)
            HStack(spacing: 10) {
                DarkPill("Replay", systemImage: "arrow.counterclockwise") { controller.resume() }
                DarkPill("Close", systemImage: "xmark") { shell.closePlayer() }
            }
            .padding(.top, 14)
            if controller.hasNext, let next = controller.upNext.first {
                Button { controller.next() } label: {
                    Text("Next: \(next.video.title)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.8))
        .overlay(alignment: .topLeading) {
            VideoButton("chevron.down", label: fullScreen ? "Exit full screen" : "Minimize") {
                if fullScreen { onFullScreen(false) } else { onCollapse() }
            }
            .padding(.horizontal, fullScreen ? 16 : 4)
            .padding(.top, fullScreen ? 8 : 2)
        }
    }

    private var pictureInPictureNote: some View {
        VStack(spacing: 8) {
            Image(systemName: "pip").font(.system(size: 30))
            Text("Playing in Picture in Picture").font(.footnote)
        }
        .foregroundStyle(.white.opacity(0.7))
        .allowsHitTesting(false)
    }

    /// YouTube's half-moon on the tapped side, with arrows and the running total.
    private func skipBadge(_ skip: Skip, width: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: skip.forward ? 1000 : 0, bottomLeadingRadius: skip.forward ? 1000 : 0,
                                           bottomTrailingRadius: skip.forward ? 0 : 1000, topTrailingRadius: skip.forward ? 0 : 1000)
        return VStack(spacing: 4) {
            Image(systemName: skip.forward ? "forward.fill" : "backward.fill").font(.system(size: 14))
            Text("\(skip.seconds) seconds").font(.footnote.weight(.medium))
        }
        .foregroundStyle(.white)
        .frame(width: width / 2.4)
        .frame(maxHeight: .infinity)
        .background(.white.opacity(0.16), in: shape)
        .frame(maxWidth: .infinity, alignment: skip.forward ? .trailing : .leading)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var holdBadge: some View {
        Label("2×", systemImage: "forward.fill")
            .labelStyle(TrailingIconLabelStyle())
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, fullScreen ? 24 : 14)
            .allowsHitTesting(false)
    }

    // MARK: - Seeking

    /// The bar: thin along the bottom, with a dot while the controls show. A drag moves from
    /// where the video is (not where the finger lands), like YouTube; a tap jumps there.
    private func seekBar(width: CGFloat) -> some View {
        let fraction = scrubbing ?? controller.fraction
        let bufferedFraction = controller.duration > 0 ? min(controller.buffered / controller.duration, 1) : 0
        let showDot = visible || scrubbing != nil
        let barHeight: CGFloat = showDot ? 3 : 2
        let dot: CGFloat = scrubbing != nil ? 16 : 12
        return ZStack(alignment: .leading) {
            Rectangle().fill(.white.opacity(0.3)).frame(height: barHeight)
            Rectangle().fill(.white.opacity(0.5)).frame(width: width * bufferedFraction, height: barHeight)
            Rectangle().fill(colors.accent).frame(width: width * fraction, height: barHeight)
            if showDot {
                Circle().fill(colors.accent).frame(width: dot, height: dot)
                    .offset(x: width * fraction - dot / 2)
            }
        }
        .frame(width: width, height: 28)
        .contentShape(Rectangle())
        .gesture(scrubGesture(width: width))
        .frame(maxHeight: .infinity, alignment: .bottom)
        // Across the video's bottom edge, as on YouTube; lifted clear of the edge in full screen.
        .offset(y: fullScreen ? -16 : 13)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(Format.duration(ms: Int(controller.position * 1000)))
        .accessibilityAdjustableAction { direction in
            controller.skip(forward: direction == .increment)
        }
    }

    @State private var scrubStart: Double = 0
    @State private var scrubMoved = false

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if scrubbing == nil {
                    scrubStart = controller.fraction
                    scrubMoved = false
                    scrubbing = scrubStart
                }
                if abs(value.translation.width) > 4 { scrubMoved = true }
                if scrubMoved {
                    let at = min(max(scrubStart + value.translation.width / max(width, 1), 0), 1)
                    scrubbing = at
                    frames.show(at * controller.duration)
                }
                touches += 1
            }
            .onEnded { value in
                if scrubMoved, let scrubbing {
                    controller.seek(to: scrubbing * controller.duration)
                } else if visible {
                    controller.seek(to: min(max(value.location.x / max(width, 1), 0), 1) * controller.duration)
                } else {
                    withAnimation(.easeOut(duration: 0.09)) { visible = true }
                }
                scrubbing = nil
                touches += 1
            }
    }

    /// While scrubbing: the frame there (downloaded videos) and its time, above the bar.
    private func scrubPreview(_ at: Double, width: CGFloat) -> some View {
        let boxWidth: CGFloat = fullScreen ? 200 : 150
        let x = min(max(width * at - boxWidth / 2, 8), max(width - boxWidth - 8, 8))
        return VStack(spacing: 4) {
            if controller.fileURL != nil {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black)
                    .overlay {
                        if let image = frames.image {
                            Image(uiImage: image).resizable().scaledToFill()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white, lineWidth: 1.5) }
                    .frame(width: boxWidth, height: boxWidth * 9 / 16)
            }
            Text(Format.duration(ms: Int(at * controller.duration * 1000)))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 3)
        }
        .frame(width: boxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .offset(x: x)
        .padding(.bottom, fullScreen ? 52 : 20)
        .allowsHitTesting(false)
    }
}

/// A white icon button over the video.
struct VideoButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    init(_ systemImage: String, label: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Play, pause, previous and next: a dark disc in the middle of the video.
private struct RoundControl: View {
    let systemImage: String
    let label: String
    let size: CGFloat
    var enabled = true
    let action: () -> Void

    init(_ systemImage: String, label: String, size: CGFloat, enabled: Bool = true, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.size = size
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42))
                .foregroundStyle(enabled ? .white : .white.opacity(0.3))
                .frame(width: size, height: size)
                .background(.black.opacity(0.35), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// A light capsule on the dark video.
struct DarkPill: View {
    let label: String
    let systemImage: String
    let action: () -> Void

    init(_ label: String, systemImage: String, action: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.white.opacity(0.18), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Playback speed, with a check by the one in use.
struct SpeedMenu<Label: View>: View {
    let controller: PlaybackController
    @ViewBuilder var label: Label

    var body: some View {
        Menu {
            Picker("Playback speed", selection: Binding(get: { controller.speed }, set: { controller.setSpeed($0) })) {
                ForEach(Prefs.playbackSpeeds, id: \.self) { speed in
                    Text(Self.name(speed)).tag(speed)
                }
            }
        } label: {
            label
        }
    }

    static func name(_ speed: Double) -> String {
        speed == 1 ? "Normal" : "\(speed.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}
