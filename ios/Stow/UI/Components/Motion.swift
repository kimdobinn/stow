import SwiftUI

/// How the app moves, in one place so everything moves alike, as on YouTube: quick (150 to 300
/// ms), slowing down as things arrive and speeding up as they leave, and no bounce. Gestures
/// follow the finger and finish on a spring that starts at the finger's speed (`Motion.settle`).
/// With Reduce Motion, big movements become fades (`motionTransition`).
enum Motion {
    /// Most changes: a row going or coming, a banner, a section folding, selection mode.
    static let standard = Animation.spring(duration: 0.3, bounce: 0)
    /// Small state changes: a disc, a spinner taking over, replies folding open.
    static let brisk = Animation.spring(duration: 0.25, bounce: 0)
    /// Something arriving on screen (Material's emphasized decelerate).
    static let enter = Animation.timingCurve(0.05, 0.7, 0.1, 1, duration: 0.25)
    /// Something leaving (emphasized accelerate).
    static let exit = Animation.timingCurve(0.3, 0, 0.8, 0.15, duration: 0.2)
    /// A quick swap: a color, a spinner becoming its value.
    static let quick = Animation.easeOut(duration: 0.15)
    /// A fade, for content that loaded or an overlay coming or going.
    static let fade = Animation.easeOut(duration: 0.2)
    /// Welcome, pairing and the app replacing each other.
    static let screen = Animation.easeInOut(duration: 0.3)
    /// The watch page opening from and shrinking into the mini player.
    static let player = Animation.spring(duration: 0.3, bounce: 0)
    /// The player's controls: in quickly, out a touch slower.
    static let controlsIn = Animation.easeOut(duration: 0.15)
    static let controlsOut = Animation.easeIn(duration: 0.2)
    /// A finger on a button.
    static let press = Animation.spring(duration: 0.2, bounce: 0)
    /// Download progress: linear over about the time between updates, so the fill reads as
    /// one continuous movement instead of steps.
    static let progress = Animation.linear(duration: 0.5)

    /// Finishes a drag: a spring without bounce from `value` to `target`, starting at the
    /// finger's speed (points per second, in the value's direction).
    static func settle(from value: CGFloat, to target: CGFloat, velocity: CGFloat, duration: Double = 0.3) -> Animation {
        .interpolatingSpring(duration: duration, bounce: 0,
                             initialVelocity: MotionRules.relativeVelocity(velocity, from: value, to: target, duration: duration))
    }
}

extension View {
    /// A transition that becomes a plain fade with Reduce Motion on.
    func motionTransition(_ transition: AnyTransition) -> some View {
        modifier(MotionTransition(transition: transition))
    }

    /// Changes in the view animate with `animation` while `value` changes, unless the change
    /// already has its own animation (or turned animations off): a default for changes that come
    /// from many places, which a gesture with its own spring can still override.
    func defaultAnimation(_ animation: Animation, value: some Equatable) -> some View {
        transaction(value: value) { transaction in
            if transaction.animation == nil, !transaction.disablesAnimations { transaction.animation = animation }
        }
    }
}

private struct MotionTransition: ViewModifier {
    let transition: AnyTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : transition)
    }
}

/// Runs `change` without any animation, even under a view's `.animation(_:value:)`: for
/// switching what a screen shows (a chip, a filter), which YouTube does at once.
@MainActor func withoutAnimation(_ change: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, change)
}
