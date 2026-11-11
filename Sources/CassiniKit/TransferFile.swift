// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Copy user-selected bytes to private staging, with bounded buffers and stable source identity.
public enum TransferFile {
    @discardableResult public static func copy(_ source: URL, to destination: URL, limit: UInt64,
                                               check: () throws -> Void = {}) throws -> UInt64 {
        try check()
        let fd = open(source.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        let input = FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer { try? input.close() }
        var before = stat()
        guard fstat(fd,&before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0 else { throw POSIXError(.EINVAL) }
        guard UInt64(before.st_size) <= limit else { throw ZIPFailure.tooLarge }
        let outputFD = open(destination.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard outputFD >= 0 else { throw POSIXError(.EIO) }
        let output = FileHandle(fileDescriptor:outputFD,closeOnDealloc:true); defer { try? output.close() }
        var bytes: UInt64 = 0
        while true {
            try check()
            let data = try input.read(upToCount:ZIPArchive.chunkBytes) ?? Data()
            if data.isEmpty { break }
            guard UInt64(data.count) <= limit - bytes else { throw ZIPFailure.tooLarge }
            bytes += UInt64(data.count)
            try output.write(contentsOf:data)
        }
        var after = stat()
        guard fstat(fd,&after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, bytes == UInt64(before.st_size),
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw POSIXError(.EINVAL) }
        try check(); try output.synchronize()
        return bytes
    }
}
