import Testing
@testable import Stow

@MainActor
struct PlaybackKeysTests {
    @Test func lettersWorkWithAKoreanInputSource() {
        var actions: [PlaybackAction] = []
        var fullScreenToggles = 0
        let screen = PlaybackScreen(mode: .watch, perform: { actions.append($0) })
        screen.toggleFullScreen = { fullScreenToggles += 1 }
        screen.update(NowPlaying(index: 0, count: 1, video: video("abcdefghijk"), isLoading: false,
                                 isPaused: false, position: 0, duration: 60))
        screen.handleKey(code: KeyCode.f, characters: "ㄹ")
        screen.handleKey(code: KeyCode.m, characters: "ㅡ")
        #expect(fullScreenToggles == 1)
        #expect(actions == [.setMuted(true)])
    }

    @Test func skipsFiveSecondsUnlessChanged() {
        #expect(PlaybackScreen.seekStep(stored: 0) == 5)
        #expect(PlaybackScreen.seekStep(stored: 15) == 15)
        #expect(PlaybackScreen.seekStep(stored: 7) == 5)
    }
}
