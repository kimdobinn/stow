import SwiftUI
import UIKit

/// The pull at the end of a list, as numbers (pure, so it's tested).
struct PullUpRules {
    /// How far past the end the content has to come before letting go refreshes.
    static let threshold: CGFloat = 70

    /// How far the content is pulled past its end: 0 inside it. A list shorter than the screen
    /// ends at its top.
    static func overscroll(offset: CGFloat, contentHeight: CGFloat, viewHeight: CGFloat, insetTop: CGFloat, insetBottom: CGFloat) -> CGFloat {
        max(0, pastEnd(offset: offset, contentHeight: contentHeight, viewHeight: viewHeight, insetTop: insetTop, insetBottom: insetBottom))
    }

    /// Where the content is against its end: negative inside the list, positive pulled past it.
    static func pastEnd(offset: CGFloat, contentHeight: CGFloat, viewHeight: CGFloat, insetTop: CGFloat, insetBottom: CGFloat) -> CGFloat {
        offset - max(contentHeight + insetBottom - viewHeight, -insetTop)
    }

    /// Only a drag that starts at the end pulls: one that scrolls the list and then hits the end
    /// doesn't, so swiping down quickly to the bottom never refreshes by accident.
    static func startsAtEnd(pastEnd: CGFloat) -> Bool { pastEnd >= -2 }

    static func progress(_ overscroll: CGFloat) -> Double { min(1, overscroll / threshold) }

    /// Letting go refreshes only past the threshold, and only when one isn't already running.
    static func fires(overscroll: CGFloat, refreshing: Bool) -> Bool { !refreshing && overscroll >= threshold }
}

extension View {
    /// Pull up at the end of the list to refresh, as well as pull down at the top: the spinner
    /// comes up from the bottom, and after the refresh the list goes back to the top, where the
    /// fresh batch is. Put it on the scroll view's content.
    func pullUpToRefresh(_ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(PullUpModifier(action: action))
    }
}

private struct PullUpModifier: ViewModifier {
    let action: @MainActor () async -> Void
    @State private var model = PullUpModel()

    func body(content: Content) -> some View {
        content
            .background(ScrollViewFinder(model: model))
            .onAppear { model.action = action }
    }
}

/// Puts the spinner over the bottom of the scroll view the content belongs to.
private struct PullUpIndicator: View {
    let model: PullUpModel

    var body: some View {
        if model.refreshing || model.overscroll > 0 {
            ZStack {
                Circle().fill(.regularMaterial).shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                // Letting go past the threshold hands the ring straight over to the spinner.
                if model.refreshing {
                    ProgressView()
                        .transition(.opacity)
                } else {
                    Circle()
                        .trim(from: 0, to: PullUpRules.progress(model.overscroll))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 20, height: 20)
                        .transition(.opacity)
                }
            }
            .frame(width: 38, height: 38)
            .opacity(model.refreshing ? 1 : max(0.25, PullUpRules.progress(model.overscroll)))
            .scaleEffect(model.refreshing ? 1 : 0.6 + 0.4 * PullUpRules.progress(model.overscroll))
            .transition(.scale.combined(with: .opacity))
        }
    }
}

@MainActor @Observable
final class PullUpModel {
    var overscroll: CGFloat = 0
    var refreshing = false
    @ObservationIgnored var action: (@MainActor () async -> Void)?
    @ObservationIgnored weak var scrollView: UIScrollView?
    @ObservationIgnored private var armed = false
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var host: UIHostingController<PullUpIndicator>?
    @ObservationIgnored private let haptics = UIImpactFeedbackGenerator(style: .light)

    func attach(_ scrollView: UIScrollView) {
        guard self.scrollView !== scrollView else { return }
        self.scrollView = scrollView
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(pan(_:)))
        observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.offsetChanged() }
        }
        // The spinner lives in the scroll view's superview, over its bottom edge (above the tab bar).
        if let container = scrollView.superview {
            let host = UIHostingController(rootView: PullUpIndicator(model: self))
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
                host.view.bottomAnchor.constraint(equalTo: scrollView.safeAreaLayoutGuide.bottomAnchor, constant: -12),
                host.view.widthAnchor.constraint(equalToConstant: 44),
                host.view.heightAnchor.constraint(equalToConstant: 44),
            ])
            self.host = host
        }
    }

    /// This drag began at the end of the list, so it can pull.
    @ObservationIgnored private var dragStartedAtEnd = false

    private func currentPastEnd() -> CGFloat {
        guard let scrollView else { return -.greatestFiniteMagnitude }
        let inset = scrollView.adjustedContentInset
        return PullUpRules.pastEnd(offset: scrollView.contentOffset.y, contentHeight: scrollView.contentSize.height,
                                   viewHeight: scrollView.bounds.height, insetTop: inset.top, insetBottom: inset.bottom)
    }

    private func currentOverscroll() -> CGFloat {
        guard let scrollView else { return 0 }
        let inset = scrollView.adjustedContentInset
        return PullUpRules.overscroll(offset: scrollView.contentOffset.y, contentHeight: scrollView.contentSize.height,
                                      viewHeight: scrollView.bounds.height, insetTop: inset.top, insetBottom: inset.bottom)
    }

    private func offsetChanged() {
        // Only the finger pulls; a fling that bounces off the end doesn't.
        guard let scrollView, scrollView.isTracking, dragStartedAtEnd, !refreshing else {
            // Let go short: the ring shrinks and fades instead of vanishing.
            if overscroll != 0 { withAnimation(Motion.quick) { overscroll = 0 } }
            return
        }
        overscroll = currentOverscroll()
        if !armed, overscroll >= PullUpRules.threshold {
            armed = true
            haptics.impactOccurred()
        } else if armed, overscroll < PullUpRules.threshold {
            armed = false
        }
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            dragStartedAtEnd = PullUpRules.startsAtEnd(pastEnd: currentPastEnd())
            if dragStartedAtEnd { haptics.prepare() }
        case .ended:
            let fire = dragStartedAtEnd && PullUpRules.fires(overscroll: currentOverscroll(), refreshing: refreshing)
            dragStartedAtEnd = false
            armed = false
            withAnimation(Motion.quick) { overscroll = 0 }
            if fire { refresh() }
        case .cancelled, .failed:
            dragStartedAtEnd = false
            armed = false
            withAnimation(Motion.quick) { overscroll = 0 }
        default: break
        }
    }

    private func refresh() {
        guard let action else { return }
        withAnimation(Motion.brisk) { refreshing = true }
        Task { @MainActor in
            await action()
            if let scrollView {
                scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: true)
            }
            withAnimation(Motion.brisk) { refreshing = false }
        }
    }
}

/// Finds the UIScrollView a SwiftUI ScrollView is drawn with, from inside its content.
private struct ScrollViewFinder: UIViewRepresentable {
    let model: PullUpModel

    func makeUIView(context: Context) -> FinderView {
        let view = FinderView()
        view.model = model
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: FinderView, context: Context) {}

    final class FinderView: UIView {
        weak var model: PullUpModel?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var view: UIView? = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            if let scrollView = view as? UIScrollView { model?.attach(scrollView) }
        }
    }
}
