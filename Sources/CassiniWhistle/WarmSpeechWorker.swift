// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Persistent single-child worker session supporting sequential JSON-line requests
/// (`follow`, `stopFollow`, `transcribeMeeting`, `shutdown`) with warm handoff and
/// immediate preemption/termination.
public final class WarmSpeechWorker: @unchecked Sendable {
    // Internal test seam: production waits on the same independent exit group;
    // tests can gate grace/escalation phases deterministically without wall-clock sleeps.
    struct WatchdogClock: Sendable {
        enum Phase: Sendable, Hashable { case eofGrace, shutdownGrace, escalation }
        var wait: @Sendable (Phase, DispatchGroup, TimeInterval) -> Bool
        static let live = WatchdogClock(wait: { _, exited, delay in
            exited.wait(timeout: .now() + delay) == .timedOut
        })
    }

    public enum Failure: Error {
        case timedOut
        case closed
        case writeFailed(Int32)
    }

    public struct Reply: Sendable {
        public let line: Data
        public let stderr: Data
        public let exited: Bool
        public let status: Int32
    }

    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let clock: WatchdogClock
    private let stateLock = NSLock()
    private let exitGroup = DispatchGroup()
    private let stderrGroup = DispatchGroup()
    private let stdoutReadGroup = DispatchGroup()
    private var stderrBuffer = Data()
    private var stdoutPending = Data()
    private var closed = false
    private var terminated = false
    private var stdinClosed = false
    private var escalationStarted = false
    private var pipesClosed = false

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isAlive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !closed && !terminated && process.isRunning
    }

    public convenience init(executable: URL, arguments: [String], environment: [String: String]) throws {
        try self.init(executable: executable, arguments: arguments, environment: environment, clock: .live)
    }

    init(executable: URL, arguments: [String], environment: [String: String], clock: WatchdogClock) throws {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        proc.environment = environment
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe
        self.clock = clock

        let exitGroup = self.exitGroup
        exitGroup.enter()
        proc.terminationHandler = { _ in exitGroup.leave() }
        do {
            try proc.run()
        } catch {
            proc.terminationHandler = nil
            exitGroup.leave()
            throw error
        }

        // Drain stderr continuously so the child can never block on a full stderr pipe.
        let stderrGroup = self.stderrGroup
        stderrGroup.enter()
        let errFD = errPipe.fileHandleForReading.fileDescriptor
        Thread.detachNewThread { [weak self] in
            defer { stderrGroup.leave() }
            var bytes = [UInt8](repeating: 0, count: 8192)
            var captured = Data()
            let cap = 262_144
            while true {
                let count = Darwin.read(errFD, &bytes, bytes.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if count == 0 { break }
                if captured.count < cap {
                    captured.append(contentsOf: bytes.prefix(min(count, cap - captured.count)))
                }
            }
            if let self {
                self.stateLock.lock()
                self.stderrBuffer = captured
                self.stateLock.unlock()
            }
        }
    }

    deinit {
        terminateImmediately()
    }

    /// Sends one JSON-line request and awaits one JSON-line reply.
    /// Cancelling the enclosing Swift Task signals termination without blocking the
    /// caller's thread, then awaits process exit and pipe cleanup off-thread.
    public func send(_ requestJSON: Data, timeout: TimeInterval = 24 * 60 * 60) async throws -> Reply {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Thread.detachNewThread {
                    do {
                        let reply = try self.blockingSend(requestJSON, timeout: timeout)
                        continuation.resume(returning: reply)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.requestTermination()
        }
    }

    private func blockingSend(_ requestJSON: Data, timeout: TimeInterval) throws -> Reply {
        stateLock.lock()
        let wasTerminatedBeforeStart = terminated
        let isClosed = closed
        stateLock.unlock()
        if wasTerminatedBeforeStart {
            finishTeardownBlocking()
            throw CancellationError()
        }
        if isClosed { throw Failure.closed }

        var payload = requestJSON
        if payload.last != 10 { payload.append(10) }

        var writeError: Int32?
        do {
            try WhistleIO.write(payload, to: stdinPipe.fileHandleForWriting.fileDescriptor)
        } catch WhistleIO.Failure.system(_, let code) {
            writeError = code
        } catch {
            writeError = EIO
        }

        let line: Data?
        do {
            line = try readLine(timeout: timeout)
        } catch is CancellationError {
            finishTeardownBlocking()
            throw CancellationError()
        } catch Failure.timedOut {
            terminateImmediately()
            throw Failure.timedOut
        }

        stateLock.lock()
        let wasTerminatedAfterRead = terminated
        stateLock.unlock()
        if wasTerminatedAfterRead {
            finishTeardownBlocking()
            throw CancellationError()
        }

        if let line {
            let running = process.isRunning
            if !running {
                finishTeardownBlocking()
            }
            stateLock.lock()
            let wasTerminated = terminated
            let err = stderrBuffer
            stateLock.unlock()

            if wasTerminated {
                finishTeardownBlocking()
                throw CancellationError()
            }
            return Reply(
                line: line,
                stderr: err,
                exited: !running,
                status: running ? 0 : process.terminationStatus
            )
        }

        if let writeError {
            throw Failure.writeFailed(writeError)
        }

        // EOF on stdout can arrive before Foundation observes process termination,
        // or if the child closed stdout while remaining alive. Never read
        // `terminationStatus` until exit is confirmed off-thread.
        awaitExitAfterEOF()
        stateLock.lock()
        let wasTerminatedAfterEOF = terminated
        let err = stderrBuffer
        stateLock.unlock()
        if wasTerminatedAfterEOF { throw CancellationError() }
        return Reply(line: Data(), stderr: err, exited: true, status: process.terminationStatus)
    }

    private func readLine(timeout: TimeInterval) throws -> Data? {
        stdoutReadGroup.enter()
        defer { stdoutReadGroup.leave() }

        let fd = stdoutPipe.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        let maxLineBytes = 4_194_304
        var buffer = [UInt8](repeating: 0, count: 16384)

        while true {
            if let newlineIndex = stdoutPending.firstIndex(of: 10) {
                let line = Data(stdoutPending[..<newlineIndex])
                stdoutPending.removeSubrange(...newlineIndex)
                return line
            }
            stateLock.lock()
            let wasTerminated = terminated
            stateLock.unlock()
            if wasTerminated { throw CancellationError() }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw Failure.timedOut
            }
            let pollMs = Int32(min(100, max(1, Int(remaining * 1000))))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&pfd, 1, pollMs)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if ready == 0 { continue }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 {
                if !stdoutPending.isEmpty {
                    let line = stdoutPending
                    stdoutPending.removeAll()
                    return line
                }
                return nil
            }
            let allowed = max(0, maxLineBytes - stdoutPending.count)
            if allowed > 0 {
                stdoutPending.append(contentsOf: buffer.prefix(min(count, allowed)))
            }
        }
    }

    /// Signals termination without waiting for process exit or pipe drains.
    /// Safe to invoke synchronously from task cancellation handlers on the main actor.
    private func requestTermination() {
        stateLock.lock()
        closed = true
        terminated = true
        let closeIn = !stdinClosed
        stdinClosed = true
        let startEscalation = !escalationStarted
        escalationStarted = true
        stateLock.unlock()

        if closeIn {
            try? stdinPipe.fileHandleForWriting.close()
        }
        if startEscalation {
            if process.isRunning {
                process.terminate()
            }
            let proc = self.process
            let exitGroup = self.exitGroup
            let clock = self.clock
            Thread.detachNewThread {
                if clock.wait(.escalation, exitGroup, 0.3), proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }
    }

    private func awaitExitAfterEOF() {
        stateLock.lock()
        closed = true
        let closeIn = !stdinClosed
        stdinClosed = true
        stateLock.unlock()

        if closeIn {
            try? stdinPipe.fileHandleForWriting.close()
        }
        if process.isRunning {
            if clock.wait(.eofGrace, exitGroup, 2.0), process.isRunning {
                stateLock.lock()
                let shouldEscalate = !escalationStarted
                escalationStarted = true
                stateLock.unlock()
                if shouldEscalate {
                    process.terminate()
                    if clock.wait(.escalation, exitGroup, 0.3), process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
        finishTeardownBlocking()
    }

    private func finishTeardownBlocking() {
        process.waitUntilExit()
        stderrGroup.wait()
        stdoutReadGroup.wait()
        stateLock.lock()
        closed = true
        let closeIn = !stdinClosed
        stdinClosed = true
        let closePipes = !pipesClosed
        pipesClosed = true
        stateLock.unlock()

        if closeIn {
            try? stdinPipe.fileHandleForWriting.close()
        }
        if closePipes {
            process.terminationHandler = nil
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }
    }

    /// Cleanly closes stdin so the worker finishes its loop and exits 0; escalates if it hangs.
    public func shutdown() {
        stateLock.lock()
        let alreadyClosed = closed
        closed = true
        let closeIn = !stdinClosed
        stdinClosed = true
        stateLock.unlock()

        if closeIn {
            try? stdinPipe.fileHandleForWriting.close()
        }
        if !alreadyClosed, process.isRunning {
            if clock.wait(.shutdownGrace, exitGroup, 2.0), process.isRunning {
                stateLock.lock()
                let shouldEscalate = !escalationStarted
                escalationStarted = true
                stateLock.unlock()
                if shouldEscalate {
                    process.terminate()
                    if clock.wait(.escalation, exitGroup, 0.3), process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
        finishTeardownBlocking()
    }

    /// Immediately preempts and terminates the child (`SIGTERM` -> 300 ms -> `SIGKILL`).
    public func terminateImmediately() {
        requestTermination()
        finishTeardownBlocking()
    }
}
