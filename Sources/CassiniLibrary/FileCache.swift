import Foundation
import Darwin

/// R1: never follow file symlinks or wait for a FIFO. fstat checks the opened
/// descriptor too, so replacing a regular file with a link cannot bypass this.
func openRegular(_ url: URL) throws -> (Int32, FileKey) {
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
        Darwin.close(fd); throw MetadataError.invalid
    }
    return (fd, FileKey(info))
}
func pathInfo(_ url: URL) throws -> stat? {
    var info = stat()
    if lstat(url.path, &info) == 0 { return info }
    if errno == ENOENT { return nil }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
struct FileKey: Equatable {
    let device: dev_t; let inode: ino_t; let size: off_t; let seconds: Int; let nanoseconds: Int
    init(_ s: stat) {
        device = s.st_dev; inode = s.st_ino; size = s.st_size
        seconds = s.st_mtimespec.tv_sec; nanoseconds = s.st_mtimespec.tv_nsec
    }
}
func regularData(_ fd: Int32, limit: Int = Int.max - 1) throws -> Data {
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    let data = try (limit == Int.max - 1 ? file.readToEnd() : file.read(upToCount: limit + 1)) ?? Data()
    guard data.count <= limit else { throw MetadataError.invalid }
    return data
}
/// R10: typed successes AND failures are cached by the opened file's stat key.
/// Sharing a scanner across background scans does not repeat Opus verification.
final class LibraryFileCache: @unchecked Sendable {
    private struct Entry { var key: FileKey; var value: Result<Any, Error> }
    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]
    private var counts: [URL: Int] = [:]
    func read<Value>(_ url: URL, parse: (Int32) throws -> Value) throws -> Value {
        let (fd, key) = try openRegular(url); defer { Darwin.close(fd) }
        lock.lock(); defer { lock.unlock() }
        if let entry = entries[url], entry.key == key {
            switch entry.value {
            case .success(let value): if let typed = value as? Value { return typed }
            case .failure(let error): throw error
            }
        }
        counts[url, default: 0] += 1
        let value = Result<Any, Error> { try parse(fd) }
        entries[url] = Entry(key: key, value: value)
        return try value.get() as! Value
    }
    func prune(keeping urls: Set<URL>) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { urls.contains($0.key) }
    }
    func parseCount(_ url: URL) -> Int { lock.lock(); defer { lock.unlock() }; return counts[(try? physicalURL(url)) ?? url, default: 0] }
}

func physicalURL(_ url: URL) throws -> URL {
    guard let path = realpath(url.path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: false)
}
