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
    // Native byte producers keep pipe-pressure coverage independent of the Apple
    // /usr/bin/python3 shim, which starts xcodebuild per child on hosted Intel.
    @Test func concurrentStderrDrainCannotBlockStdout() async throws {
        let result = try await WhistleSubprocess.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/usr/bin/head -c 800000 /dev/zero | /usr/bin/tr '\\000' e >&2; printf done"],
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
    @Test func timeoutAlsoUnblocksAWriterWhenTheChildNeverReadsInput() async {
        await #expect(throws: WhistleSubprocess.Failure.self) {
            try await WhistleSubprocess.run(executable:URL(fileURLWithPath:"/usr/bin/python3"),
                arguments:["-c","import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)"],
                environment:["PATH":"/usr/bin:/bin"],input:Data(repeating:1,count:1_048_576),timeout:0.2)
        }
    }
    @Test func concurrentDuplexProcessesDoNotDependOnSharedPoolDrains() async throws {
        try await withThrowingTaskGroup(of:Void.self) { tasks in
            for _ in 0..<8 {
                tasks.addTask {
                    let result = try await WhistleSubprocess.run(executable:URL(fileURLWithPath:"/bin/sh"),
                        arguments:["-c","/usr/bin/head -c 800000 /dev/zero | /usr/bin/tr '\\000' e >&2; n=$(/usr/bin/wc -c); printf '%s\\n' \"$((n))\""],
                        environment:["PATH":"/usr/bin:/bin"],input:Data(repeating:1,count:1_048_576),timeout:10)
                    #expect(result.status == 0 && result.inputError == nil)
                    #expect(result.stdout == Data("1048576\n".utf8)); #expect(result.stderr.count == 262144)
                }
            }
            try await tasks.waitForAll()
        }
    }
    @Test func cancellationStopsTheChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:root) }
        let ready = root.appendingPathComponent("ready")
        try #require(mkfifo(ready.path,0o600) == 0)
        let fd = open(ready.path,O_RDWR | O_NONBLOCK | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        let task = Task {
            try await WhistleSubprocess.run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", "import signal,sys\nwith open(sys.argv[1],'wb',buffering=0) as ready: ready.write(b'1')\nsignal.pause()",ready.path],
                environment: ["PATH": "/usr/bin:/bin"], input: Data())
        }
        defer { task.cancel() }
        // A real child handshake makes cancellation exercise the running child,
        // independently of process startup speed. Five seconds is only a bound.
        try await Task.detached {
            var event = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
            try #require(poll(&event,1,5000) == 1)
            var byte: UInt8 = 0
            try #require(read(fd,&byte,1) == 1 && byte == 49)
        }.value
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
