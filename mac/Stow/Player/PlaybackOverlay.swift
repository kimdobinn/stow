import AppKit
import SwiftUI

/// Stow's own controls over the alarm video: a transparent panel just above mpv's fullscreen
/// window (mpv sits at the floating level) on the same screen. It never activates Stow, so mpv
/// keeps the menu bar and Dock hidden, but it takes the clicks and keys.
@MainActor
enum PlaybackOverlay {
    private static var panel: OverlayPanel?

    /// Shows the controls until `updates` ends (mpv exited). Replaces any controls already shown.
    static func present(updates: AsyncStream<NowPlaying>, perform: @escaping @Sendable (PlaybackAction) -> Void) {
        dismiss()
        guard let screen = NSScreen.screens.first else { return }
        let state = PlaybackScreen(perform: perform)
        let shown = OverlayPanel(screen: screen, state: state)
        panel = shown
        shown.orderFrontRegardless()
        shown.makeKey()
        Task {
            for await nowPlaying in updates {
                state.update(nowPlaying)
                // mpv can take focus when its window appears; the controls want the keys.
                if !shown.isKeyWindow { shown.makeKey() }
            }
            if panel === shown { dismiss() }
        }
    }

    static func dismiss() {
        guard let panel else { return }
        self.panel = nil
        panel.state.stopTimers()
        panel.orderOut(nil)
        panel.close()
        NSCursor.setHiddenUntilMouseMoves(false)
    }
}

/// What the alarm screen shows, plus when its controls fade out.
@MainActor
@Observable
final class PlaybackScreen {
    static let chromeTimeout: Duration = .seconds(4)
    static let seekStep: TimeInterval = 10

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

    /// Keyboard: space pauses, ←/→ seek 10 s, N skips, esc or return ends the alarm.
    /// Every key also brings up the controls.
    func handleKey(code: UInt16, characters: String?) {
        revealChrome()
        switch code {
        case 53, 36, 76: perform(.stop)
        case 49: togglePause()
        case 123: perform(.seekBy(-Self.seekStep))
        case 124: perform(.seekBy(Self.seekStep))
        default:
            if characters?.lowercased() == "n", nowPlaying?.upNext != nil { perform(.next) }
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

private final class OverlayPanel: NSPanel {
    let state: PlaybackScreen

    init(screen: NSScreen, state: PlaybackScreen) {
        self.state = state
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        acceptsMouseMovedEvents = true
        // Otherwise clicks on the (clear) background would fall through to mpv.
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        title = "Stow Alarm Controls"
        appearance = NSAppearance(named: .darkAqua)

        let container = ActivityView(frame: NSRect(origin: .zero, size: screen.frame.size))
        container.onActivity = { [weak state] in state?.revealChrome() }
        let host = FirstMouseHostingView(rootView: AlarmPlaybackView(screen: state))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Keys are handled here, before SwiftUI, so space never "clicks" a focused button.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            state.handleKey(code: event.keyCode, characters: event.charactersIgnoringModifiers)
            return
        }
        super.sendEvent(event)
    }
}

/// Reports pointer movement anywhere on the panel, even while Stow isn't the active app.
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

/// The first click on a button acts at once instead of only focusing the panel.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
