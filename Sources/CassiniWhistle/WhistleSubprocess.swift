// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Finite exchange used by the packaging probe. All blocking pipe/process work
/// runs off the main actor, with concurrent stderr draining and an independent
/// watchdog. The runtime queue can reuse the same descriptor primitives later.
public enum WhistleSubprocess {
    // Internal test seam: production waits on the same independent semaphores;
    // tests can fire watchdog boundaries after the child acknowledges readiness.
    struct WatchdogClock: Sendable {
        enum Phase: Sendable, Hashable { case timeout, escalation }
        var wait: @Sendable (Phase, DispatchSemaphore, TimeInterval) -> Bool
        var didExit: @Sendable (Int32) -> Void = { _ in }
        var inputPipeCreated: @Sendable (Int32) -> Void = { _ in }
        static let live = WatchdogClock(wait: { _, event, delay in
            event.wait(timeout:.now()+delay) == .timedOut
        })
    }
    public enum Failure: Error { case timedOut }
    public struct Output: Sendable {
        public let stdout: Data
        public let stderr: Data
        public let status: Int32
        public let inputError: Int32?
    }
    private final class Control: @unchecked Sendable {
        let clock: WatchdogClock
        init(clock: WatchdogClock) { self.clock = clock }
        let lock = NSLock()
        let exited = DispatchSemaphore(value:0)
        private var process: Process?
        private(set) var cancelled = false
        private(set) var timedOut = false
        func attach(_ process: Process) {
            lock.lock(); self.process = process; let stop = cancelled || timedOut; lock.unlock()
            if stop { terminate(process) }
        }
        func stop(timeout: Bool) {
            lock.lock(); timedOut = timedOut || timeout; cancelled = cancelled || !timeout
            let process = process; lock.unlock()
            if let process { terminate(process) }
        }
        private func terminate(_ process: Process) {
            if process.isRunning { process.terminate() }
            // Escalation must remain runnable even when the shared dispatch
            // worker pool is occupied by other blocking process/pipe work.
            Thread.detachNewThread { [exited, clock] in
                if clock.wait(.escalation,exited,0.3), process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        func outcome() -> (cancelled: Bool, timedOut: Bool) {
            lock.lock(); defer { lock.unlock() }; return (cancelled, timedOut)
        }
    }
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data(), stderr = Data()
        func put(_ data: Data, error: Bool) { lock.lock(); defer { lock.unlock() }; if error { stderr = data } else { stdout = data } }
        func result() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (stdout, stderr) }
    }
    public static func run(executable: URL, arguments: [String], environment: [String: String], input: Data, timeout: TimeInterval = 30) async throws -> Output {
        try await run(executable:executable,arguments:arguments,environment:environment,input:input,timeout:timeout,clock:.live)
    }
    /// Persistent worker for the opt-in realtime path. Pipe operations are serialized
    /// off the UI actor. A cancellation or deadline terminates only this process.
    public final class WindowSession: @unchecked Sendable {
        public enum RequestFailure: Error { case rejected, invalidResponse }
        private struct Transport {
            let process: Process
            let input: FileHandle
            let output: FileHandle
            let reader: WhistleLineReader
        }

        private let executable: URL
        private let arguments: [String]
        private let environment: [String: String]
        private let io = DispatchQueue(label: "Cassini live worker pipes", qos: .userInitiated)
        private let control = Control(clock: .live)
        // Only the IO queue accesses the transport and counter.
        private var transport: Transport?
        private var counter: UInt64 = 0

        public init(executable: URL, arguments: [String], environment: [String: String]) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
        }

