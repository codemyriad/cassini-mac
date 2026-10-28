// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin
import CassiniZstd

enum ModelFiles {
    static func existingDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path,&info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }
    static func directory(_ root: URL) throws {
        var info = stat()
        if lstat(root.path,&info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw ModelDownloadError.unsafePath }
            return
        }
        guard errno == ENOENT, root.path != "/" else { throw POSIXError(.EACCES) }
        try directory(root.deletingLastPathComponent())
        guard mkdir(root.path,0o700) == 0 || errno == EEXIST else { throw POSIXError(.EACCES) }
        try directory(root)
    }
    static func size(_ url: URL) throws -> UInt64? {
        var info = stat()
        if lstat(url.path,&info) != 0 { if errno == ENOENT { return nil }; throw POSIXError(.EACCES) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0 else { throw ModelDownloadError.unsafePath }
        return UInt64(info.st_size)
    }
    static func digest(_ url: URL) throws -> String {
        let fd = open(url.path,O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0, try size(url) != nil else { if fd >= 0 { close(fd) }; throw ModelDownloadError.unsafePath }
        let input = FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount:1 << 20), !data.isEmpty { try Task.checkCancellation(); hash.update(data:data) }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    static func decode(_ asset: ModelAsset, compressed: URL, output: URL) throws {
        guard let context = cassini_zstd_create() else { throw ModelDownloadError.zstd }; defer { cassini_zstd_free(context) }
        let input = try FileHandle(forReadingFrom:compressed); defer { try? input.close() }
        let fd = open(output.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        let stream = FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer { try? stream.close() }
        var buffer = [UInt8](repeating:0,count:128 << 10), produced: UInt64 = 0, last: Int = 1
        while let data = try input.read(upToCount:128 << 10), !data.isEmpty {
            var offset = 0, drain = false
            repeat {
                try Task.checkCancellation()
                var used = 0, written = 0
                last = data.withUnsafeBytes { source in buffer.withUnsafeMutableBytes { target in
                    cassini_zstd_decode(context,source.baseAddress!.advanced(by:offset),data.count - offset,&used,target.baseAddress,target.count,&written)
                } }
                guard last >= 0, UInt64(written) <= asset.rawBytes - produced else { throw ModelDownloadError.zstd }
                if used == 0 && written == 0 {
                    guard offset == data.count else { throw ModelDownloadError.zstd }; break
                }
                try stream.write(contentsOf:Data(buffer.prefix(written))); produced += UInt64(written); offset += used
                drain = last > 0 && written == buffer.count
            } while offset < data.count || drain
        }
        guard last == 0, produced == asset.rawBytes else { throw ModelDownloadError.truncated }
        try stream.synchronize()
        guard try digest(output) == asset.rawSHA256 else { throw ModelDownloadError.hash }
    }
}
