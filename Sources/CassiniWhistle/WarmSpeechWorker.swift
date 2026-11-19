// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Persistent single-child worker session supporting sequential JSON-line requests
/// (`follow`, `stopFollow`, `transcribeMeeting`, `shutdown`) with warm handoff and
/// immediate preemption/termination.
public final class WarmSpeechWorker: @unchecked Sendable {
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
    private let stateLock = NSLock()
    private let exitedSemaphore = DispatchSemaphore(value: 0)
    private let stderrGroup = DispatchGroup()
    private var stderrBuffer = Data()
    private var stdoutPending = Data()
    private var closed = false
    private var terminated = false
    private var stdinClosed = false

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isAlive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !closed && !terminated && process.isRunning
    }

    public init(executable: URL, arguments: [String], environment: [String: String]) throws {
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

        let exited = self.exitedSemaphore
        proc.terminationHandler = { _ in exited.signal() }
        try proc.run()

        // Drain stderr continuously so the child can never block on a full stderr pipe.
        stderrGroup.enter()
        let errFD = errPipe.fileHandleForReading.fileDescriptor
        Thread.detachNewThread { [weak self] in
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
                self.stderrGroup.leave()
            }
        }
    }

    deinit {
        terminateImmediately()
    }

    /// Sends one JSON-line request and awaits one JSON-line reply.
    /// Cancelling the enclosing Swift Task immediately terminates the child process.
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
            self.terminateImmediately()
        }
    }

    private func blockingSend(_ requestJSON: Data, timeout: TimeInterval) throws -> Reply {
        stateLock.lock()
        let wasTerminatedBeforeStart = terminated
        let isClosed = closed
        stateLock.unlock()
        if wasTerminatedBeforeStart { throw CancellationError() }
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

        let line = try readLine(timeout: timeout)
        let running = process.isRunning
        if !running {
            process.waitUntilExit()
            stderrGroup.wait()
        }
        stateLock.lock()
        let wasTerminated = terminated
        let err = stderrBuffer
        stateLock.unlock()

        if wasTerminated { throw CancellationError() }
        if let line {
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
        return Reply(line: Data(), stderr: err, exited: true, status: process.terminationStatus)
    }

    private func readLine(timeout: TimeInterval) throws -> Data? {
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
                terminateImmediately()
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

    /// Cleanly closes stdin so the worker finishes its loop and exits 0; escalates if it hangs.
    public func shutdown() {
        stateLock.lock()
        if closed { stateLock.unlock(); return }
        closed = true
        let closeIn = !stdinClosed
        stdinClosed = true
        stateLock.unlock()

        if closeIn {
            try? stdinPipe.fileHandleForWriting.close()
        }
        if process.isRunning {
            if exitedSemaphore.wait(timeout: .now() + 2.0) == .timedOut, process.isRunning {
                process.terminate()
                if exitedSemaphore.wait(timeout: .now() + 0.3) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        process.waitUntilExit()
        process.terminationHandler = nil
        try? stdoutPipe.fileHandleForReading.close()
        stderrGroup.wait()
        try? stderrPipe.fileHandleForReading.close()
    }

    /// Immediately preempts and terminates the child (`SIGTERM` -> 300 ms -> `SIGKILL`).
    public func terminateImmediately() {
        stateLock.lock()
        let alreadyClosed = closed && terminated
        closed = true
        terminated = true
        let closeIn = !stdinClosed
        stdinClosed = true
        stateLock.unlock()
        if alreadyClosed { return }

        if closeIn {
            try? stdinPipe.fileHandleForWriting.close()
        }
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            if exitedSemaphore.wait(timeout: .now() + 0.3) == .timedOut, process.isRunning {
                kill(pid, SIGKILL)
            }
        }
        process.waitUntilExit()
        process.terminationHandler = nil
        try? stdoutPipe.fileHandleForReading.close()
        stderrGroup.wait()
        try? stderrPipe.fileHandleForReading.close()
    }
}
