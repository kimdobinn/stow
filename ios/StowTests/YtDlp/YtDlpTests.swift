import AVFoundation
import Foundation
import Testing
@testable import Stow

/// Offline: the embedded interpreter, the Swift <-> Python plumbing, parsing and the AVFoundation
/// merge. The real-YouTube checks are the app's -ytdlp-selftest.
@Suite struct PythonRuntimeTests {
    let runtime = PythonRuntime.shared

    @Test func answersAPing() async throws {
        let data = try await runtime.call(["op": "ping", "echo": "héllo"])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["echo"] as? String == "héllo")
        #expect((object["thread"] as? String)?.hasPrefix("stow-call-") == true)
    }

    @Test func loadsYtDlp() async throws {
        let version = try await YtDlp.shared.version()
        #expect(version.ytDlp == "2026.11.23")
        #expect(version.python.hasPrefix("3.14"))
        #expect(version.openSSL.contains("OpenSSL"))
    }

    @Test func reportsErrorsShortly() async throws {
        await #expect(throws: YtDlpError.failed("Video unavailable")) {
            _ = try await runtime.call(["op": "ping", "fail": "Video unavailable"])
        }
    }

    @Test func unknownRequestFails() async throws {
        await #expect(throws: YtDlpError.self) {
            _ = try await runtime.call(["op": "nonsense"])
        }
    }

    @Test func cancelsARunningCall() async throws {
        let runtime = runtime
        let task = Task { try await runtime.call(["op": "ping", "sleep": 10]) }
        try await Task.sleep(for: .milliseconds(300))
        let clock = ContinuousClock()
        let began = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(clock.now - began < .seconds(2))
    }

    @Test func runsCallsAtTheSameTime() async throws {
        let runtime = runtime
        let clock = ContinuousClock()
        let began = clock.now
        async let first = runtime.call(["op": "ping", "sleep": 1])
        async let second = runtime.call(["op": "ping", "sleep": 1])
        async let third = runtime.call(["op": "ping", "sleep": 1])
        _ = try await (first, second, third)
        #expect(clock.now - began < .seconds(2.5))
    }

    @Test func deliversProgress() async throws {
        let seen = Box()
        _ = try await runtime.call(["op": "ping", "progress": true]) { data in
            seen.set(YtDlp.parseProgress(data))
        }
        let progress = try #require(seen.value)
        #expect(progress.downloadedBytes == 1)
        #expect(progress.totalBytes == 2)
        #expect(progress.percent == 50)
    }

    nonisolated final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: YtDlpProgress?
        func set(_ value: YtDlpProgress?) { lock.withLock { stored = value } }
        var value: YtDlpProgress? { lock.withLock { stored } }
    }
}

@Suite struct JavaScriptRunnerTests {
    @Test func returnsConsoleLog() throws {
        let result = JavaScriptRunner.run("console.warn('noise'); console.log(JSON.stringify({a: [1, 2].map(x => x * 2)}));")
        #expect(try result.get() == #"{"a":[2,4]}"#)
    }

    @Test func reportsExceptions() {
        let result = JavaScriptRunner.run("throw new Error('nope')")
        guard case .failure(let failure) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure.message.contains("nope"))
    }
}

