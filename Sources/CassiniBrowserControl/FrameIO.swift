// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CassiniKit

public enum BrowserIPCError: Error { case unavailable, unsafePath, framing, closed, timeout, backpressure }

final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

enum FrameIO {
    static let maximum = 524288
    static func prepare(_ fd: Int32) throws {
        guard fcntl(fd,F_SETFL,fcntl(fd,F_GETFL) | O_NONBLOCK) == 0,
              fcntl(fd,F_SETFD,fcntl(fd,F_GETFD) | FD_CLOEXEC) == 0 else { throw POSIXError(.EIO) }
    }
    static func normalized(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximum else { throw BrowserIPCError.framing }
        let json: JSON
        do { json = try JSONParser.parse(data) } catch { throw BrowserIPCError.framing }
        guard json.object != nil else { throw BrowserIPCError.framing }
        if json["type"]?.string == "hello", json["version"]?.int != 1 { throw BrowserIPCError.framing }
        do { return try json.encoded(maximumBytes:maximum) } catch { throw BrowserIPCError.framing }
    }
    static func wait(_ fd: Int32, _ events: Int16, cancel: Cancellation, deadline: UInt64? = nil, alive: (@Sendable () -> Bool)? = nil) throws {
        while true {
            if cancel.isCancelled { throw BrowserIPCError.closed }
            if let alive, !alive() { throw BrowserIPCError.closed }
            if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline { throw BrowserIPCError.timeout }
            var item = pollfd(fd:fd,events:events,revents:0)
            let result = poll(&item,1,100)
            if result == -1 && errno == EINTR { continue }
            guard result >= 0, item.revents & Int16(POLLNVAL) == 0 else { throw BrowserIPCError.closed }
            // Recheck the nonblocking syscall even after a poll timeout: FIFO
            // EOF is not reliably reported as a readiness event on Darwin.
            return
        }
    }
    static func exact(_ fd: Int32, count: Int, cancel: Cancellation, allowEOF: Bool = false, deadline: UInt64? = nil, alive: (@Sendable () -> Bool)? = nil) throws -> Data? {
        var output = Data(), bytes = [UInt8](repeating:0,count:min(count,16384))
        var peerEnded = false
        while output.count < count {
            if cancel.isCancelled { throw BrowserIPCError.closed }
            if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline { throw BrowserIPCError.timeout }
            // A nonblocking FIFO read reports EOF even when Darwin poll does
            // not report a readiness event for its last writer disappearing.
            let size = Darwin.read(fd,&bytes,min(bytes.count,count-output.count))
            if size < 0 && errno == EINTR { continue }
            if size < 0 && errno == EAGAIN {
                if peerEnded { throw BrowserIPCError.closed }
                if let alive, !alive() {
                    // The last writer can exit between read(EAGAIN) and the
                    // lease check. Try once more to drain its final bytes.
                    peerEnded = true; continue
                }
                try wait(fd,Int16(POLLIN),cancel:cancel,deadline:deadline)
                continue
            }
            if size == 0, output.isEmpty && allowEOF { return nil }
            guard size > 0 else { throw BrowserIPCError.framing }
            output.append(contentsOf:bytes.prefix(size))
        }
        return output
    }
    static func read(_ fd: Int32, cancel: Cancellation, deadline: UInt64? = nil, alive: (@Sendable () -> Bool)? = nil) throws -> Data? {
        guard let header = try exact(fd,count:4,cancel:cancel,allowEOF:true,deadline:deadline,alive:alive) else { return nil }
        let length = header.withUnsafeBytes { UInt32(littleEndian:$0.loadUnaligned(as:UInt32.self)) }
        guard length > 0, length <= maximum else { throw BrowserIPCError.framing }
        return try exact(fd,count:Int(length),cancel:cancel,deadline:deadline,alive:alive)
    }
    static func write(_ fd: Int32, bytes: Data, cancel: Cancellation, seconds: UInt64 = 5) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + seconds * 1_000_000_000
        try bytes.withUnsafeBytes { buffer in
            var used = 0
            while used < buffer.count {
                try wait(fd,Int16(POLLOUT),cancel:cancel,deadline:deadline)
                let size = Darwin.write(fd,buffer.baseAddress!.advanced(by:used),buffer.count-used)
                if size < 0 && [EINTR,EAGAIN].contains(errno) { continue }
                guard size > 0 else { throw BrowserIPCError.closed }
                used += size
            }
        }
    }
    static func writeFrame(_ fd: Int32, data: Data, cancel: Cancellation, seconds: UInt64 = 5) throws {
        guard !data.isEmpty, data.count <= maximum else { throw BrowserIPCError.framing }
        var length = UInt32(data.count).littleEndian
        var output = withUnsafeBytes(of:&length) { Data($0) }; output.append(data)
        try write(fd,bytes:output,cancel:cancel,seconds:seconds)
    }
}
