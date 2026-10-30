// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin

/// D39's app-owned, browser-readable folder. The sandboxed helper supplies the
/// production home/source; its RPC accepts neither destination nor commands.
public struct LocalCompanionInstallation {
    public static let extensionID = "pcafdaahfhjiolfpfnlhmljfgoabbaij"
    public static let relativePath = "Library/Application Support/Cassini/BrowserCompanion/extension"
    public let home: URL, source: URL
    public init(home: URL, source: URL) { self.home = home; self.source = source }
    public var destination: URL { home.appendingPathComponent(Self.relativePath,isDirectory:true) }
    public struct Result: Sendable { public let updated: Bool, version: String }
    private struct Manifest { let version: String, components: [Int] }
    public func install() throws -> Result { try install(beforePublish:{}) }
    @_spi(Testing) public func install(beforePublish: () throws -> Void) throws -> Result {
        let sourceFD = try readableDirectory(source)
        defer { close(sourceFD) }
        let bundled = try manifest(sourceFD)
        let parent = destination.deletingLastPathComponent()
        let parentFD = try readableDirectory(parent,create:true)
        defer { close(parentFD) }
        var info = stat()
        guard fstat(parentFD,&info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw BrowserSetupError.unsafePath }
        let lockFD = openat(parentFD,".browser-companion.lock",O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,0o600)
        guard lockFD >= 0 else { throw error() }; defer { close(lockFD) }
        guard fstat(lockFD,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw BrowserSetupError.unsafePath }
        guard flock(lockFD,LOCK_EX | LOCK_NB) == 0 else { throw BrowserSetupError.unavailable }
        defer { flock(lockFD,LOCK_UN) }
        let name = destination.lastPathComponent
        let installedFD = openat(parentFD,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let exists = installedFD >= 0
        if installedFD >= 0 {
            defer { close(installedFD) }
            guard fstat(installedFD,&info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw BrowserSetupError.unsafePath }
            let old = try manifest(installedFD)
            if !old.components.lexicographicallyPrecedes(bundled.components) { return .init(updated:false,version:old.version) }
        } else if errno != ENOENT { throw BrowserSetupError.unsafePath }
        let stage = ".browser-companion-"+UUID().uuidString
        guard mkdirat(parentFD,stage,0o700) == 0 else { throw error() }
        defer { try? removeTree(parentFD,stage) }
        let stageFD = openat(parentFD,stage,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stageFD >= 0 else { throw error() }; defer { close(stageFD) }
        var count = 0, bytes = 0
        try copy(sourceFD,to:stageFD,depth:0,count:&count,bytes:&bytes)
        guard try manifest(stageFD).components == bundled.components else { throw BrowserSetupError.invalidHost }
        guard fsync(stageFD) == 0 else { throw error() }
        try beforePublish()
        // Atomic exchange keeps the loaded folder path present throughout an
        // update. The old tree becomes stage and is removed under the same lock.
        if exists {
            guard renameatx_np(parentFD,stage,parentFD,name,UInt32(RENAME_SWAP)) == 0 else { throw error() }
        } else {
            guard renameat(parentFD,stage,parentFD,name) == 0 else { throw error() }
        }
        guard fsync(parentFD) == 0 else { throw error() }
        return .init(updated:true,version:bundled.version)
    }
    private func readableDirectory(_ url: URL, create: Bool = false) throws -> Int32 {
        // macOS exposes these system-owned aliases even from resolved URLs
        // and app translocation. Preserve no-follow checks below that root.
        let path = url.path
        let physical = ["/var/","/tmp/","/etc/"].contains(where:{ path.hasPrefix($0) }) ? URL(fileURLWithPath:"/private"+path,isDirectory:true) : url
        let search = try BrowserSetupInstallation.openDirectory(physical,create:create)
        defer { close(search) }
        let fd = openat(search,".",O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error() }; return fd
    }
    private func manifest(_ directory: Int32) throws -> Manifest {
        let fd = openat(directory,"manifest.json",O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw BrowserSetupError.invalidHost }; defer { close(fd) }
        let data = try read(fd,limit:1_048_576)
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let key = object["key"] as? String, let der = Data(base64Encoded:key),
              SHA256.hash(data:der).prefix(16).flatMap({ [Character(UnicodeScalar(97+Int($0>>4))!),Character(UnicodeScalar(97+Int($0&15))!)] }).map(String.init).joined() == Self.extensionID,
              let version = object["version"] as? String else { throw BrowserSetupError.invalidHost }
        let parts = version.split(separator:".",omittingEmptySubsequences:false)
        guard (1...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && ($0.count == 1 || $0.first != "0") && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) else { throw BrowserSetupError.invalidHost }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ (0...65535).contains($0) }), numbers.contains(where:{ $0 > 0 }) else { throw BrowserSetupError.invalidHost }
        return .init(version:version,components:numbers+[Int](repeating:0,count:4-numbers.count))
    }
    private func names(_ fd: Int32) throws -> [String] {
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw error() }
        guard let directory = fdopendir(duplicate) else { close(duplicate); throw error() }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else { if errno != 0 { throw error() }; break }
            let name = withUnsafePointer(to:&entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to:CChar.self,capacity:1024) { String(cString:$0) }
            }
            if name != "." && name != ".." { result.append(name) }
        }
        return result.sorted()
    }
    private func copy(_ source: Int32, to destination: Int32, depth: Int, count: inout Int, bytes: inout Int) throws {
        guard depth <= 8 else { throw BrowserSetupError.tooLarge }
        for name in try names(source) {
            count += 1; guard count <= 256 else { throw BrowserSetupError.tooLarge }
            let input = openat(source,name,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard input >= 0 else { throw BrowserSetupError.unsafePath }; defer { close(input) }
            var info = stat()
            guard fstat(input,&info) == 0, info.st_mode & 0o022 == 0 else { throw BrowserSetupError.unsafePath }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard mkdirat(destination,name,0o700) == 0 else { throw error() }
                let output = openat(destination,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard output >= 0 else { throw error() }; defer { close(output) }
                try copy(input,to:output,depth:depth+1,count:&count,bytes:&bytes)
                guard fsync(output) == 0 else { throw error() }
            case S_IFREG:
                let data = try read(input,limit:2_097_152)
                bytes += data.count; guard bytes <= 16_777_216 else { throw BrowserSetupError.tooLarge }
                let output = openat(destination,name,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
                guard output >= 0 else { throw error() }; defer { close(output) }
                try data.withUnsafeBytes { buffer in
                    var written = 0
                    while written < buffer.count {
                        let n = Darwin.write(output,buffer.baseAddress!+written,buffer.count-written)
                        if n < 0 && errno == EINTR { continue }
                        guard n > 0 else { throw error() }; written += n
                    }
                }
                guard fsync(output) == 0 else { throw error() }
            default: throw BrowserSetupError.unsafePath
            }
        }
    }
    private func read(_ fd: Int32, limit: Int) throws -> Data {
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0, info.st_size <= limit else { throw BrowserSetupError.unsafePath }
        var data = Data(), buffer = [UInt8](repeating:0,count:8192)
        while true {
            let n = Darwin.read(fd,&buffer,buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw error() }
            if n == 0 { return data }
            guard data.count+n <= limit else { throw BrowserSetupError.tooLarge }
            data.append(contentsOf:buffer.prefix(n))
        }
    }
    private func removeTree(_ parent: Int32, _ name: String) throws {
        let fd = openat(parent,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { if errno == ENOENT { return }; throw error() }; defer { close(fd) }
        for child in try names(fd) {
            var info = stat()
            guard fstatat(fd,child,&info,AT_SYMLINK_NOFOLLOW) == 0 else { throw error() }
            if info.st_mode & S_IFMT == S_IFDIR { try removeTree(fd,child) }
            else if unlinkat(fd,child,0) != 0 { throw error() }
        }
        guard unlinkat(parent,name,AT_REMOVEDIR) == 0 else { throw error() }
    }
    private func error() -> Error { POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
}
