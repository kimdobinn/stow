import CoreGraphics
import Testing
@testable import Stow

/// The gestures' numbers: when a drag counts, and the speed the finishing spring starts at.
@Suite struct MotionTests {
    @Test func theFingersSpeedIsInLengthsOfTheMovePerSecond() {
        // Pulled down 100 pt and still moving down at 200 pt/s, settling back to 0: away from
        // the target, two lengths per second.
        #expect(MotionRules.relativeVelocity(200, from: 100, to: 0, duration: 0.3) == -2)
        // Flicked back up at 300 pt/s: toward the target.
        #expect(MotionRules.relativeVelocity(-300, from: 100, to: 0, duration: 0.3) == 3)
        // Thrown off to the side: 1000 pt/s with 400 pt to go.
        #expect(MotionRules.relativeVelocity(1000, from: 100, to: 500, duration: 0.3) == 2.5)
    }

    @Test func aFastFlingIsCappedSoTheSpringDoesNotOvershoot() {
        let limit = 2 * Double.pi / 0.3
        #expect(MotionRules.relativeVelocity(5000, from: 0, to: 10, duration: 0.3) == limit)
        #expect(MotionRules.relativeVelocity(-5000, from: 0, to: 10, duration: 0.3) == -limit)
    }

    @Test func noMoveLeftMeansNoSpeed() {
        #expect(MotionRules.relativeVelocity(800, from: 0, to: 0, duration: 0.3) == 0)
        #expect(MotionRules.relativeVelocity(800, from: 0.4, to: 0, duration: 0.3) == 0)
        #expect(MotionRules.relativeVelocity(800, from: 0, to: 100, duration: 0) == 0)
    }

    @Test func thePageCollapsesWhenPulledFarOrFast() {
        #expect(MotionRules.collapses(pull: 121, velocity: 0))
        #expect(MotionRules.collapses(pull: 20, velocity: 901))
        #expect(!MotionRules.collapses(pull: 120, velocity: 900))
        #expect(!MotionRules.collapses(pull: 60, velocity: -400))
    }

    @Test func thePageFadesAndShrinksAsItIsPulled() {
        #expect(MotionRules.detailsOpacity(pull: 0) == 1)
        #expect(MotionRules.detailsOpacity(pull: 150) == 0.5)
        #expect(MotionRules.detailsOpacity(pull: 900) == 0)
        #expect(MotionRules.detailsOpacity(pull: -40) == 1)
        #expect(MotionRules.pageScale(pull: 0) == 1)
        #expect(MotionRules.pageScale(pull: 187.5) == 0.9375)
        #expect(MotionRules.pageScale(pull: 2000) == 0.92)
    }

    @Test func theMiniPlayerLiftsLessThanTheFingerAndOnlyUp() {
        #expect(MotionRules.miniPlayerLift(-50) == -30)
        #expect(MotionRules.miniPlayerLift(40) == 0)
    }

    @Test func swipingTheMiniPlayerFarOrFastClosesItToThatSide() {
        let far = MotionRules.miniPlayerRelease(translation: CGSize(width: -130, height: 10),
                                                predictedEnd: CGSize(width: -140, height: 10), velocity: .zero)
        #expect(far == .dismiss(direction: -1))
        let flung = MotionRules.miniPlayerRelease(translation: CGSize(width: 60, height: 5),
                                                  predictedEnd: CGSize(width: 300, height: 5), velocity: CGSize(width: 1200, height: 0))
        #expect(flung == .dismiss(direction: 1))
        let short = MotionRules.miniPlayerRelease(translation: CGSize(width: 60, height: 5),
                                                  predictedEnd: CGSize(width: 90, height: 5), velocity: CGSize(width: 100, height: 0))
        #expect(short == .settle)
    }

    @Test func pushingTheMiniPlayerUpOpensTheWatchPage() {
        let pushed = MotionRules.miniPlayerRelease(translation: CGSize(width: 2, height: -30), predictedEnd: CGSize(width: 2, height: -60), velocity: .zero)
        #expect(pushed == .expand)
        let flicked = MotionRules.miniPlayerRelease(translation: CGSize(width: 2, height: -14), predictedEnd: CGSize(width: 2, height: -80),
                                                    velocity: CGSize(width: 0, height: -700))
        #expect(flicked == .expand)
        let down = MotionRules.miniPlayerRelease(translation: CGSize(width: 2, height: 40), predictedEnd: CGSize(width: 2, height: 60),
                                                 velocity: CGSize(width: 0, height: 300))
        #expect(down == .settle)
    }
}
