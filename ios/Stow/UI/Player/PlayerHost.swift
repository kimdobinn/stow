import StowKit
import SwiftUI
import UIKit

extension View {
    /// The player over the app: the watch page when open, the mini player above the tabs when not,
    /// playing whatever `Shell.playback` asks for.
    func playerHost() -> some View {
        modifier(PlayerHost())
    }

    /// Room for the mini player at the bottom of a tab, above the tab bar.
    func miniPlayerInset() -> some View {
        modifier(MiniPlayerInset())
    }
}

private struct PlayerHost: ViewModifier {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(PlaybackController.self) private var controller

    func body(content: Content) -> some View {
        let expanded = shell.playback != nil && shell.playerExpanded
        content
            .overlay {
                if expanded {
                    WatchPage()
                        .accessibilityAddTraits(.isModal)
                        .transition(.move(edge: .bottom))
                }
            }
            .animation(.spring(duration: 0.35, bounce: 0), value: shell.playerExpanded)
            .animation(.spring(duration: 0.35, bounce: 0), value: shell.playback == nil)
            .environment(\.downloadHold, repository.downloads.hold)
            // The watch page covers the tabs: VoiceOver mustn't reach the hidden cards and tab bar.
            // SwiftUI's accessibilityHidden doesn't reach into the UIKit tab bar controller, so
            // hide its view directly.
            .onChange(of: expanded, initial: true) { _, expanded in CoveredTabs.setHidden(expanded) }
            .onChange(of: shell.playback) { _, request in
                if let request { controller.play(request) } else { controller.stop() }
            }
            .task {
                // `-play <video id>` opens the player on that video at launch (for checking a build).
                let arguments = ProcessInfo.processInfo.arguments
                guard let index = arguments.firstIndex(of: "-play"), index + 1 < arguments.count,
                      let item = repository.item(arguments[index + 1]) else { return }
                shell.play(item)
            }
    }
}

/// The tab bar and navigation bars under the watch page, which are UIKit's: hidden from VoiceOver
/// while the page is up (the screens themselves hide, see `coveredByPlayer`).
@MainActor
private enum CoveredTabs {
    static func setHidden(_ hidden: Bool) {
        // After SwiftUI has put the watch page on screen (or taken it away).
        DispatchQueue.main.async {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                for window in scene.windows {
                    guard let tabs = tabBarController(in: window.rootViewController) else { continue }
                    tabs.tabBar.accessibilityElementsHidden = hidden
                    for navigation in navigationControllers(under: tabs) {
                        navigation.navigationBar.accessibilityElementsHidden = hidden
                    }
                    UIAccessibility.post(notification: .screenChanged, argument: nil)
                    if !hidden { expandLargeTitles(in: tabs) }
                }
            }
        }
    }

    /// Full screen turns the window sideways, which collapses the large titles under the watch
    /// page, and UIKit doesn't expand them again back upright. A screen still scrolled to its top
    /// gets its large title back.
    private static func expandLargeTitles(in tabs: UITabBarController) {
        for navigation in navigationControllers(under: tabs) {
            guard navigation.navigationBar.prefersLargeTitles || navigation.topViewController?.navigationItem.largeTitleDisplayMode == .always,
                  let root = navigation.topViewController?.view, let scrollView = firstScrollView(in: root) else { continue }
            guard scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 1 else { continue }
            navigation.navigationBar.sizeToFit()
            navigation.view.layoutIfNeeded()
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top), animated: false)
        }
    }

    private static func navigationControllers(under controller: UIViewController) -> [UINavigationController] {
        controller.children.flatMap { child -> [UINavigationController] in
            (child as? UINavigationController).map { [$0] } ?? navigationControllers(under: child)
        }
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        var queue = [view]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let scrollView = next as? UIScrollView, scrollView.bounds.height > 200 { return scrollView }
            queue += next.subviews
        }
        return nil
    }

    private static func tabBarController(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let tabs = tabBarController(in: child) { return tabs }
        }
        return nil
    }
}

private struct MiniPlayerInset: ViewModifier {
    @Environment(Shell.self) private var shell

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if shell.playback != nil, !shell.playerExpanded {
                    MiniPlayer()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
    }
}

/// The player shrunk above the tabs: the video, its title and channel, play or pause, close, and
/// a thin line for how far it is. Tap or drag it up for the watch page; swipe it aside to close.
struct MiniPlayer: View {
    @Environment(Shell.self) private var shell
    @Environment(PlaybackController.self) private var controller
    @Environment(\.stowColors) private var colors
    @State private var swipe: CGFloat = 0

    var body: some View {
        let item = controller.current
        HStack(spacing: 0) {
            VideoSurface(controller: controller, fill: true)
                .frame(width: 96, height: 54)
                .overlay {
                    if controller.isResolving { ProgressView().controlSize(.small).tint(.white) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.leading, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(item?.video.title ?? "")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(colors.text)
                    .lineLimit(1)
                Text(controller.error ?? item?.video.channelTitle ?? "")
                    .font(.caption)
                    .foregroundStyle(colors.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                controller.togglePlay()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(colors.text)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
            Button {
                shell.closePlayer()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(colors.text)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .accessibilityLabel("Close")
        }
        .frame(height: 66)
        .background(colors.raised)
        .overlay(alignment: .bottomLeading) {
            GeometryReader { proxy in
                Rectangle().fill(colors.accent)
                    .frame(width: proxy.size.width * controller.fraction, height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 2)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(colors.divider.opacity(0.6), lineWidth: 0.5)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .offset(x: swipe)
        .opacity(1 - min(abs(swipe) / 300, 0.8))
        .contentShape(Rectangle())
        .onTapGesture { expand() }
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    if abs(value.translation.width) > abs(value.translation.height) { swipe = value.translation.width }
                }
                .onEnded { value in
                    let sideways = abs(value.translation.width) > abs(value.translation.height)
                    if sideways, abs(value.translation.width) > 120 || abs(value.predictedEndTranslation.width) > 260 {
                        withAnimation(.easeOut(duration: 0.2)) { swipe = value.translation.width > 0 ? 500 : -500 }
                        shell.closePlayer()
                    } else if !sideways, value.translation.height < -20 {
                        expand()
                    } else {
                        withAnimation(.spring) { swipe = 0 }
                    }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open player") { expand() }
    }

    private func expand() {
        withAnimation(.spring(duration: 0.35, bounce: 0)) { shell.playerExpanded = true }
    }
}

nonisolated private struct DownloadHoldKey: EnvironmentKey {
    static let defaultValue = DownloadManager.Hold.none
}

extension EnvironmentValues {
    /// Why waiting downloads aren't running (no connection, waiting for Wi-Fi), for their status.
    nonisolated var downloadHold: DownloadManager.Hold {
        get { self[DownloadHoldKey.self] }
        set { self[DownloadHoldKey.self] = newValue }
    }
}
