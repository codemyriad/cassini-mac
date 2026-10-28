// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CassiniLibrary

public enum ExportDestination {
    /// A chosen folder grants its children. Publish a fully written file with
    /// exclusive rename; collisions select title2/title3 without overwriting.
    public static func folder(_ artifact: ExportArtifact, directory: URL, title: String, extension suffix: String,
                               shouldCancel: () -> Bool = { false }) throws -> URL {
        let fd = open(directory.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EACCES) }; defer { close(fd) }
        let temporary = ".cassini-export-\(UUID().uuidString).tmp"
        let output = openat(fd,temporary,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard output >= 0 else { throw POSIXError(.EIO) }
        defer { unlinkat(fd,temporary,0) }
        try copy(artifact,to:output,shouldCancel:shouldCancel)
        for collision in 1...100000 {
            if shouldCancel() { throw CancellationError() }
            var name = MeetingMarkdown.filename(title:title,extension:suffix,collision:collision)
            // POSIX filesystems also cap a component's bytes. Keep the visible
            // stem within the shared120-character maximum and a safe byte cap.
            if name.utf8.count > 255 {
                let ending = (collision > 1 ? " \(collision)" : "") + "." + suffix
                var stem = String(name.dropLast(ending.count))
                while (stem + ending).utf8.count > 255 { stem.removeLast() }
                name = stem + ending
            }
            if renameatx_np(fd,temporary,fd,name,UInt32(RENAME_EXCL)) == 0 {
                _ = fsync(fd); return directory.appendingPathComponent(name)
            }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        }
        throw POSIXError(.EEXIST)
    }
    /// NSSavePanel grants the selected file. Foundation obtains an appropriate
    /// replacement directory so safe saving works with per-file sandbox access.
    public static func selectedFile(_ artifact: ExportArtifact, url: URL,
                                    shouldCancel: () -> Bool = { false }) throws {
        let manager = FileManager.default
        let replacement = try manager.url(for:.itemReplacementDirectory,in:.userDomainMask,appropriateFor:url,create:true)
        defer { try? manager.removeItem(at:replacement) }
        let pending = replacement.appendingPathComponent("meeting.tmp")
        let fd = open(pending.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        try copy(artifact,to:fd,shouldCancel:shouldCancel)
        if shouldCancel() { throw CancellationError() }
        if manager.fileExists(atPath:url.path) {
            _ = try manager.replaceItemAt(url,withItemAt:pending,backupItemName:nil,options:.usingNewMetadataOnly)
        } else { try manager.moveItem(at:pending,to:url) }
    }
    private static func copy(_ artifact: ExportArtifact, to fd: Int32, shouldCancel: () -> Bool) throws {
        let destination = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer { try? destination.close() }
        let source = try FileHandle(forReadingFrom:artifact.url); defer { try? source.close() }
        while let data = try source.read(upToCount:1024 * 1024), !data.isEmpty {
            if shouldCancel() { throw CancellationError() }
            try destination.write(contentsOf:data)
        }
        try destination.synchronize()
    }
}
