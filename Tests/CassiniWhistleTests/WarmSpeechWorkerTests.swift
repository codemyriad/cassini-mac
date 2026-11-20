// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import Darwin
@testable import CassiniWhistle

private final class ManualWarmWatchdog: @unchecked Sendable {
    typealias Phase = WarmSpeechWorker.WatchdogClock.Phase

    let eofGraceArmed = XCTestExpectation(description: "EOF grace wait armed")
    let shutdownGraceArmed = XCTestExpectation(description: "Shutdown grace wait armed")
    let escalationArmed = XCTestExpectation(description: "Escalation wait armed")

    private let condition = NSCondition()
    private var fired: Set<Phase> = []
    private var closed = false
    private var delays: [Phase: TimeInterval] = [:]

    init() {
        eofGraceArmed.assertForOverFulfill = false
        shutdownGraceArmed.assertForOverFulfill = false
        escalationArmed.assertForOverFulfill = false
    }

    var clock: WarmSpeechWorker.WatchdogClock {
        .init(wait: { [self] phase, exited, delay in
            condition.lock()
            delays[phase] = delay
            switch phase {
            case .eofGrace: eofGraceArmed.fulfill()
            case .shutdownGrace: shutdownGraceArmed.fulfill()
            case .escalation: escalationArmed.fulfill()
            }
            while !closed && !fired.contains(phase) {
                // If the process exits naturally while we are waiting on a grace phase,
                // report non-timeout immediately (matching DispatchGroup.wait semantics).
                if exited.wait(timeout: .now()) == .success {
                    condition.unlock()
                    return false
                }
                condition.wait(until: Date().addingTimeInterval(0.01))
            }
            let timedOut = fired.contains(phase) || (closed && phase == .escalation)
            condition.unlock()
            return timedOut
        })
    }

    var registeredDelays: [Phase: TimeInterval] {
        condition.lock()
        defer { condition.unlock() }
        return delays
    }

    func fire(_ phase: Phase) {
        condition.lock()
        fired.insert(phase)
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Event-driven lifecycle tests for `WarmSpeechWorker` (sequential JSON-line requests,
/// single-PID warm handoff, non-blocking main-actor cancellation, stdout-EOF-while-alive
/// handling, and error-on-exit handling).
final class WarmSpeechWorkerTests: XCTestCase {
    private func waitForFIFOByte(fd: Int32, expected: UInt8 = 49, timeoutMs: Int32 = 10_000) async throws {
        try await Task.detached {
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, timeoutMs)
            guard ready == 1 else {
                throw NSError(domain: "WarmSpeechWorkerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for child FIFO handshake (poll=\(ready))"])
            }
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            guard count == 1, byte == expected else {
                throw NSError(domain: "WarmSpeechWorkerTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unexpected FIFO byte \(byte) (count=\(count))"])
            }
        }.value
    }

