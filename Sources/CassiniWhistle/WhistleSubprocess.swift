import Foundation
import Darwin

/// Finite exchange used by the packaging probe. All blocking pipe/process work
/// runs off the main actor, with concurrent stderr draining and an independent
/// watchdog. The runtime queue can reuse the same descriptor primitives later.
public enum WhistleSubprocess {
    public enum Failure: Error { case timedOut }
    public struct Output: Sendable {
        public let stdout: Data
        public let stderr: Data
        public let status: Int32
        public let inputError: Int32?
    }
    private final class Control: @unchecked Sendable {
        let lock = NSLock()
        private var process: Process?
        private(set) var cancelled = false
        private(set) var timedOut = false
        func attach(_ process: Process) {
            lock.lock(); self.process = process; let stop = cancelled; lock.unlock()
            if stop { terminate(process) }
        }
        func stop(timeout: Bool) {
            lock.lock(); timedOut = timedOut || timeout; cancelled = cancelled || !timeout
            let process = process; lock.unlock()
            if let process { terminate(process) }
        }
        private func terminate(_ process: Process) {
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
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
        let control = Control()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
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
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run(); control.attach(process)
        let deadline = Date().addingTimeInterval(timeout)
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + timeout); watchdog.setEventHandler { control.stop(timeout: true) }; watchdog.resume()
        defer { watchdog.cancel() }
        let group = DispatchGroup(), capture = Capture()
        for (pipe, isError, cap) in [(stdout, false, 4_194_304), (stderr, true, 262_144)] {
            group.enter()
            DispatchQueue.global().async {
                capture.put(drain(pipe.fileHandleForReading.fileDescriptor, cap: cap, until: deadline.addingTimeInterval(1)), error: isError)
                group.leave()
            }
        }
        var inputError: Int32?
        do { try WhistleIO.write(input, to: stdin.fileHandleForWriting.fileDescriptor) }
        catch WhistleIO.Failure.system(_, let code) { inputError = code }
        catch { inputError = EIO }
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit(); group.wait()
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
