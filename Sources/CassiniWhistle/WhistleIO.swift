import Foundation
import Darwin

public enum WhistleIO {
    public enum Failure: Error { case system(String, Int32), notRegular, tooLarge }
    public static func readRegular(_ url: URL, maximum: Int) throws -> Data {
        guard url.isFileURL else { throw Failure.notRegular }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.system("open", errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.system("fstat", errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegular }
        guard info.st_size >= 0, info.st_size <= maximum else { throw Failure.tooLarge }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = read(fd, &buffer, min(buffer.count, maximum - result.count + 1))
            if count < 0 { if errno == EINTR { continue }; throw Failure.system("read", errno) }
            if count == 0 { return result }
            guard count <= maximum - result.count else { throw Failure.tooLarge }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
    /// Suppress SIGPIPE on this descriptor, without changing the app's global
    /// signal disposition. POSIX writes turn a closed reader into a caught EPIPE.
    public static func write(_ data: Data, to fd: Int32) throws {
        guard fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.system("fcntl", errno) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw Failure.system("write", errno) }
                guard count > 0 else { throw Failure.system("write", EIO) }
                offset += count
            }
        }
    }
}

/// Bounds the buffer while reading, before allocating an arbitrarily long line.
public final class WhistleLineReader {
    private let fd: Int32
    private let maximum: Int
    private var pending = Data()
    public init(fd: Int32, maximum: Int = 65536) { self.fd = fd; self.maximum = maximum }
    public func next() throws -> Data? {
        while true {
            if let end = pending.firstIndex(of: 10) {
                guard pending.distance(from: pending.startIndex, to: end) <= maximum else { throw WhistleIO.Failure.tooLarge }
                let line = Data(pending[..<end]); pending.removeSubrange(...end); return line
            }
            guard pending.count <= maximum else { throw WhistleIO.Failure.tooLarge }
            var bytes = [UInt8](repeating: 0, count: min(4096, maximum - pending.count + 1))
            let count = read(fd, &bytes, bytes.count)
            if count < 0 { if errno == EINTR { continue }; throw WhistleIO.Failure.system("read stdin", errno) }
            if count == 0 { if pending.isEmpty { return nil }; defer { pending.removeAll() }; return pending }
            pending.append(contentsOf: bytes.prefix(count))
        }
    }
}
