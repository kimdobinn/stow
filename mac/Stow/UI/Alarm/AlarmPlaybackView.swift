import SwiftUI

/// The controls drawn over the alarm video: a clock that always shows, and (after any mouse
/// movement or key, a new video, or while paused) the title, a progress bar, playback buttons
/// and a big "I'm Awake" button that ends the alarm.
struct AlarmPlaybackView: View {
    let screen: PlaybackScreen
    /// The spot (0–1) on the timeline under the pointer, for the preview above it.
    @State private var scrub: Double?
    @AppStorage(PlaybackScreen.seekStepKey) private var storedSeekStep = PlaybackScreen.defaultSeekStep
    private var seekStep: Int { PlaybackScreen.seekStep(stored: storedSeekStep) }

    private var chrome: Bool { screen.showsChrome }

    var body: some View {
        ZStack {
            scrims
            VStack(alignment: .leading, spacing: 0) {
                topBar
                Spacer(minLength: 0)
                center
                Spacer(minLength: 0)
                if let nowPlaying = screen.nowPlaying, !nowPlaying.isLoading {
                    bottomBar(nowPlaying)
                        .opacity(chrome ? 1 : 0)
                        .offset(y: chrome ? 0 : 24)
                        .allowsHitTesting(chrome)
                }
            }
            .padding(.horizontal, 72)
            .padding(.top, 52)
            .padding(.bottom, 56)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        // Clicking the video pauses or resumes it, like YouTube.
        .background(Color.black.opacity(0.001).onTapGesture { screen.togglePause() })
        .animation(.easeInOut(duration: 0.35), value: chrome)
        .animation(.easeInOut(duration: 0.25), value: screen.nowPlaying?.isPaused)
        .animation(.easeInOut(duration: 0.25), value: screen.nowPlaying?.isLoading)
        .task(id: screen.nowPlaying?.video.id) {
            // Signed out: no cookies file, and members-only videos just get no frames.
            guard let videoId = screen.nowPlaying?.video.id else { return }
            StoryboardLoader.shared.load(videoId: videoId, cookiesFile: AppPaths.cookiesFile)
        }
    }

    // MARK: Background

    private var scrims: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 280)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .frame(height: 460)
        }
        .opacity(chrome || isLoading ? 1 : 0)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var isLoading: Bool { screen.nowPlaying?.isLoading ?? true }

    // MARK: Top

    private var topBar: some View {
        HStack(alignment: .top) {
            Clock()
            Spacer(minLength: 40)
            if let nowPlaying = screen.nowPlaying {
                VStack(alignment: .trailing, spacing: 14) {
                    Label("Morning alarm · \(nowPlaying.index + 1) of \(nowPlaying.count)", systemImage: "alarm.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                    KeyboardHints()
                }
                .opacity(chrome ? 1 : 0)
            }
        }
    }

    // MARK: Center

    @ViewBuilder
    private var center: some View {
        if let nowPlaying = screen.nowPlaying, nowPlaying.isLoading {
            loading(nowPlaying)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
        } else if screen.nowPlaying?.isPaused == true {
            Button { screen.togglePause() } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 54, weight: .bold))
                    .offset(x: 4)
                    .frame(width: 132, height: 132)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .help("Resume (space)")
            .frame(maxWidth: .infinity)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }

    private func loading(_ nowPlaying: NowPlaying) -> some View {
        VStack(spacing: 22) {
            Spinner()
            Text(nowPlaying.index == 0 ? "Good morning" : "Up next")
                .font(.system(size: 44, weight: .bold, design: .rounded))
            Text(nowPlaying.video.title)
                .font(.system(size: 24, weight: .medium))
                .opacity(0.75)
                .lineLimit(1)
                .frame(maxWidth: 1000)
            AwakeButton { screen.perform(.stop) }
                .padding(.top, 16)
        }
        .shadow(color: .black.opacity(0.4), radius: 16)
    }

    // MARK: Bottom

    private func bottomBar(_ nowPlaying: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(nowPlaying.video.channelTitle)
                        .font(.system(size: 22, weight: .semibold))
                        .opacity(0.8)
                    if nowPlaying.video.isMembersOnly {
                        Label("Members only", systemImage: "star.fill")
                            .font(.system(size: 15, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.green, in: Capsule())
                    }
                }
                Text(nowPlaying.video.title)
                    .font(.system(size: 40, weight: .bold))
                    .lineLimit(2)
                    .frame(maxWidth: 1600, alignment: .leading)
            }
            .shadow(color: .black.opacity(0.5), radius: 10)

            PlaybackProgressBar(position: nowPlaying.position, duration: nowPlaying.duration,
                                onScrub: { scrub = $0 }) { target in
                screen.perform(.seekTo(target))
            }
            .overlay(alignment: .topLeading) {
                if let scrub, let duration = nowPlaying.duration, duration > 0 {
                    ScrubPreview(fraction: scrub, duration: duration, maxWidth: 320, fontSize: 15)
                }
            }

            HStack(spacing: 14) {
                ControlButton(systemImage: nowPlaying.isPaused ? "play.fill" : "pause.fill",
                              help: nowPlaying.isPaused ? "Play (space)" : "Pause (space)", size: 34) {
                    screen.togglePause()
                }
                ControlButton(systemImage: "gobackward.\(seekStep)", help: "Back \(seekStep) seconds (←)", size: 26) {
                    screen.perform(.seekBy(-TimeInterval(seekStep)))
                }
                ControlButton(systemImage: "goforward.\(seekStep)", help: "Forward \(seekStep) seconds (→)", size: 26) {
                    screen.perform(.seekBy(TimeInterval(seekStep)))
                }
                ControlButton(systemImage: "forward.end.fill", help: "Next video (N)", size: 26) {
                    screen.perform(.next)
                }
                .disabled(nowPlaying.upNext == nil)
                .opacity(nowPlaying.upNext == nil ? 0.35 : 1)

                VolumeControl(volume: nowPlaying.volume, isMuted: nowPlaying.isMuted,
                              onToggleMute: { screen.toggleMute() },
                              onChange: { volume in
                                  if nowPlaying.isMuted { screen.perform(.setMuted(false)) }
                                  screen.perform(.setVolume(volume))
                              })
                    .padding(.leading, 6)

                Text(timeText(nowPlaying))
                    .font(.system(size: 21, weight: .medium))
                    .monospacedDigit()
                    .padding(.leading, 10)
                if let upNext = nowPlaying.upNext {
                    Text("Up next · \(upNext.title)")
                        .font(.system(size: 19))
                        .opacity(0.6)
                        .lineLimit(1)
                        .padding(.leading, 18)
                        .frame(maxWidth: 700, alignment: .leading)
                }
                Spacer(minLength: 24)
                AwakeButton { screen.perform(.stop) }
            }
        }
        .onHover { screen.isPointerOverControls = $0 }
    }

    private func timeText(_ nowPlaying: NowPlaying) -> String {
        let position = AlarmText.playbackTime(nowPlaying.position)
        guard let duration = nowPlaying.duration else { return position }
        return "\(position) / \(AlarmText.playbackTime(duration))"
    }
}

