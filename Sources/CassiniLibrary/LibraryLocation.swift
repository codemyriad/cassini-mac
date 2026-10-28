// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CassiniKit

/// Mac-local app/host routing, separate from capture metadata and browser wire
/// messages. Previous roots remain readable after a failed or deferred move.
public struct LibraryLocation: Codable, Sendable, Equatable {
    public let version: Int
    public var primaryPath: String
    public var previousPaths: [String]
    public var bookmarks: [String:Data]
    public var pendingMoves: [LibraryPendingMove]
    public init(primary: URL, previous: [URL] = [], bookmarks: [String:Data] = [:], pendingMoves: [LibraryPendingMove] = []) {
        let path = primary.standardizedFileURL.path
        version = 1; primaryPath = path
        var seen: Set<String> = [path]
        previousPaths = previous.map { $0.standardizedFileURL.path }.filter { seen.insert($0).inserted }
        self.bookmarks = bookmarks; self.pendingMoves = pendingMoves
    }
    private enum CodingKeys: String, CodingKey { case version, primaryPath, previousPaths, bookmarks, pendingMoves }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        version = try values.decode(Int.self,forKey:.version)
        primaryPath = try values.decode(String.self,forKey:.primaryPath)
        previousPaths = try values.decode([String].self,forKey:.previousPaths)
        bookmarks = try values.decode([String:Data].self,forKey:.bookmarks)
        pendingMoves = try values.decodeIfPresent([LibraryPendingMove].self,forKey:.pendingMoves) ?? []
    }
    public var primary: URL { URL(fileURLWithPath:primaryPath,isDirectory:true) }
    public var roots: [URL] { ([primaryPath] + previousPaths).map { URL(fileURLWithPath:$0,isDirectory:true) } }
    public static var userHome: URL {
        getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { URL(fileURLWithPath:String(cString:$0)) } ?? FileManager.default.homeDirectoryForCurrentUser
    }
    public static func canonical(_ url: URL) -> URL {
        guard let path = realpath(url.path,nil) else { return url.standardizedFileURL }
        defer { free(path) }; return URL(fileURLWithPath:String(cString:path),isDirectory:true)
    }
    public static var standardRoot: URL { userHome.appendingPathComponent("Music/Cassini",isDirectory:true) }
    /// The existing Music entitlement covers this stable private pointer; the native host
    /// can read it without receiving an app preference or a browser message.
    public static var standardFile: URL {
        userHome.appendingPathComponent("Music/.cassini-library-location.json")
    }
    public func validate() throws {
        let paths = [primaryPath] + previousPaths
        guard version == 1, paths.count <= 32, Set(paths).count == paths.count,
              paths.allSatisfy({ $0.hasPrefix("/") && $0 != "/" && !$0.contains("\0") && $0.utf8.count < 4096 }),
              bookmarks.keys.allSatisfy(paths.contains), bookmarks.values.allSatisfy({ $0.count <= 524288 }),
              pendingMoves.count <= 10000, Set(pendingMoves.map(\.id)).count == pendingMoves.count,
              pendingMoves.allSatisfy({ $0.valid && previousPaths.contains($0.sourcePath) }) else { throw POSIXError(.EINVAL) }
    }
    public static func read(file: URL = standardFile, defaultRoot: URL = standardRoot) throws -> Self {
        let fd = open(file.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return .init(primary:defaultRoot) }
        guard fd >= 0 else { throw POSIXError(.EACCES) }; defer { close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= 1_048_576 else { throw POSIXError(.EINVAL) }
        let stream = FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        let bytes = try stream.read(upToCount:1_048_577) ?? Data()
        _ = try JSONParser.parse(bytes)
        let value = try JSONDecoder().decode(Self.self,from:bytes); try value.validate(); return value
    }
    public func write(file: URL = Self.standardFile) throws {
        try validate()
        let bytes = try JSONEncoder().encode(self)
        guard bytes.count <= 1_048_576 else { throw POSIXError(.EFBIG) }
        let folder = Self.canonical(file.deletingLastPathComponent())
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd = open(folder.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EACCES) }; defer { close(fd) }
        let name = ".library-location-" + UUID().uuidString
        let output = openat(fd,name,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard output >= 0 else { throw POSIXError(.EIO) }; defer { unlinkat(fd,name,0) }
        let stream = FileHandle(fileDescriptor:output,closeOnDealloc:true); defer { try? stream.close() }
        try stream.write(contentsOf:bytes); try stream.synchronize()
        guard renameat(fd,name,fd,file.lastPathComponent) == 0 else { throw POSIXError(.EIO) }
        _ = fsync(fd)
    }
}

/// Retain this object throughout capture/scan so a resolved security scope is
/// not released while another operation still uses its URLs.
public final class LibraryAccess: @unchecked Sendable {
    public let roots: [URL]
    private var scoped: [URL] = []
    public init(_ location: LibraryLocation, tolerateMissingPrevious: Bool = false) throws {
        var roots: [URL] = [], scoped: [URL] = []
        var complete = false
        defer { if !complete { scoped.forEach { $0.stopAccessingSecurityScopedResource() } } }
        for root in location.roots {
            var resolved = root
            if let bookmark = location.bookmarks[root.path] {
                var stale = false
                do {
                    resolved = try URL(resolvingBookmarkData:bookmark,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
                    if resolved.startAccessingSecurityScopedResource() { scoped.append(resolved) }
                } catch { if !tolerateMissingPrevious || roots.isEmpty { throw error } }
            }
            roots.append(LibraryLocation.canonical(resolved))
        }
        self.roots = roots; self.scoped = scoped; complete = true
    }
    deinit { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
}
