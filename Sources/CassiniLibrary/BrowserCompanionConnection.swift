// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CassiniKit

public struct BrowserCompanionSnapshot: Sendable, Equatable {
    public let connected: Bool
    public let browser: String?
    public let recordingDirectories: Set<String>
    public init(connected: Bool = false, browser: String? = nil, recordingDirectories: Set<String> = []) {
        self.connected = connected; self.browser = browser; self.recordingDirectories = recordingDirectories
    }
}
/// Mac-local presence of a live Native Messaging connection. Every host owns a
/// separate advisory lease; no extension wire change or global capture lock.
public final class BrowserCompanionConnection {
    public static var directory: URL { LibraryLocation.standardFile.deletingLastPathComponent().appendingPathComponent(".cassini-browser-connections",isDirectory:true) }
    private let fd: Int32
    private let file: URL
    private let browser: String?
    private var recordingPath: String?
    public init(directory: URL = BrowserCompanionConnection.directory, browser: String? = nil) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var info = stat()
        guard lstat(directory.path,&info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw POSIXError(.EACCES) }
        file = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        fd = open(file.path,O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        self.browser = browser.flatMap { Self.names.contains($0) ? $0 : nil }
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { close(fd); unlink(file.path); throw POSIXError(.EIO) }
        do { try write() } catch { close(fd); unlink(file.path); throw error }
    }
    deinit { unlink(file.path); close(fd) }
    public func update(recordingDirectory: URL?) throws {
        let path = recordingDirectory.map { LibraryLocation.canonical($0).path }
        guard path != recordingPath else { return }; recordingPath = path; try write()
    }
    private func write() throws {
        var value: [String:Any] = ["version":1]
        if let browser { value["browser"] = browser }; if let recordingPath { value["recordingPath"] = recordingPath }
        let bytes = try JSONSerialization.data(withJSONObject:value)
        guard bytes.count <= 8192, ftruncate(fd,0) == 0, lseek(fd,0,SEEK_SET) == 0 else { throw POSIXError(.EIO) }
        try FileHandle(fileDescriptor:fd,closeOnDealloc:false).write(contentsOf:bytes)
    }
    private static let names: Set<String> = ["Chrome","Chromium","Microsoft Edge","Brave","Vivaldi","Opera"]
    public static var parentBrowserName: String? {
        var bytes = [CChar](repeating:0,count:4096)
        let length = bytes.withUnsafeMutableBufferPointer { proc_pidpath(getppid(),$0.baseAddress,UInt32($0.count)) }
        guard length > 0 else { return nil }; let path = String(cString:bytes)
        for (component,name) in [("Google Chrome.app","Chrome"),("Chromium.app","Chromium"),("Microsoft Edge.app","Microsoft Edge"),("Brave Browser.app","Brave"),("Vivaldi.app","Vivaldi"),("Opera.app","Opera")] {
            if path.contains("/" + component + "/") { return name }
        }
        return nil
    }
    public static func snapshot(directory: URL = BrowserCompanionConnection.directory) -> BrowserCompanionSnapshot {
        var info = stat()
        guard lstat(directory.path,&info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              let names = try? FileManager.default.contentsOfDirectory(atPath:directory.path) else { return .init() }
        var browsers: [String?] = [], recordings = Set<String>()
        for name in names.sorted().prefix(512) where name.hasSuffix(".json") && UUID(uuidString:String(name.dropLast(5))) != nil {
            let fd = open(directory.appendingPathComponent(name).path,O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }; defer { close(fd) }
            guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= 8192 else { continue }
            if flock(fd,LOCK_EX | LOCK_NB) == 0 { flock(fd,LOCK_UN); continue }
            guard errno == EWOULDBLOCK else { continue }
            let bytes = try? FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:8192)
            let json = bytes.flatMap { try? JSONParser.parse($0) }
            browsers.append(json?["browser"]?.string.flatMap { Self.names.contains($0) ? $0 : nil })
            if let path = json?["recordingPath"]?.string, path.hasPrefix("/"), path.utf8.count < 4096 { recordings.insert(path) }
        }
        let known = Set(browsers.compactMap { $0 })
        return .init(connected:!browsers.isEmpty,browser:known.count == 1 && !browsers.contains(nil) ? known.first : nil,recordingDirectories:recordings)
    }
}
