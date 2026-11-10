// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import Testing
import XCTest
@testable import CassiniWhistle

private final class ManualWatchdog: @unchecked Sendable {
    typealias Phase = WhistleSubprocess.WatchdogClock.Phase
    let timeoutArmed = XCTestExpectation(description:"Watchdog armed")
    let escalationArmed = XCTestExpectation(description:"Escalation armed after TERM")
    let exitObserved = XCTestExpectation(description:"Actual child exit observed")
    let inputQueued = XCTestExpectation(description:"Actual input bytes queued without a child read")
    private let condition = NSCondition()
    private var fired: Set<Phase> = []
    private var closed = false
    private var status: Int32?
    private var delays: [Phase: TimeInterval] = [:]
    private var inputObserver: DispatchSourceRead?
    private var observedInput = false
    init() {
        timeoutArmed.assertForOverFulfill = false
        escalationArmed.assertForOverFulfill = false
    }
    var clock: WhistleSubprocess.WatchdogClock {
        .init(wait:{ [self] phase,_,delay in
            condition.lock(); defer { condition.unlock() }
            delays[phase] = delay
            switch phase {
            case .timeout: timeoutArmed.fulfill()
            case .escalation: escalationArmed.fulfill()
            }
            while !closed && !fired.contains(phase) { condition.wait() }
            // Failure cleanup must still kill a child that ignores TERM.
            return !closed || phase == .escalation
        },didExit:{ [self] value in
            condition.lock(); status = value; condition.unlock()
            exitObserved.fulfill()
        },inputPipeCreated:{ [self] fd in
            let copy = dup(fd)
            guard copy >= 0 else { Issue.record("Cannot observe input pipe"); return }
            guard fcntl(copy,F_SETFD,FD_CLOEXEC) == 0 else { Darwin.close(copy); Issue.record("Cannot protect observer FD"); return }
            let source = DispatchSource.makeReadSource(fileDescriptor:copy,queue:.global())
            source.setEventHandler { [weak self] in
                guard let self else { return }
                condition.lock(); defer { condition.unlock() }
                if let observer = inputObserver, observer.data > 0 { observedInput = true; observer.cancel() }
            }
            source.setCancelHandler { [weak self] in
                Darwin.close(copy) // Drop the extra reader BEFORE permitting child death.
                guard let self else { return }
                condition.lock(); let queued = observedInput; condition.unlock()
                if queued { inputQueued.fulfill() }
            }
            condition.lock(); inputObserver = source; condition.unlock()
            source.resume()
        })
    }
    var exitStatus: Int32? { condition.lock(); defer { condition.unlock() }; return status }
    var registeredDelays: [Phase: TimeInterval] { condition.lock(); defer { condition.unlock() }; return delays }
    func fire(_ phase: Phase) {
        condition.lock(); fired.insert(phase); condition.broadcast(); condition.unlock()
    }
    func close() {
        condition.lock(); closed = true; let observer = inputObserver; condition.broadcast(); condition.unlock()
        observer?.cancel()
    }
}

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
        try await proveWatchdogTermination(input:Data())
    }
    @Test func timeoutAlsoUnblocksAWriterWhenTheChildNeverReadsInput() async throws {
        try await proveWatchdogTermination(input:Data(repeating:1,count:1_048_576))
    }
    private func proveWatchdogTermination(input: Data) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:root) }
        let ready = root.appendingPathComponent("ready"), blocked = root.appendingPathComponent("blocked")
        try #require(mkfifo(ready.path,0o600) == 0 && mkfifo(blocked.path,0o600) == 0)
        let fd = open(ready.path,O_RDWR | O_NONBLOCK | O_CLOEXEC)
        try #require(fd >= 0); defer { close(fd) }
        let watchdog = ManualWatchdog()
        let task = Task {
            try await WhistleSubprocess.run(executable:URL(fileURLWithPath:"/bin/sh"),
                arguments:["-c","trap '' TERM; printf 1 > \"$1\"; exec 3<\"$2\"","cassini-watchdog",ready.path,blocked.path],
                environment:["PATH":"/usr/bin:/bin"],input:input,clock:watchdog.clock)
        }
        defer { task.cancel(); watchdog.close() }
        // The child has installed SIGTERM-ignore and never reads stdin. Neither
        // interpreter startup nor a fixed delay can satisfy this handshake.
        try await Task.detached {
            var event = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
            try #require(poll(&event,1,10000) == 1)
            var byte: UInt8 = 0
            try #require(read(fd,&byte,1) == 1 && byte == 49)
        }.value
        try #require(await XCTWaiter.fulfillment(of:[watchdog.timeoutArmed],timeout:10) == .completed)
        if !input.isEmpty {
            // Observe real pipe readability without consuming any bytes. The
            // large production write has begun, so timeout cannot win startup.
            try #require(await XCTWaiter.fulfillment(of:[watchdog.inputQueued],timeout:10) == .completed)
        }
        watchdog.fire(.timeout)
        try #require(await XCTWaiter.fulfillment(of:[watchdog.escalationArmed],timeout:10) == .completed)
        watchdog.fire(.escalation)
        do { _ = try await task.value; Issue.record("Watchdog did not report its timeout") }
        catch WhistleSubprocess.Failure.timedOut { }
        try #require(await XCTWaiter.fulfillment(of:[watchdog.exitObserved],timeout:10) == .completed)
        #expect(watchdog.exitStatus == SIGKILL,"TERM-ignore requires the real escalation path")
        #expect(watchdog.registeredDelays == [.timeout:30,.escalation:0.3],"Production timer configuration stays intact")
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
        let blocked = root.appendingPathComponent("blocked")
        try #require(mkfifo(ready.path,0o600) == 0)
        try #require(mkfifo(blocked.path,0o600) == 0)
        let fd = open(ready.path,O_RDWR | O_NONBLOCK | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        let task = Task {
            // The shell reports readiness then blocks opening a separate FIFO.
            // No interpreter initialization or fixed sleep enters cancellation.
            try await WhistleSubprocess.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 1 > \"$1\"; exec 3<\"$2\"", "cassini-cancel", ready.path, blocked.path],
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
