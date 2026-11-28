import CoreGraphics

/// The numbers behind the app's gestures (pure, so they're tested): when a drag counts, and how
/// fast the spring that finishes it should start.
enum MotionRules {
    /// The finger's speed as a spring's starting speed. SwiftUI counts it in lengths of the move
    /// per second (positive toward the target); capped at the spring's own pace, so a critically
    /// damped spring never shoots past the target and back.
    static func relativeVelocity(_ velocity: CGFloat, from value: CGFloat, to target: CGFloat, duration: Double) -> Double {
        let distance = Double(target - value)
        guard abs(distance) >= 1, duration > 0 else { return 0 }
        let limit = 2 * Double.pi / duration
        return min(max(Double(velocity) / distance, -limit), limit)
    }

    // MARK: - The watch page

    /// Letting go of the video after pulling it down: far enough or fast enough shrinks the page
    /// into the mini player, else it settles back.
    static func collapses(pull: CGFloat, velocity: CGFloat) -> Bool {
        pull > 120 || velocity > 900
    }

    /// While the page is pulled down, the details under the video fade out...
    static func detailsOpacity(pull: CGFloat) -> Double {
        1 - Double(min(max(pull, 0) / 300, 1))
    }

    /// ...and the page shrinks a little toward the mini player.
    static func pageScale(pull: CGFloat) -> CGFloat {
        1 - min(max(pull, 0) / 3000, 0.08)
    }

    /// In full screen the video moves half as far as the finger (there's nowhere to shrink to).
    static let fullScreenPullFactor: CGFloat = 0.5

    // MARK: - The mini player

    enum MiniPlayerRelease: Equatable {
        /// Swiped off to that side (-1 left, 1 right): closes the player.
        case dismiss(direction: CGFloat)
        /// Pushed up: opens the watch page.
        case expand
        /// Too short: back to where it was.
        case settle
    }

    /// Dragging the mini player up lifts it a little less than the finger, to feel tied down.
    static func miniPlayerLift(_ translation: CGFloat) -> CGFloat {
        min(translation, 0) * 0.6
    }

    /// Where the mini player goes when let go: aside far or fast enough closes it, up opens the
    /// watch page.
    static func miniPlayerRelease(translation: CGSize, predictedEnd: CGSize, velocity: CGSize) -> MiniPlayerRelease {
        let sideways = abs(translation.width) > abs(translation.height)
        if sideways {
            if abs(translation.width) > 120 || abs(predictedEnd.width) > 260 {
                let direction: CGFloat = (abs(translation.width) > 1 ? translation.width : predictedEnd.width) > 0 ? 1 : -1
                return .dismiss(direction: direction)
            }
            return .settle
        }
        return translation.height < -20 || velocity.height < -500 ? .expand : .settle
    }

    /// How far a swiped-away mini player travels: past either edge of any phone.
    static let miniPlayerFling: CGFloat = 500
}
