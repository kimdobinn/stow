import Foundation
import Testing
@testable import Stow

struct StreamCacheTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "stream-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func json(_ id: String, live: String = "not_live") -> Data {
        Data(#"{"id": "\#(id)", "live_status": "\#(live)", "duration": 10}"#.utf8)
    }

    @Test func usesMpvsOwnArguments() {
        let arguments = StreamCache.arguments(videoId: "abcdefghijk", format: "bv*+ba/b", cookies: URL(filePath: "/c/1.txt"))
        #expect(arguments == ["--no-warnings", "-J", "--flat-playlist", "--sub-format", "ass/srt/best",
                              "--format", "bv*+ba/b", "--sub-langs", "all", "--write-srt", "--no-playlist",
                              "--cookies", "/c/1.txt", "--", "https://www.youtube.com/watch?v=abcdefghijk"])
        #expect(!StreamCache.arguments(videoId: "x", format: "f", cookies: nil).contains("--cookies"))
    }

    @Test func keepsVideosButNotLiveStreamsOrOtherIds() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(StreamCache.store(json: json("abcdefghijk"), videoId: "abcdefghijk", in: directory))
        #expect(StreamCache.isFresh("abcdefghijk", in: directory))
        #expect(!StreamCache.store(json: json("livelivelive", live: "is_live"), videoId: "livelivelive", in: directory))
        #expect(!StreamCache.store(json: json("otherotherx"), videoId: "abcdefghijz", in: directory))
        #expect(!StreamCache.store(json: Data("nope".utf8), videoId: "abcdefghijk", in: directory))
        #expect(!StreamCache.isFresh("livelivelive", in: directory))
    }

    @Test func handsBackOnlyFreshAnswers() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(StreamCache.cached("abcdefghijk", in: directory) == nil)
        StreamCache.store(json: json("abcdefghijk"), videoId: "abcdefghijk", in: directory)
        #expect(StreamCache.cached("abcdefghijk", in: directory) == json("abcdefghijk"))
        let later = Date.now.addingTimeInterval(StreamCache.lifetime + 1)
        #expect(StreamCache.cached("abcdefghijk", in: directory, now: later) == nil)
    }

    @Test func oldAnswersAreStale() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        StreamCache.store(json: json("abcdefghijk"), videoId: "abcdefghijk", in: directory)
        let later = Date.now.addingTimeInterval(StreamCache.lifetime + 1)
        #expect(!StreamCache.isFresh("abcdefghijk", in: directory, now: later))
        StreamCache.removeStale(in: directory, now: later)
        #expect(!FileManager.default.fileExists(atPath: StreamCache.file(for: "abcdefghijk", in: directory).path))
    }

    /// The wrapper answers from the cache when it can and runs yt-dlp otherwise.
    @Test func wrapperReusesFreshAnswers() throws {
        let directory = try temporaryDirectory().appending(path: "it's here")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fake = directory.appending(path: "fake-yt-dlp")
        try "#!/bin/sh\necho \"ran: $*\"\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let wrapper = try StreamCache.wrapper(realYtDlp: fake, directory: directory)
        StreamCache.store(json: json("abcdefghijk"), videoId: "abcdefghijk", in: directory)

        func run(_ url: String) throws -> String {
            let process = Process()
            process.executableURL = wrapper
            process.arguments = ["--no-warnings", "-J", "--", url]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        #expect(try run("https://www.youtube.com/watch?v=abcdefghijk") == String(decoding: json("abcdefghijk"), as: UTF8.self))
        #expect(try run("https://www.youtube.com/watch?v=zzzzzzzzzzz")
                == "ran: --ignore-config --no-warnings -J -- https://www.youtube.com/watch?v=zzzzzzzzzzz\n")
    }
}
