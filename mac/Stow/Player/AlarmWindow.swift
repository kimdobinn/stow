import AppKit
import SwiftUI

/// The alarm's window: mpv's video (drawn in process by `MPVVideoLayer`) with Stow's controls
/// on top. It opens filling the screen, can be resized, moved or made full screen like any
/// window, and closing it ends the alarm.
@MainActor
enum AlarmWindow {
    private static var window: VideoWindow?

    /// Opens the window for `core` and keeps it current from `updates`; it closes when `updates`
    /// ends (mpv stopped) or the core releases its video. Throws `.player` when the video
    /// output can't be set up.
    static func present(core: MPVCore, updates: AsyncStream<NowPlaying>,
                        perform: @escaping @Sendable (PlaybackAction) -> Void) throws {
        close(window)
        let state = PlaybackScreen(perform: perform)
        let videoLayer = try MPVVideoLayer(core: core)
        let shown = VideoWindow(state: state, videoLayer: videoLayer)
        window = shown
        core.setVideoRelease {
            videoLayer.release()
            close(shown)
        }
        NSApp.unhide(nil)
        shown.makeKeyAndOrderFront(nil)
        // At alarm time Stow is usually in the background; the window still has to come first.
        shown.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        Task {
            for await nowPlaying in updates { state.update(nowPlaying) }
            close(shown)
        }
    }

    private static func close(_ closing: VideoWindow?) {
        guard let closing, closing.isVisible || window === closing else { return }
        if window === closing { window = nil }
        closing.state.stopTimers()
        closing.forceClose()
        NSCursor.setHiddenUntilMouseMoves(false)
    }
}

/// What the alarm screen shows, plus when its controls fade out.
@MainActor
@Observable
final class PlaybackScreen {
    static let chromeTimeout: Duration = .seconds(4)
    static let seekStep: TimeInterval = 10
    static let volumeStep: Double = 5

    private(set) var nowPlaying: NowPlaying?
    private(set) var showsChrome = true
    /// The pointer is over the bottom controls; they stay up meanwhile.
    var isPointerOverControls = false {
        didSet { if isPointerOverControls { revealChrome() } }
    }

    @ObservationIgnored let perform: (PlaybackAction) -> Void
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    init(nowPlaying: NowPlaying? = nil, showsChrome: Bool = true, perform: @escaping (PlaybackAction) -> Void) {
        self.nowPlaying = nowPlaying
        self.showsChrome = showsChrome
        self.perform = perform
    }

    func update(_ new: NowPlaying) {
        let old = nowPlaying
        nowPlaying = new
        // A new video, loading finishing, or pausing/resuming brings the controls up for a moment.
        if old?.index != new.index || old?.isLoading != new.isLoading || old?.isPaused != new.isPaused {
            revealChrome()
        }
    }

    /// Shows the controls (and the pointer) and restarts the fade-out timer.
    func revealChrome() {
        if !showsChrome { showsChrome = true }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.chromeTimeout)
            guard !Task.isCancelled else { return }
            self?.hideChromeIfIdle()
        }
    }

    func togglePause() {
        guard let nowPlaying, !nowPlaying.isLoading else { return }
        perform(.setPaused(!nowPlaying.isPaused))
    }

    func changeVolume(by step: Double) {
        guard let nowPlaying else { return }
        if nowPlaying.isMuted { perform(.setMuted(false)) }
        perform(.setVolume(nowPlaying.volume + step))
    }

    func toggleMute() {
        guard let nowPlaying else { return }
        perform(.setMuted(!nowPlaying.isMuted))
    }

    /// Keyboard: space pauses, ←/→ seek 10 s, ↑/↓ volume, M mutes, N skips, esc or return ends the alarm.
    /// Every key also brings up the controls.
    func handleKey(code: UInt16, characters: String?) {
        revealChrome()
        switch code {
        case 53, 36, 76: perform(.stop)
        case 49: togglePause()
        case 123: perform(.seekBy(-Self.seekStep))
        case 124: perform(.seekBy(Self.seekStep))
        case 126: changeVolume(by: Self.volumeStep)
        case 125: changeVolume(by: -Self.volumeStep)
        default:
            switch characters?.lowercased() {
            case "n": if nowPlaying?.upNext != nil { perform(.next) }
            case "m": toggleMute()
            default: break
            }
        }
    }

    func stopTimers() {
        hideTask?.cancel()
    }

    private func hideChromeIfIdle() {
        guard let nowPlaying, !nowPlaying.isLoading, !nowPlaying.isPaused, !isPointerOverControls else { return }
        showsChrome = false
        NSCursor.setHiddenUntilMouseMoves(true)
    }
}

private final class VideoWindow: NSWindow, NSWindowDelegate {
    let state: PlaybackScreen
    private let videoLayer: MPVVideoLayer
    private var closesForReal = false

    init(state: PlaybackScreen, videoLayer: MPVVideoLayer) {
        self.state = state
        self.videoLayer = videoLayer
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        super.init(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        setFrame(frame, display: false)
        title = "Stow Alarm"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .black
        appearance = NSAppearance(named: .darkAqua)
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.fullScreenPrimary, .moveToActiveSpace]
        minSize = NSSize(width: 640, height: 360)
        delegate = self

        let container = ActivityView(frame: NSRect(origin: .zero, size: frame.size))
        container.onActivity = { [weak state] in state?.revealChrome() }
        let video = NSView(frame: container.bounds)
        video.layer = videoLayer
        video.wantsLayer = true
        video.autoresizingMask = [.width, .height]
        videoLayer.contentsScale = backingScaleFactor
        let host = FirstMouseHostingView(rootView: AlarmPlaybackView(screen: state))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(video)
        container.addSubview(host)
        contentView = container
    }

    /// Closing the window is "I'm awake": the alarm stops, and the window closes once mpv has.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closesForReal { return true }
        state.perform(.stop)
        return false
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        videoLayer.contentsScale = backingScaleFactor
    }

    func forceClose() {
        closesForReal = true
        orderOut(nil)
        close()
    }

    /// Keys without ⌘ are the player's (space, arrows, esc…); ⌘-shortcuts (⌘W, ⌘Q…) work as usual.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            state.handleKey(code: event.keyCode, characters: event.charactersIgnoringModifiers)
            return
        }
        super.sendEvent(event)
    }
}

/// Reports pointer movement anywhere in the window, even while Stow isn't the active app.
private final class ActivityView: NSView {
    var onActivity: () -> Void = {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        onActivity()
    }
}

/// The first click on a button acts at once instead of only focusing the window.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
