import Foundation
import Testing
@testable import Stow

/// Pulling up at the end of a feed: how far past the end, and when letting go refreshes.
@Suite struct PullUpTests {
    @Test func insideTheListThereIsNoPull() {
        // 2000 pt of content in an 800 pt view with 100 pt insets: the end is at 1300.
        #expect(PullUpRules.overscroll(offset: 500, contentHeight: 2000, viewHeight: 800, insetTop: 100, insetBottom: 100) == 0)
        #expect(PullUpRules.overscroll(offset: 1300, contentHeight: 2000, viewHeight: 800, insetTop: 100, insetBottom: 100) == 0)
    }

    @Test func pastTheEndIsThePull() {
        #expect(PullUpRules.overscroll(offset: 1380, contentHeight: 2000, viewHeight: 800, insetTop: 100, insetBottom: 100) == 80)
        #expect(PullUpRules.progress(35) == 0.5)
        #expect(PullUpRules.progress(200) == 1)
    }

    @Test func aShortListEndsAtItsTop() {
        // 300 pt of content in an 800 pt view: any pull up from the top counts.
        #expect(PullUpRules.overscroll(offset: -100, contentHeight: 300, viewHeight: 800, insetTop: 100, insetBottom: 100) == 0)
        #expect(PullUpRules.overscroll(offset: -20, contentHeight: 300, viewHeight: 800, insetTop: 100, insetBottom: 100) == 80)
    }

    @Test func onlyADragStartingAtTheEndPulls() {
        // At the end (1300 of 1300), or a point short of it: pulls.
        #expect(PullUpRules.startsAtEnd(pastEnd: PullUpRules.pastEnd(offset: 1300, contentHeight: 2000, viewHeight: 800, insetTop: 100, insetBottom: 100)))
        #expect(PullUpRules.startsAtEnd(pastEnd: -1))
        // Still scrolling the list: doesn't.
        #expect(!PullUpRules.startsAtEnd(pastEnd: PullUpRules.pastEnd(offset: 900, contentHeight: 2000, viewHeight: 800, insetTop: 100, insetBottom: 100)))
    }

    @Test func lettingGoRefreshesOnlyPastTheThreshold() {
        #expect(PullUpRules.fires(overscroll: 70, refreshing: false))
        #expect(!PullUpRules.fires(overscroll: 69, refreshing: false))
        #expect(!PullUpRules.fires(overscroll: 120, refreshing: true))
    }
}
