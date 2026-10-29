// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Serialize only destination publication and new-folder creation. An existing
/// capture never holds this lock while writing audio, notes or transcripts.
public enum LibraryRouting {
    public static func withLock<T>(file: URL = LibraryLocation.standardFile, exclusive: Bool, wait: Bool = true, _ body: () throws -> T) throws -> T {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let lock = file.appendingPathExtension("lock")
        let fd = open(lock.path,O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }; defer { close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { throw POSIXError(.EACCES) }
        let mode = (exclusive ? LOCK_EX : LOCK_SH) | (wait ? 0 : LOCK_NB)
        guard flock(fd,mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        defer { flock(fd,LOCK_UN) }
        return try body()
    }
    /// Unsandboxed native hosts use the GUI's published path, not its app-scoped
    /// bookmark (which belongs to a different code identity).
    public static func recordingDestination(file: URL = LibraryLocation.standardFile) throws -> URL {
        let location = try LibraryLocation.read(file:file)
        let destination = LibraryLocation.canonical(location.primary)
        if destination.path != LibraryLocation.standardRoot.path {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath:destination.path,isDirectory:&directory), directory.boolValue else { throw POSIXError(.ENOENT) }
        }
        return destination
    }
    /// The sandboxed app resolves its own bookmark at creation time and keeps
    /// this lease for the complete capture. Hosts keep using the path-only API.
    public static func withRecordingAccess<T>(file: URL = LibraryLocation.standardFile, defaultRoot: URL = LibraryLocation.standardRoot,
                                             _ body: (URL,LibraryAccess) throws -> T) throws -> T {
        try withLock(file:file,exclusive:false,wait:false) {
            let location = try LibraryLocation.read(file:file,defaultRoot:defaultRoot)
            let access = try LibraryAccess(location,tolerateMissingPrevious:true)
            let destination = access.roots[0]
            if location.primary.path != defaultRoot.path || location.bookmarks[location.primary.path] != nil {
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath:destination.path,isDirectory:&directory),directory.boolValue else { throw POSIXError(.ENOENT) }
            }
            return try body(destination,access)
        }
    }
}
