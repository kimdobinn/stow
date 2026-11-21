import CoreGraphics
import Testing
@testable import Stow

struct PanelWindowLayoutTests {
    private let visible = CGRect(x: 0, y: 0, width: 2000, height: 1100)

    @Test func growsToTheRight() {
        let window = CGRect(x: 100, y: 50, width: 1180, height: 760)
        #expect(PanelWindowLayout.grownFrame(window: window, visible: visible, grow: 600)
                == CGRect(x: 100, y: 50, width: 1780, height: 760))
    }

    @Test func movesLeftWhenTheRightEdgeWouldLeaveTheScreen() {
        let window = CGRect(x: 700, y: 50, width: 1180, height: 760)
        #expect(PanelWindowLayout.grownFrame(window: window, visible: visible, grow: 600)
                == CGRect(x: 220, y: 50, width: 1780, height: 760))
    }

    @Test func stopsAtTheScreenWidth() {
        let window = CGRect(x: 300, y: 50, width: 1500, height: 760)
        #expect(PanelWindowLayout.grownFrame(window: window, visible: visible, grow: 900)
                == CGRect(x: 0, y: 50, width: 2000, height: 760))
        let full = CGRect(x: 0, y: 0, width: 2000, height: 1100)
        #expect(PanelWindowLayout.grownFrame(window: full, visible: visible, grow: 900) == full)
    }

    @Test func goesBackWhereItWasWhenUntouched() {
        let original = CGRect(x: 700, y: 50, width: 1180, height: 760)
        let grown = CGRect(x: 220, y: 50, width: 1780, height: 760)
        #expect(PanelWindowLayout.shrunkFrame(current: grown, grown: grown, original: original, shrink: 600, minWidth: 820)
                == original)
        let rounded = CGRect(x: 220, y: 50, width: 1779, height: 760)
        #expect(PanelWindowLayout.shrunkFrame(current: rounded, grown: grown, original: original, shrink: 600, minWidth: 820)
                == original)
    }

    @Test func narrowsByThePanelWhenMovedOrResized() {
        let grown = CGRect(x: 220, y: 50, width: 1780, height: 760)
        let moved = CGRect(x: 100, y: 80, width: 1700, height: 700)
        #expect(PanelWindowLayout.shrunkFrame(current: moved, grown: grown, original: .zero, shrink: 600, minWidth: 820)
                == CGRect(x: 100, y: 80, width: 1100, height: 700))
        #expect(PanelWindowLayout.shrunkFrame(current: moved, grown: grown, original: .zero, shrink: 1500, minWidth: 820).width
                == 820)
    }
}
