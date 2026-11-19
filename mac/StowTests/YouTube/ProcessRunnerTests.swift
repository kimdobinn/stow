import Foundation
import Testing
@testable import Stow

struct ProcessRunnerTests {
    @Test func capturesOutputAndPath() async throws {
        let output = try await ProcessRunner.run(URL(filePath: "/bin/sh"), arguments: ["-c", "echo 한글; echo $PATH; echo oops >&2"],
                                                 timeout: .seconds(10))
        let lines = String(decoding: output.stdout, as: UTF8.self).split(separator: "\n")
        #expect(output.exitCode == 0)
        #expect(lines.first == "한글")
        #expect(lines.last?.hasPrefix("/opt/homebrew/bin:") == true)
        #expect(output.stderr == "oops\n")
    }

    @Test func returnsNonZeroExit() async throws {
        let output = try await ProcessRunner.run(URL(filePath: "/bin/sh"), arguments: ["-c", "exit 3"], timeout: .seconds(10))
        #expect(output.exitCode == 3)
    }

    @Test func drainsLargeOutput() async throws {
        let output = try await ProcessRunner.run(URL(filePath: "/bin/sh"), arguments: ["-c", "head -c 1000000 /dev/zero"],
                                                 timeout: .seconds(10))
        #expect(output.stdout.count == 1_000_000)
    }

    @Test func timesOut() async {
        let start = ContinuousClock.now
        await #expect(throws: StowError.timedOut(tool: "sleep")) {
            try await ProcessRunner.run(URL(filePath: "/bin/sleep"), arguments: ["10"], timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func cancellationTerminates() async {
        let start = ContinuousClock.now
        let task = Task { try await ProcessRunner.run(URL(filePath: "/bin/sleep"), arguments: ["10"], timeout: .seconds(30)) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func unlaunchableExecutableThrows() async {
        await #expect(throws: StowError.self) {
            try await ProcessRunner.run(URL(filePath: "/nonexistent/tool"), arguments: [], timeout: .seconds(1))
        }
    }
}
