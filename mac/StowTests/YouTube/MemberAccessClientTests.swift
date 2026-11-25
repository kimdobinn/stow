import Testing
@testable import Stow

struct MemberAccessClientTests {
    @Test func readsTheLevelALockedVideoNeeds() {
        let error = "ERROR: [youtube] vgfM2tMY69M: This video is available to this channel's members on level: 티미단 이사님 (or any higher level). Join this channel to get access to members-only content and other exclusive perks."
        #expect(MemberAccessClient.access(fromError: error) == .locked(level: "티미단 이사님"))
        #expect(MemberAccessClient.access(fromError: "ERROR: [youtube] x: Join this channel to get access to members-only content like this video, and other exclusive perks.")
                == .locked(level: nil))
    }

    @Test func aStreamProblemAfterGettingInIsWatchable() {
        #expect(MemberAccessClient.access(fromError: "ERROR: [youtube] x: Requested format is not available. Use --list-formats") == .watchable)
        #expect(MemberAccessClient.access(fromError: "ERROR: [youtube] x: Unable to download webpage: timed out") == nil)
    }
}
