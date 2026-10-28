// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// The kernel releases this lease even after SIGKILL. PID reuse and sandbox
/// restrictions on kill(pid,0) therefore cannot strand new scratch audio.
public final class SpeechScratch {
    public let directory: URL
    private let fd: Int32
    public init(root: URL = FileManager.default.temporaryDirectory) throws {
        directory = root.appendingPathComponent("CassiniSpeech-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let descriptor = open(directory.appendingPathComponent(".lease").path,O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard descriptor >= 0 else { try? FileManager.default.removeItem(at:directory); throw POSIXError(.EACCES) }
        guard flock(descriptor,LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); try? FileManager.default.removeItem(at:directory); throw POSIXError(.EIO)
        }
        fd = descriptor
    }
    deinit { close(fd); try? FileManager.default.removeItem(at:directory) }
    public static func removeAbandoned(in root: URL) {
        for directory in (try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? [] {
            let name = directory.lastPathComponent
            guard name.hasPrefix("CassiniSpeech-") else { continue }
            let parts = name.dropFirst("CassiniSpeech-".count).split(separator:"-",maxSplits:1)
            guard parts.count == 2, let pid = Int32(parts[0]), pid > 0, UUID(uuidString:String(parts[1])) != nil else { continue }
            var info = stat()
            guard lstat(directory.path,&info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { continue }
            let fd = open(directory.appendingPathComponent(".lease").path,O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if fd >= 0 {
                defer { close(fd) }
                guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                      flock(fd,LOCK_EX | LOCK_NB) == 0 else { continue }
                try? FileManager.default.removeItem(at:directory)
            } else if errno == ENOENT, kill(pid,0) != 0, errno == ESRCH {
                // Compatibility only for scratch made before leases existed.
                try? FileManager.default.removeItem(at:directory)
            }
        }
    }
}
