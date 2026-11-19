// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
@testable import CassiniWhistle

/// Event-driven lifecycle tests for `WarmSpeechWorker` (sequential JSON-line requests,
/// single-PID warm handoff, immediate preemption/cancellation, and error-on-exit handling).
final class WarmSpeechWorkerTests: XCTestCase {
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

    func testTaskCancellationTerminatesWarmWorkerImmediately() async throws {
        // Worker emits a readiness signal on first request, then blocks on second request until terminated.
        let script = """
        import json, sys, time
        first = sys.stdin.readline()
        req = json.loads(first)
        sys.stdout.write(json.dumps({"id": req["id"], "ready": True}) + "\\n")
        sys.stdout.flush()
        _ = sys.stdin.readline()
        time.sleep(60)
        """
        let worker = try WarmSpeechWorker(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", script],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        let readyReply = try await worker.send(Data("{\"id\":\"ready\"}\n".utf8), timeout: 10)
        XCTAssertFalse(readyReply.exited)

        let task = Task {
            try await worker.send(Data("{\"id\":\"blocked\"}\n".utf8), timeout: 60)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // Expected
        }
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
