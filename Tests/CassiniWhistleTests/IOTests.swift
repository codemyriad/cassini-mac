// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import Testing
@testable import CassiniWhistle

@Suite struct WhistleIOTests {
    @Test func sequentialLinesSurviveBufferRemovalAndBatchBoundaries() throws {
        let pipe = Pipe()
        let expected = [String(repeating:"a",count:3000),"second",String(repeating:"b",count:3000)]
        try WhistleIO.write(Data((expected.joined(separator:"\n") + "\n").utf8),to:pipe.fileHandleForWriting.fileDescriptor)
        try pipe.fileHandleForWriting.close()
        let reader = WhistleLineReader(fd:pipe.fileHandleForReading.fileDescriptor)
        for line in expected { #expect(try reader.next() == Data(line.utf8)) }
        #expect(try reader.next() == nil)
    }
    @Test func rejectsFifoSymlinkAndOversizeBeforeReading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: WhistleIO.Failure.self) { try WhistleIO.readRegular(fifo, maximum: 10) }
        let file = root.appendingPathComponent("file"); try Data(repeating: 1, count: 11).write(to: file)
        #expect(throws: WhistleIO.Failure.self) { try WhistleIO.readRegular(file, maximum: 10) }
        #expect(try WhistleIO.readRegular(file, maximum: 11).count == 11)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: WhistleIO.Failure.self) { try WhistleIO.readRegular(link, maximum: 11) }
    }
    @Test func lineLimitIsEnforcedDuringRead() throws {
        let pipe = Pipe()
        try WhistleIO.write(Data("ok\n12345\n".utf8), to: pipe.fileHandleForWriting.fileDescriptor)
        try pipe.fileHandleForWriting.close()
        let reader = WhistleLineReader(fd: pipe.fileHandleForReading.fileDescriptor, maximum: 4)
        #expect(try reader.next() == Data("ok".utf8))
        #expect(throws: WhistleIO.Failure.self) { try reader.next() }
    }
    @Test func brokenPipeBecomesAnErrorWithoutASignal() throws {
        let pipe = Pipe(); try pipe.fileHandleForReading.close()
        do {
            try WhistleIO.write(Data("response".utf8), to: pipe.fileHandleForWriting.fileDescriptor)
            Issue.record("Broken pipe unexpectedly accepted output")
        } catch WhistleIO.Failure.system(_, let code) { #expect(code == EPIPE) }
    }
    @Test func concurrentStderrDrainCannotBlockStdout() async throws {
        let result = try await WhistleSubprocess.run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import sys; sys.stderr.buffer.write(b'e'*800000); sys.stderr.flush(); sys.stdout.write('done'); sys.stdout.flush()"],
            environment: ["PATH": "/usr/bin:/bin"], input: Data(), timeout: 10)
        #expect(result.status == 0 && result.inputError == nil)
        #expect(result.stdout == Data("done".utf8))
        #expect(result.stderr.count == 262144)
    }
    @Test func childExitBeforeInputDoesNotCrashParent() async throws {
        let result = try await WhistleSubprocess.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
            environment: [:], input: Data(repeating: 1, count: 1_048_576), timeout: 10)
        #expect(result.status == 0 && result.inputError == EPIPE)
    }
    @Test func watchdogKillsAnUnresponsiveChild() async throws {
        await #expect(throws: WhistleSubprocess.Failure.self) {
            try await WhistleSubprocess.run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)"],
                environment: ["PATH": "/usr/bin:/bin"], input: Data(), timeout: 0.2)
        }
    }
    @Test func cancellationStopsTheChild() async throws {
        let task = Task {
            try await WhistleSubprocess.run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", "import time; time.sleep(60)"], environment: ["PATH": "/usr/bin:/bin"], input: Data())
        }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
