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

    // The window grows to the right for the panel, so the section keeps its width.
    /// The section's width while the panel is beside it, when the window grew for the panel.
    var keptSectionWidth: CGFloat?
    /// The window is being widened or narrowed for the panel: the section keeps its width exactly.
    private(set) var isResizingWindow = false
    /// How wide the panel will be when it opens, and how wide the section is (set by the window).
    @ObservationIgnored var plannedPanelWidth: CGFloat = 640
    @ObservationIgnored var detailWidth: CGFloat = 0
    @ObservationIgnored private var originalFrame: CGRect?
    @ObservationIgnored private var grownFrame: CGRect?
    /// The panel that is closing, while the window narrows.
    @ObservationIgnored private weak var closing: PlaybackScreen?
    static let minSectionWidth: CGFloat = 320
    static let resizeDuration: TimeInterval = 0.25

    /// Shows a new video's controls and video, replacing any video playing in the panel.
    func present(core: MPVCore, updates: AsyncStream<NowPlaying>,
                 perform: @escaping @Sendable (PlaybackAction) -> Void) throws {
        let opening = screen == nil || screen === closing
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
        if opening { growWindow() }
    }

    /// Widens the window to the right by the panel's width, so the section beside it stays as it is.
    private func growWindow() {
        closing = nil
        guard let window = hostWindow, !window.styleMask.contains(.fullScreen),
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
            keptSectionWidth = nil
            return
        }
        // Opened again while narrowing back: widen to where it was.
        if let grownFrame, originalFrame != nil, keptSectionWidth != nil {
            resize(window, to: grownFrame) {}
            return
        }
        let wanted = plannedPanelWidth + 1
        let original = originalFrame ?? window.frame
        let grown = PanelWindowLayout.grownFrame(window: window.frame, visible: visible, grow: wanted)
        let shortfall = wanted - (grown.width - window.frame.width)
        keptSectionWidth = max(detailWidth - shortfall, Self.minSectionWidth)
        guard grown != window.frame else { return }
        originalFrame = original
        grownFrame = grown
        resize(window, to: grown) {}
    }

    private func resize(_ window: NSWindow, to frame: CGRect, then done: @escaping @MainActor () -> Void) {
        isResizingWindow = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.resizeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        } completionHandler: {
            MainActor.assumeIsolated {
                self.isResizingWindow = false
                done()
            }
        }
    }

    #if DEBUG
    /// Shows `state` in the panel with no video playing, for `--snapshot`.
    func showPreview(_ state: PlaybackScreen?) {
        screen = state
        videoLayer = nil
    }
    #endif

    /// Stops the video and closes the panel at once (mpv may take a few seconds to stop while
    /// it's still looking the video up).
    func stop() {
        guard let screen else { return }
        screen.perform(.stop)
        clear(ifShowing: screen)
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
        guard screen === state, closing !== state else { return }
        state.stopTimers()
        // Narrow the window back first, the panel shrinking away on the right.
        if !enteredFullScreen, let window = hostWindow, !window.styleMask.contains(.fullScreen),
           let grown = grownFrame, let original = originalFrame, let kept = keptSectionWidth {
            let target = PanelWindowLayout.shrunkFrame(current: window.frame, grown: grown, original: original,
                                                       shrink: detailWidth - kept, minWidth: window.minSize.width)
            closing = state
            isExpanded = false
            resize(window, to: target) { [weak self] in
                guard let self, self.closing === state else { return }
                self.closing = nil
                self.finishClosing(state)
            }
            return
        }
        finishClosing(state)
    }

    private func finishClosing(_ state: PlaybackScreen) {
        guard screen === state else { return }
        originalFrame = nil
        grownFrame = nil
        keptSectionWidth = nil
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

    /// While a video is in the panel, ⌘W closes it, and the main window's keys without ⌘ control
    /// it (except while typing in a text field): space, ←/→, ↑/↓, M, F, and esc to leave full
    /// screen, shrink the panel, then close it.
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
        // ⌘W closes the video, not the window.
        if screen != nil, let window = event.window, window === hostWindow,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            stop()
            return true
        }
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