/// The current time, large, with the date underneath.
private struct Clock: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 0) {
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 84, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: 24, weight: .medium))
                    .opacity(0.8)
            }
            .shadow(color: .black.opacity(0.55), radius: 14)
        }
    }
}

/// Ends the alarm: mpv quits and the run is recorded as stopped.
private struct AwakeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(StowBrand.gradient)
                Text("I'm Awake")
                Text("esc")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.45))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.2)))
            }
            .font(.system(size: 26, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .padding(.leading, 30)
            .padding(.trailing, 22)
            .padding(.vertical, 18)
            .background(.white, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        }
        .buttonStyle(PressableStyle())
        .help("End the alarm (esc)")
    }
}

private struct ControlButton: View {
    let systemImage: String
    let help: String
    let size: CGFloat
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size * 2.1, height: size * 2.1)
                .background(Circle().fill(.white.opacity(isHovered ? 0.18 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// A thin bar that grows on hover; click (or drag) anywhere on it to jump there at once, like
/// YouTube. Only regular playback (mpv reports the position about once a second) glides.
struct PlaybackProgressBar: View {
    let position: TimeInterval
    let duration: TimeInterval?
    var height: CGFloat = 6
    /// Hears the spot (0–1) under the pointer while it hovers or drags the bar, nil when it leaves.
    var onScrub: ((Double?) -> Void)? = nil
    let onSeek: (TimeInterval) -> Void
    @State private var isHovered = false
    @State private var isDragging = false
    /// What the bar shows: follows `fraction`, gliding only through playback ticks.
    @State private var shown: Double = 0
    /// Where a click asked to go, shown until the player gets there.
    @State private var pending: Double?
    @State private var pendingTimeout: Task<Void, Never>?

    private var fraction: Double {
        guard let duration, duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    private var displayed: Double { pending ?? shown }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28))
                Capsule()
                    .fill(StowBrand.gradient)
                    .frame(width: max(width * displayed, isHovered ? height + 4 : height))
            }
            .frame(height: isHovered ? height + 4 : height)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: height * 3.3, height: height * 3.3)
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    .offset(x: width * displayed - height * 1.65)
                    .opacity(isHovered ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): onScrub?(spot(location.x, width: width))
                case .ended: if !isDragging { onScrub?(nil) }
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isDragging = true
                    onScrub?(spot(value.location.x, width: width))
                    seek(to: value.location.x, width: width, commit: false)
                }
                .onEnded { value in
                    isDragging = false
                    seek(to: value.location.x, width: width, commit: true)
                    if !isHovered { onScrub?(nil) }
                })
        }
        .frame(height: height * 4.6)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onAppear { shown = fraction }
        .onChange(of: fraction) { old, new in
            if let pending, let duration, abs(new - pending) * duration < 2 { self.pending = nil }
            let step = (new - old) * (duration ?? 0)
            if step > 0, step < 1.6 {
                withAnimation(.linear(duration: 1)) { shown = new }
            } else {
                shown = new
            }
        }
    }

    private func spot(_ x: CGFloat, width: CGFloat) -> Double {
        width > 0 ? min(max(x / width, 0), 1) : 0
    }

    /// Moves the bar under the pointer at once; the player seeks on release.
    private func seek(to x: CGFloat, width: CGFloat, commit: Bool) {
        guard let duration, duration > 0, width > 0 else { return }
        let target = min(max(x / width, 0), 1)
        pending = target
        guard commit else { return }
        onSeek(target * duration)
        // If the player never gets there (seek refused), stop pretending after a moment.
        pendingTimeout?.cancel()
        pendingTimeout = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { pending = nil }
        }
    }
}

