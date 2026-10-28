// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CassiniKit
import CryptoKit

public struct LibraryMoveResult: Sendable {
    public var moved: [String] = []
    public var deferred: [String] = []
    public var failed: [String] = []
    /// A complete destination exists; the old source could not be retired.
    public var originalsRetained: [String] = []
}

/// File movement only. Root selection, bookmarks, browser-host routing and live
/// capture deferral belong to the caller, not the read-only Library scanner.
public enum LibraryMove {
    public static func meetings(from source: URL, to destination: URL, excluding: Set<String> = [], including: Set<String>? = nil,
                                 shouldCancel: () -> Bool = { false }) throws -> LibraryMoveResult {
        try perform(from:source,to:destination,excluding:excluding,copyOnly:false,shouldCancel:shouldCancel,including:including)
    }
    static func perform(from source: URL, to destination: URL, excluding: Set<String>, copyOnly: Bool,
                        shouldCancel: () -> Bool, including: Set<String>? = nil, afterCopy: ((URL) throws -> Void)? = nil) throws -> LibraryMoveResult {
        let from = source.resolvingSymlinksInPath().standardizedFileURL
        let to = destination.resolvingSymlinksInPath().standardizedFileURL
        guard from.path != to.path, !to.path.hasPrefix(from.path + "/"), !from.path.hasPrefix(to.path + "/") else { throw POSIXError(.EINVAL) }
        let input = open(from.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw POSIXError(.ENOENT) }; defer { close(input) }
        try FileManager.default.createDirectory(at:to,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let output = open(to.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard output >= 0 else { throw POSIXError(.EACCES) }; defer { close(output) }
        // Coordinate with import publication without blocking the main actor.
        while flock(input,LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw POSIXError(.EIO) }
            if shouldCancel() { throw CancellationError() }; Thread.sleep(forTimeInterval:0.02)
        }
        defer { flock(input,LOCK_UN) }
        let names = try FileManager.default.contentsOfDirectory(atPath:from.path).filter { LibraryScanner.identity($0) != nil }.sorted()
        var result = LibraryMoveResult()
        for name in names {
            if let including, !including.contains(name) { continue }
            if shouldCancel() { throw CancellationError() }
            if excluding.contains(name) { result.deferred.append(name); continue }
            let path = from.appendingPathComponent(name)
            let fd = openat(input,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { result.failed.append(name); continue }
            defer { close(fd) }
            guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { result.deferred.append(name); continue }
            defer { flock(fd,LOCK_UN) }
            // A real transcription child holds this lock throughout inference.
            // Hold an existing idle lock through rename/copy to prevent a new job
            // starting between the busy check and publication.
            let speech = openat(fd,".transcription.lock",O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if speech >= 0 {
                guard flock(speech,LOCK_EX | LOCK_NB) == 0 else { close(speech); result.deferred.append(name); continue }
            } else if errno != ENOENT { result.failed.append(name); continue }
            defer { if speech >= 0 { flock(speech,LOCK_UN); close(speech) } }
            do {
                var info = stat()
                guard fstatat(output,name,&info,AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw POSIXError(.EEXIST) }
                if !copyOnly, renameatx_np(input,name,output,name,UInt32(RENAME_EXCL)) == 0 {
                    _ = fsync(input); _ = fsync(output); result.moved.append(name); continue
                }
                guard copyOnly || errno == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
                let before = try tree(path)
                let sourceHashes = try content(path,shouldCancel:shouldCancel)
                let temporary = to.appendingPathComponent(".cassini-move-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at:temporary) }
                try FileManager.default.copyItem(at:path,to:temporary)
                try afterCopy?(temporary)
                if shouldCancel() { throw CancellationError() }
                // Refuse a source that changed during the copy. Never publish a
                // mixture of two revisions or delete the original on failure.
                guard try tree(path) == before, try content(temporary,shouldCancel:shouldCancel) == sourceHashes else { throw POSIXError(.EBUSY) }
                try syncTree(temporary)
                guard renameatx_np(output,temporary.lastPathComponent,output,name,UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(.EEXIST) }
                _ = fsync(output)
                // Retire the source as one rename before recursive cleanup. If
                // this fails, both complete copies remain; no partial deletion.
                let retired = ".cassini-moved-" + UUID().uuidString
                if renameatx_np(input,name,input,retired,UInt32(RENAME_EXCL)) == 0 {
                    _ = fsync(input)
                    do { try FileManager.default.removeItem(at:from.appendingPathComponent(retired)) }
                    catch { /* Publication succeeded; an unlisted retired remnant remains. */ }
                } else { result.originalsRetained.append(name) }
                result.moved.append(name)
            } catch is CancellationError { throw CancellationError() }
            catch { result.failed.append(name) }
        }
        return result
    }
    public static func remaining(in root: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath:root.path).filter { LibraryScanner.identity($0) != nil })
    }
    /// Older browser hosts do not expose app control yet. Preserve a recording
    /// or unreadable producer manifest until completion is actually observable.
    public static func activeOrUnreadable(in root: URL, only: Set<String>? = nil, shouldCancel: () -> Bool = { false }) throws -> Set<String> {
        var result = Set<String>()
        for name in try remaining(in:root) {
            if let only, !only.contains(name) { continue }
            if shouldCancel() { throw CancellationError() }
            let speech = open(root.appendingPathComponent(name + "/.transcription.lock").path,O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if speech >= 0 {
                let idle = flock(speech,LOCK_EX | LOCK_NB) == 0
                if idle { flock(speech,LOCK_UN) }; close(speech)
                if !idle { result.insert(name); continue }
            } else if errno != ENOENT, name.hasPrefix("Recording-") { result.insert(name); continue }
            guard name.hasPrefix("Recording-") else { continue }
            do {
                let (fd,key) = try openRegular(root.appendingPathComponent(name + "/session.json")); defer { close(fd) }
                guard key.size <= 1_048_576 else { throw POSIXError(.EINVAL) }
                let bytes = try regularData(fd,limit:1_048_576)
                let value = try JSONParser.parse(bytes)
                if !["completed","interrupted"].contains(value["state"]?.string ?? "") { result.insert(name) }
            } catch { result.insert(name) }
        }
        return result
    }
    private struct Fingerprint: Equatable { let size: Int64; let hash: String? }
    private static func content(_ root: URL, shouldCancel: () -> Bool) throws -> [String:Fingerprint] {
        var result: [String:Fingerprint] = [:]
        func visit(_ folder: URL) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath:folder.path) {
                if shouldCancel() { throw CancellationError() }
                let url = folder.appendingPathComponent(name), relative = String(url.path.dropFirst(root.path.count))
                var info = stat()
                guard lstat(url.path,&info) == 0 else { throw POSIXError(.ENOENT) }
                if info.st_mode & S_IFMT == S_IFDIR { result[relative] = .init(size:0,hash:nil); try visit(url) }
                else {
                    let (fd,key) = try openRegular(url); defer { close(fd) }
                    let input = FileHandle(fileDescriptor:fd,closeOnDealloc:false)
                    var hash = SHA256(), count: Int64 = 0
                    while let bytes = try input.read(upToCount:1 << 20), !bytes.isEmpty {
                        if shouldCancel() { throw CancellationError() }
                        hash.update(data:bytes); count += Int64(bytes.count)
                        guard count <= key.size else { throw POSIXError(.EBUSY) }
                    }
                    guard count == key.size else { throw POSIXError(.EBUSY) }
                    result[relative] = .init(size:count,hash:hash.finalize().map { String(format:"%02x",$0) }.joined())
                }
            }
        }
        try visit(root); return result
    }
    private struct Entry: Equatable { let inode: UInt64; let size: Int64; let seconds: Int; let nanoseconds: Int }
    private static func tree(_ root: URL) throws -> [String:Entry] {
        var result: [String:Entry] = [:]
        func visit(_ folder: URL) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath:folder.path) {
                let url = folder.appendingPathComponent(name); var info = stat()
                guard lstat(url.path,&info) == 0 else { throw POSIXError(.ENOENT) }
                // A corrupt/unsafe meeting is retained instead of following a
                // link outside its boundary or waiting for a special file.
                guard [S_IFDIR,S_IFREG].contains(info.st_mode & S_IFMT) else { throw POSIXError(.EINVAL) }
                result[String(url.path.dropFirst(root.path.count))] = .init(inode:info.st_ino,size:info.st_size,seconds:info.st_mtimespec.tv_sec,nanoseconds:info.st_mtimespec.tv_nsec)
                if info.st_mode & S_IFMT == S_IFDIR { try visit(url) }
            }
        }
        try visit(root); return result
    }
    private static func syncTree(_ folder: URL) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath:folder.path) {
            let url = folder.appendingPathComponent(name); var info = stat()
            guard lstat(url.path,&info) == 0 else { throw POSIXError(.ENOENT) }
            if info.st_mode & S_IFMT == S_IFDIR { try syncTree(url) }
            else {
                let fd = open(url.path,O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw POSIXError(.EACCES) }; defer { close(fd) }
                guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
            }
        }
        let fd = open(folder.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EACCES) }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }
}