        public func decode(_ samples: [Float]) async throws -> WhistleTranscript {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    io.async {
                        continuation.resume(with: Result { try self.exchange(samples) })
                    }
                }
            } onCancel: { self.control.stop(timeout: false) }
        }

        public func close() async {
            control.stop(timeout: false)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                io.async {
                    if let transport = self.transport {
                        try? transport.input.close()
                        transport.process.waitUntilExit()
                        transport.process.terminationHandler = nil
                        try? transport.output.close()
                        self.transport = nil
                    }
                    continuation.resume()
                }
            }
        }

        private func exchange(_ samples: [Float]) throws -> WhistleTranscript {
            if control.outcome().cancelled { throw CancellationError() }
            do {
                if transport == nil {
                    try withDeadline(seconds: 45) {
                        let connection = try open()
                        transport = connection
                        guard try connection.reader.next() == LiveWindowProtocol.ready else {
                            throw WhistleFailure.audio
                        }
                    }
                }
                guard let transport else { throw WhistleFailure.audio }
                return try withDeadline(seconds: 15) {
                    counter += 1
                    let request = try LiveWindowProtocol.Request(id: counter, samples: samples)
                    let packet = try JSONEncoder().encode(request) + Data([10])
                    try WhistleIO.write(packet, to: transport.input.fileDescriptor)
                    guard let line = try transport.reader.next() else { throw RequestFailure.invalidResponse }
                    let response = try JSONDecoder().decode(LiveWindowProtocol.Response.self, from: line)
                    guard response.id == counter else { throw RequestFailure.invalidResponse }
                    if response.failed { throw RequestFailure.rejected }
                    guard let transcript = response.transcript else { throw RequestFailure.invalidResponse }
                    if control.outcome().cancelled { throw CancellationError() }
                    return transcript
                }
            } catch {
                let outcome = control.outcome()
                if outcome.timedOut { throw Failure.timedOut }
                if outcome.cancelled { throw CancellationError() }
                throw error
            }
        }

        private func withDeadline<T>(seconds: Int, _ body: () throws -> T) throws -> T {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + .seconds(seconds))
            timer.setEventHandler { [control] in control.stop(timeout: true) }
            timer.resume()
            defer { timer.cancel() }
            let value = try body()
            if control.outcome().timedOut { throw Failure.timedOut }
            return value
        }

        private func open() throws -> Transport {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--live"] + arguments
            process.environment = environment
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [control] _ in control.exited.signal() }
            try process.run()
            control.attach(process)
            return Transport(process: process, input: input.fileHandleForWriting,
                             output: output.fileHandleForReading,
                             reader: WhistleLineReader(fd: output.fileHandleForReading.fileDescriptor, maximum: 1_048_576))
        }
    }

    static func run(executable: URL, arguments: [String], environment: [String: String], input: Data, timeout: TimeInterval = 30, clock: WatchdogClock) async throws -> Output {
        let control = Control(clock:clock)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // A process wait must not occupy the same finite worker pool
                // that its pipe drains and termination watchdog need to run.
                Thread.detachNewThread {
                    do { continuation.resume(returning: try blocking(executable, arguments, environment, input, timeout, control)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { control.stop(timeout: false) }
    }
    private static func blocking(_ executable: URL, _ arguments: [String], _ environment: [String: String], _ input: Data, _ timeout: TimeInterval, _ control: Control) throws -> Output {
        if control.outcome().cancelled { throw CancellationError() }
        let process = Process(); process.executableURL = executable; process.arguments = arguments; process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        if !input.isEmpty { control.clock.inputPipeCreated(stdin.fileHandleForReading.fileDescriptor) }
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        process.terminationHandler = { [control] _ in control.exited.signal() }
        try process.run(); control.attach(process)
        let deadline = Date().addingTimeInterval(timeout)
        let finished = DispatchSemaphore(value:0)
        Thread.detachNewThread {
            if control.clock.wait(.timeout,finished,timeout) { control.stop(timeout:true) }
        }
        defer { finished.signal(); process.terminationHandler = nil }
        let group = DispatchGroup(), capture = Capture()
        for (pipe, isError, cap) in [(stdout, false, 4_194_304), (stderr, true, 262_144)] {
            group.enter()
            Thread.detachNewThread {
                capture.put(drain(pipe.fileHandleForReading.fileDescriptor, cap: cap, until: deadline.addingTimeInterval(1)), error: isError)
                group.leave()
            }
        }
        var inputError: Int32?
        do { try WhistleIO.write(input, to: stdin.fileHandleForWriting.fileDescriptor) }
        catch WhistleIO.Failure.system(_, let code) { inputError = code }
        catch { inputError = EIO }
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        control.clock.didExit(process.terminationStatus)
        group.wait()
        let outcome = control.outcome()
        if outcome.cancelled { throw CancellationError() }
        if outcome.timedOut { throw Failure.timedOut }
        let (out, err) = capture.result()
        return .init(stdout: out, stderr: err, status: process.terminationStatus, inputError: inputError)
    }
    private static func drain(_ fd: Int32, cap: Int, until deadline: Date) -> Data {
        var result = Data(), bytes = [UInt8](repeating: 0, count: 16384)
        while Date() < deadline {
            var item = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&item, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; break }
            if ready == 0 { continue }
            let count = read(fd, &bytes, bytes.count)
            if count < 0 { if errno == EINTR { continue }; break }
            if count == 0 { break }
            // Keep draining after the diagnostic cap to avoid blocking the child.
            result.append(contentsOf: bytes.prefix(min(count, max(0, cap - result.count))))
        }
        return result
    }
}