@Suite struct ParsingTests {
    @Test func parsesAStream() throws {
        let json = #"""
        {"id":"abc","hls":"https://manifest.googlevideo.com/api/manifest/hls_variant/expire/1764300000/ei/x/file/index.m3u8",
         "video":"https://rr1.googlevideo.com/videoplayback?expire=1764290000&itag=137","video_height":1080,
         "audio":"https://rr1.googlevideo.com/videoplayback?expire=1764290000&itag=140","progressive":null,
         "progressive_height":null,"headers":{"User-Agent":"x"},"duration":635,"is_live":false}
        """#
        let stream = try YtDlp.parseStream(Data(json.utf8), videoID: "abc")
        #expect(stream.hlsURL?.host() == "manifest.googlevideo.com")
        #expect(stream.videoHeight == 1080)
        #expect(stream.progressiveURL == nil)
        #expect(stream.headers == ["User-Agent": "x"])
        #expect(stream.duration == 635)
        #expect(stream.expiresAt == Date(timeIntervalSince1970: 1_764_290_000))
    }

    @Test func readsExpiryFromHLSPaths() throws {
        let url = try #require(URL(string: "https://manifest.googlevideo.com/api/manifest/hls_variant/expire/1764300000/ei/x"))
        #expect(YtDlp.expiry(of: url) == Date(timeIntervalSince1970: 1_764_300_000))
    }

    @Test func decodesAPlan() throws {
        let json = #"""
        {"id":"abc","title":"T","duration":18,"max_height":480,"estimated_bytes":641342,
         "parts":[{"format_id":"135","ext":"mp4","has_video":true,"has_audio":false,"height":480,"width":854,
                   "fps":30,"vcodec":"avc1.4d401f","acodec":"none","bytes":332054},
                  {"format_id":"140","ext":"m4a","has_video":false,"has_audio":true,"height":null,"width":null,
                   "fps":null,"vcodec":"none","acodec":"mp4a.40.2","bytes":309288}]}
        """#
        let plan = try JSONDecoder().decode(YtDlpDownloadPlan.self, from: Data(json.utf8))
        #expect(plan.height == 480)
        #expect(plan.parts.map(\.formatID) == ["135", "140"])
        #expect(plan.estimatedBytes == 641_342)
    }

    @Test func progressWithoutTotalHasNoFraction() {
        let progress = YtDlp.parseProgress(Data(#"{"downloaded":10,"total":null}"#.utf8))
        #expect(progress?.fraction == nil)
        #expect(YtDlpProgress(phase: .merging, downloadedBytes: 1, totalBytes: nil).fraction == 1)
    }
}

@Suite struct MediaMergerTests {
    @Test func mergesVideoAndAudio() async throws {
        let folder = URL.temporaryDirectory.appending(path: "merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appending(path: "video.mp4")
        let audio = folder.appending(path: "audio.m4a")
        do { try await TestMedia.writeVideo(to: video, seconds: 2) } catch { Issue.record("writing video: \(error)"); throw error }
        do { try await TestMedia.writeAudio(to: audio, seconds: 2) } catch { Issue.record("writing audio: \(error)"); throw error }

        let output = folder.appending(path: "merged.mp4")
        try await MediaMerger.merge(video: video, audio: audio, to: output)
        let tracks = try await MediaMerger.trackCounts(of: output)
        #expect(tracks.video == 1)
        #expect(tracks.audio == 1)
        #expect(abs(tracks.duration - 2) < 0.2)
    }
}

/// Small H.264 and AAC files, made with AVAssetWriter.
nonisolated enum TestMedia {
    static func writeVideo(to url: URL, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let fps = 10
        for frame in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 10 % 255), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    static func writeAudio(to url: URL, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let rate = 44_100
        let chunk = 4_410
        var format = AudioStreamBasicDescription(
            mSampleRate: Float64(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16,
            mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        for start in stride(from: 0, to: seconds * rate, by: chunk) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var samples = (0..<chunk).map { Int16(sin(Double(start + $0) * 2 * .pi * 440 / Double(rate)) * 8_000) }
            var block: CMBlockBuffer?
            let bytes = chunk * 2
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
            }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block!, formatDescription: description!, sampleCount: chunk,
                presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
                packetDescriptions: nil, sampleBufferOut: &sample)
            input.append(sample!)
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}

@Suite struct MP4HeaderTests {
    private func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let size = UInt32(8 + body.count)
        return withUnsafeBytes(of: size.bigEndian, Array.init) + Array(type.utf8) + body
    }

    private func be32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }

    private func write(_ bytes: [UInt8]) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "header-\(UUID().uuidString).mp4")
        try Data(bytes).write(to: url)
        return url
    }

    @Test func readsTheMovieHeader() throws {
        // mvhd v0: version+flags, creation, modification, timescale 12800, duration 212480 (16.6 s)
        let mvhd = box("mvhd", [0, 0, 0, 0] + be32(0) + be32(0) + be32(12_800) + be32(212_480) + Array(repeating: 0, count: 80))
        let file = try write(box("ftyp", Array("dash".utf8) + be32(0)) + box("moov", mvhd) + box("mdat", [1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(MP4Header.duration(of: file)?.seconds == 16.6)
    }

    @Test func fallsBackToTheSegmentIndex() throws {
        let mvhd = box("mvhd", [0, 0, 0, 0] + be32(0) + be32(0) + be32(1_000) + be32(0) + Array(repeating: 0, count: 80))
        // sidx v0: version+flags, reference id, timescale 1000, earliest time, first offset, reserved, count 2, references
        let reference: (UInt32) -> [UInt8] = { duration in self.be32(100) + self.be32(duration) + self.be32(0x9000_0000) }
        let sidx = box("sidx", [0, 0, 0, 0] + be32(1) + be32(1_000) + be32(0) + be32(0) + [0, 0, 0, 2] + reference(1_500) + reference(2_500))
        let file = try write(box("moov", mvhd) + sidx + box("moof", [0]))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(MP4Header.duration(of: file)?.seconds == 4)
    }
}
