import Foundation
import Testing
@testable import Stow

struct YTDLPTests {
    @Test(arguments: [
        ("WARNING: [youtube:tab] The provided YouTube account cookies are no longer valid. They have likely been rotated", YTDLP.Failure.auth),
        ("ERROR: [youtube] abc: Sign in to confirm you’re not a bot. Use --cookies-from-browser or --cookies for the authentication.", .auth),
        ("WARNING: [youtube:tab] YouTube said: The playlist does not exist.\nERROR: [youtube:tab] UUMF-X: YouTube said: The playlist does not exist.", .unavailable),
        ("ERROR: [youtube:tab] UUMFx: Unable to download webpage: HTTP Error 404: Not Found", .unavailable),
        ("ERROR: [youtube] abc: Video unavailable", .unavailable),
        ("ERROR: Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided, or not known>", .network),
        ("ERROR: Unable to download API page: HTTP Error 503: Service Unavailable", .network),
        ("Traceback (most recent call last):\nKeyError: 'x'", .other),
        ("", .other),
    ])
    func classifiesStderr(stderr: String, expected: YTDLP.Failure) {
        #expect(YTDLP.classify(stderr: stderr) == expected)
    }

    @Test func summaryKeepsErrorLines() {
        let stderr = "WARNING: noise\nERROR: first\n  \nERROR: second\n"
        #expect(YTDLP.summary(of: stderr) == "ERROR: first\nERROR: second")
        #expect(YTDLP.summary(of: "a\nb\nc\nd") == "b\nc\nd")
    }

    @Test func missingToolThrows() {
        #expect(throws: StowError.toolNotFound("definitely-not-a-tool")) { try ToolLocator.url(for: "definitely-not-a-tool") }
    }
}
