// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Coordinates with import publication, metadata edits and speech workers. The
/// caller stops its own jobs first; another process's busy folder is left alone.
public enum LibraryTrash {
    public static func move(_ folder: URL, roots: [URL],
                            trash: (URL) throws -> URL? = systemTrash) throws -> URL? {
        guard LibraryScanner.identity(folder.lastPathComponent) != nil,
              roots.contains(where: { LibraryLocation.canonical($0) == LibraryLocation.canonical(folder.deletingLastPathComponent()) }) else {
            throw POSIXError(.EPERM)
        }
        let root = open(folder.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw POSIXError(.ENOENT) }; defer { close(root) }
        guard flock(root, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }
        defer { flock(root, LOCK_UN) }
        let directory = openat(root, folder.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0, errno == ENOENT { return nil }
        guard directory >= 0 else { throw POSIXError(.EPERM) }; defer { close(directory) }
        guard flock(directory, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }
        defer { flock(directory, LOCK_UN) }
        // Create the idle lock too: otherwise a different worker could create
        // it after an ENOENT check and start inference during the Trash call.
        let speech = openat(directory, ".transcription.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard speech >= 0 else { throw POSIXError(.EACCES) }
        defer { flock(speech, LOCK_UN); close(speech) }
        var info = stat()
        guard fstat(speech, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_uid == getuid(),
              flock(speech, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }
        var opened = stat(), named = stat()
        guard fstat(directory, &opened) == 0,
              fstatat(root, folder.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else { throw POSIXError(.EBUSY) }
        return try trash(folder)
    }
    public static func systemTrash(_ folder: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: folder, resultingItemURL: &result)
        return result as URL?
    }
    public static func unsupported(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == CocoaError.featureUnsupported.rawValue
    }
}