/// A speaker button (mute) and a slider for mpv's volume; the slider follows drags at once and
/// mpv's reported volume otherwise.
private struct VolumeControl: View {
    let volume: Double
    let isMuted: Bool
    let onToggleMute: () -> Void
    let onChange: (Double) -> Void
    @State private var dragging: Double?
    @State private var isHovered = false

    private var shown: Double { isMuted ? 0 : (dragging ?? volume) }

    private var symbol: String {
        switch shown {
        case 0: "speaker.slash.fill"
        case ..<34: "speaker.wave.1.fill"
        case ..<67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ControlButton(systemImage: symbol, help: isMuted ? "Unmute (M)" : "Mute (M)", size: 24, action: onToggleMute)
                .frame(width: 56)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.28))
                    Capsule().fill(.white).frame(width: width * shown / 100)
                }
                .frame(height: isHovered || dragging != nil ? 8 : 5)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.4), radius: 4)
                        .offset(x: width * shown / 100 - 9)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let level = (min(max(value.location.x / max(width, 1), 0), 1) * 100).rounded()
                        dragging = level
                        onChange(level)
                    }
                    .onEnded { _ in dragging = nil })
            }
            .frame(width: 150, height: 28)
            Text("\(Int(shown))")
                .font(.system(size: 17, weight: .medium))
                .monospacedDigit()
                .opacity(0.75)
                .frame(width: 40, alignment: .leading)
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .help("Volume (↑ ↓)")
    }
}

private struct KeyboardHints: View {
    @AppStorage(PlaybackScreen.seekStepKey) private var storedSeekStep = PlaybackScreen.defaultSeekStep
    var body: some View {
        HStack(spacing: 18) {
            hint("space", "pause")
            hint("← →", "\(PlaybackScreen.seekStep(stored: storedSeekStep)) s")
            hint("↑ ↓", "volume")
            hint("N", "next")
            hint("esc", "I'm awake")
        }
        .font(.system(size: 16, weight: .medium))
        .shadow(color: .black.opacity(0.5), radius: 6)
    }

    private func hint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 7) {
            Text(key)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.45)))
            Text(action).opacity(0.75)
        }
    }
}

/// A brand-colored arc that spins; the system spinner is too faint over video.
struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            let turns = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(StowBrand.gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: 56, height: 56)
                .rotationEffect(.degrees(turns * 360))
        }
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The app icon's orange → pink → purple.
enum StowBrand {
    static let gradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.62, blue: 0.25), Color(red: 0.93, green: 0.27, blue: 0.42),
                 Color(red: 0.45, green: 0.22, blue: 0.62)],
        startPoint: .leading, endPoint: .trailing)
}
