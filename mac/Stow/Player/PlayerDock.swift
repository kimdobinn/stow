import AppKit
import Observation

/// The video being watched in the main window's player panel: its controls' state and the layer
/// mpv draws into. Shown beside the current section, or filling the window when expanded.
@MainActor
@Observable
final class PlayerDock {
    static let shared = PlayerDock()

    private(set) var screen: PlaybackScreen?
    @ObservationIgnored private(set) var videoLayer: MPVVideoLayer?
    /// The panel fills the main window (and the window may be full screen).
    var isExpanded = false
    /// The main window, once the panel is on screen (for full screen and keys).
    @ObservationIgnored weak var hostWindow: NSWindow?
    @ObservationIgnored private var keyMonitor: Any?
    /// Full screen was entered from the panel, so leaving the panel leaves it too.
    @ObservationIgnored private var enteredFullScreen = false

    /// Shows a new video's controls and video, replacing any video playing in the panel.
    func present(core: MPVCore, updates: AsyncStream<NowPlaying>,
                 perform: @escaping @Sendable (PlaybackAction) -> Void) throws {
        screen?.perform(.stop)
        let state = PlaybackScreen(mode: .watch, perform: perform)
        let layer = try MPVVideoLayer(core: core)
        state.toggleFullScreen = { [weak self] in self?.toggleFullScreen() }
        screen = state
        videoLayer = layer
        core.setVideoRelease { [weak self] in
            layer.release()
            self?.clear(ifShowing: state)
        }
        Task { [weak self] in
            for await nowPlaying in updates { state.update(nowPlaying) }
            self?.clear(ifShowing: state)
        }
        installKeys()
        hostWindow?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    /// Shows `state` in the panel with no video playing, for `--snapshot`.
    func showPreview(_ state: PlaybackScreen?) {
        screen = state
        videoLayer = nil
    }
    #endif

    /// Stops the video (closing the panel once mpv has stopped).
    func stop() {
        screen?.perform(.stop)
    }

    func toggleExpanded() {
        if isExpanded, enteredFullScreen { return toggleFullScreen() }
        isExpanded.toggle()
    }

    /// Full screen shows just the player; leaving it goes back to the panel beside the section.
    func toggleFullScreen() {
        guard let window = hostWindow else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        enteredFullScreen = !isFullScreen
        isExpanded = !isFullScreen
        window.toggleFullScreen(nil)
    }

    private func clear(ifShowing state: PlaybackScreen) {
        guard screen === state else { return }
        state.stopTimers()
        screen = nil
        videoLayer = nil
        if enteredFullScreen, let window = hostWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        enteredFullScreen = false
        isExpanded = false
        removeKeys()
    }

    // MARK: Keys

    /// While a video is in the panel, the main window's keys without ⌘ control it (except while
    /// typing in a text field): space, ←/→, ↑/↓, M, F, and esc to leave full screen, shrink the
    /// panel, then close it.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) == true ? nil : event }
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let screen, let window = event.window, window === hostWindow,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !(window.firstResponder is NSText) else { return false }
        switch event.keyCode {
        case 53:
            if window.styleMask.contains(.fullScreen) {
                toggleFullScreen()
            } else if isExpanded {
                isExpanded = false
            } else {
                stop()
            }
            return true
        case 49, 123, 124, 125, 126:
            screen.handleKey(code: event.keyCode, characters: event.charactersIgnoringModifiers)
            return true
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "m", "f":
                screen.handleKey(code: event.keyCode, characters: event.charactersIgnoringModifiers)
                return true
            default:
                return false
            }
        }
    }
}