    func testSequentialRequestsReuseSingleWarmChildProcessAndShutdownCleanly() async throws {
        // Lightweight Python echo worker simulating `follow` -> `stopFollow` -> `transcribeMeeting` -> `shutdown`.
        let script = """
        import json, os, sys
        pid = os.getpid()
        for raw in sys.stdin:
            req = json.loads(raw)
            action = req.get("action")
            sys.stdout.write(json.dumps({"id": req["id"], "action": action, "pid": pid}) + "\\n")
            sys.stdout.flush()
            if action == "shutdown":
                break
        """
        let worker = try WarmSpeechWorker(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", script],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        let expectedPID = worker.processIdentifier
        XCTAssertTrue(worker.isAlive)

        struct Req: Encodable { let id: String; let action: String }
        struct Rep: Decodable { let id: String; let action: String; let pid: Int32 }

        for action in ["follow", "stopFollow", "transcribeMeeting"] {
            let payload = try JSONEncoder().encode(Req(id: "req-\(action)", action: action))
            let reply = try await worker.send(payload, timeout: 10)
            XCTAssertFalse(reply.exited)
            let decoded = try JSONDecoder().decode(Rep.self, from: reply.line)
            XCTAssertEqual(decoded.id, "req-\(action)")
            XCTAssertEqual(decoded.action, action)
            XCTAssertEqual(decoded.pid, expectedPID, "warm handoff must reuse the exact same child PID")
        }

        worker.shutdown()
        XCTAssertFalse(worker.isAlive)
    }

    func testMainActorCancellationSignalsWithoutBlockingAndAwaitsOffThreadCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let receivedFIFO = root.appendingPathComponent("received")
        let blockedFIFO = root.appendingPathComponent("blocked")
        XCTAssertEqual(mkfifo(receivedFIFO.path, 0o600), 0)
        XCTAssertEqual(mkfifo(blockedFIFO.path, 0o600), 0)
        let receivedFD = open(receivedFIFO.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(receivedFD, 0)
        defer { if receivedFD >= 0 { Darwin.close(receivedFD) } }

        let watchdog = ManualWarmWatchdog()
        defer { watchdog.close() }

        // Child ignores SIGTERM, replies to the first request, then acknowledges receipt
        // of the second in-flight request via `receivedFIFO` before blocking on `blockedFIFO`.
        let script = """
        trap '' TERM
        IFS= read -r first || exit 0
        printf '{"id":"ready","ready":true}\\n'
        IFS= read -r second || exit 0
        printf '1' > "$1"
        exec 3<"$2"
        """
        let worker = try WarmSpeechWorker(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "cassini-warm-cancel", receivedFIFO.path, blockedFIFO.path],
            environment: ["PATH": "/usr/bin:/bin"],
            clock: watchdog.clock
        )
        let readyReply = try await worker.send(Data("{\"id\":\"ready\"}\n".utf8), timeout: 10)
        XCTAssertFalse(readyReply.exited)

        let task = Task {
            try await worker.send(Data("{\"id\":\"blocked\"}\n".utf8), timeout: 60)
        }
        defer { task.cancel() }

        // Prove the child has received the blocked request before cancelling.
        try await waitForFIFOByte(fd: receivedFD)

        // Cancel from the MainActor while escalation is still gated. If cancellation
        // synchronously waited for the 300 ms escalation or `waitUntilExit()`, this
        // MainActor call would deadlock because `watchdog.fire(.escalation)` has not run.
        await MainActor.run {
            task.cancel()
        }

        let escalationResult = await XCTWaiter.fulfillment(of: [watchdog.escalationArmed], timeout: 10)
        XCTAssertEqual(escalationResult, .completed)
        XCTAssertEqual(watchdog.registeredDelays[.escalation], 0.3)

        // Release escalation so the child receives SIGKILL and off-thread cleanup completes.
        watchdog.fire(.escalation)

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // Expected
        }
        XCTAssertFalse(worker.isAlive)
    }

    func testChildClosingStdoutWhileAliveAwaitsBoundedExitWithoutCrashing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let closedFIFO = root.appendingPathComponent("closed")
        let blockedFIFO = root.appendingPathComponent("blocked")
        XCTAssertEqual(mkfifo(closedFIFO.path, 0o600), 0)
        XCTAssertEqual(mkfifo(blockedFIFO.path, 0o600), 0)
        let closedFD = open(closedFIFO.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(closedFD, 0)
        defer { if closedFD >= 0 { Darwin.close(closedFD) } }

        let watchdog = ManualWarmWatchdog()
        defer { watchdog.close() }

        // Child ignores SIGTERM, reads the request, closes stdout while remaining alive,
        // signals `closedFIFO`, and blocks on `blockedFIFO`.
        let script = """
        trap '' TERM
        IFS= read -r req || exit 0
        exec >&-
        printf '1' > "$1"
        exec 3<"$2"
        """
        let worker = try WarmSpeechWorker(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "cassini-warm-eof", closedFIFO.path, blockedFIFO.path],
            environment: ["PATH": "/usr/bin:/bin"],
            clock: watchdog.clock
        )

        let task = Task {
            try await worker.send(Data("{\"id\":\"eof\"}\n".utf8), timeout: 60)
        }
        defer { task.cancel() }

        try await waitForFIFOByte(fd: closedFD)

        let graceResult = await XCTWaiter.fulfillment(of: [watchdog.eofGraceArmed], timeout: 10)
        XCTAssertEqual(graceResult, .completed)
        watchdog.fire(.eofGrace)

        let escalationResult = await XCTWaiter.fulfillment(of: [watchdog.escalationArmed], timeout: 10)
        XCTAssertEqual(escalationResult, .completed)
        watchdog.fire(.escalation)

        let reply = try await task.value
        XCTAssertTrue(reply.exited)
        XCTAssertTrue(reply.line.isEmpty)
        XCTAssertEqual(reply.status, SIGKILL)
        XCTAssertFalse(worker.isAlive)
    }

    func testChildClosingStdoutThenExitingPreservesExitStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let closedFIFO = root.appendingPathComponent("closed")
        let releaseFIFO = root.appendingPathComponent("release")
        XCTAssertEqual(mkfifo(closedFIFO.path, 0o600), 0)
        XCTAssertEqual(mkfifo(releaseFIFO.path, 0o600), 0)
        let closedFD = open(closedFIFO.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        let releaseFD = open(releaseFIFO.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(closedFD, 0)
        XCTAssertGreaterThanOrEqual(releaseFD, 0)
        defer {
            if closedFD >= 0 { Darwin.close(closedFD) }
            if releaseFD >= 0 { Darwin.close(releaseFD) }
        }

        let watchdog = ManualWarmWatchdog()
        defer { watchdog.close() }

        // Child closes stdout while alive, waits for release byte, then exits with code 42.
        let script = """
        IFS= read -r req || exit 0
        exec >&-
        printf '1' > "$1"
        IFS= read -r go < "$2"
        exit 42
        """
        let worker = try WarmSpeechWorker(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "cassini-warm-eof-exit", closedFIFO.path, releaseFIFO.path],
            environment: ["PATH": "/usr/bin:/bin"],
            clock: watchdog.clock
        )

        let task = Task {
            try await worker.send(Data("{\"id\":\"eof-exit\"}\n".utf8), timeout: 60)
        }
        defer { task.cancel() }

        try await waitForFIFOByte(fd: closedFD)
        let graceResult = await XCTWaiter.fulfillment(of: [watchdog.eofGraceArmed], timeout: 10)
        XCTAssertEqual(graceResult, .completed)

        // Release the child so it exits cleanly with 42 during the grace window.
        let bytes: [UInt8] = [49, 10]
        _ = Darwin.write(releaseFD, bytes, bytes.count)

        let reply = try await task.value
        XCTAssertTrue(reply.exited)
        XCTAssertTrue(reply.line.isEmpty)
        XCTAssertEqual(reply.status, 42)
        XCTAssertFalse(worker.isAlive)
    }

    func testInvalidModelExitPreservesStructuredErrorReply() async throws {
        let script = """
        import json, sys
        sys.stdout.write(json.dumps({"id": None, "error": "corrupt", "code": "invalid-model"}) + "\\n")
        sys.stdout.flush()
        sys.exit(78)
        """
        let worker = try WarmSpeechWorker(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", script],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        let reply = try await worker.send(Data("{\"id\":\"1\",\"action\":\"follow\"}\n".utf8), timeout: 10)
        struct Rep: Decodable { let code: String? }
        let decoded = try JSONDecoder().decode(Rep.self, from: reply.line)
        XCTAssertEqual(decoded.code, "invalid-model")
        worker.terminateImmediately()
    }
}
