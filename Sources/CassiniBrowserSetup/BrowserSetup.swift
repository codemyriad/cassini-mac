// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import AppKit

@objc public protocol CassiniBrowserSetupService {
    func connect(audioHostBookmark: Data, controlHostBookmark: Data, reply: @escaping @Sendable (Int,NSError?) -> Void)
}
public enum BrowserSetupError: Error { case unavailable, noBrowser, unsafePath, invalidHost, tooLarge }

/// Only the XPC service chooses production paths. Its RPC cannot choose a
/// destination, extension ID, executable or shell command. Two bookmarks transfer
/// access to exactly the sibling bundled hosts, checked against its own bundle.
public struct BrowserSetupInstallation {
    public static let serviceName = "io.codemyriad.cassini.browser-setup"
    public static let origin = "chrome-extension://pcafdaahfhjiolfpfnlhmljfgoabbaij/"
    public struct Browser: Sendable {
        public let bundleID: String
        public let name: String
        public let profile: String
    }
    public static let supportedBrowsers: [Browser] = [
        .init(bundleID:"com.google.Chrome",name:"Chrome",profile:"Google/Chrome"),
        .init(bundleID:"org.chromium.Chromium",name:"Chromium",profile:"Chromium"),
        .init(bundleID:"com.google.chrome.for.testing",name:"Chrome for Testing",profile:"Google/Chrome for Testing"),
        .init(bundleID:"com.microsoft.edgemac",name:"Microsoft Edge",profile:"Microsoft Edge"),
        .init(bundleID:"com.brave.Browser",name:"Brave",profile:"BraveSoftware/Brave-Browser")
    ]
    public static let browsers = supportedBrowsers.map(\.profile)
    public static func installedBrowsers(resolve: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier:$0) }) -> [Browser] {
        supportedBrowsers.filter { resolve($0.bundleID) != nil }
    }
    private let home: URL
    private let hosts: [(String,URL)]
    private let profiles: [String]
    public init(home: URL, contents: URL, browsers: [String]? = nil) {
        self.home = home
        profiles = browsers ?? Self.installedBrowsers().map(\.profile)
        hosts = [("io.codemyriad.cassini",contents.appendingPathComponent("MacOS/cassini-browser-host")),
                 ("io.codemyriad.cassini.control",contents.appendingPathComponent("MacOS/cassini-control-host"))]
    }
    public static var accountHome: URL? {
        guard let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath:String(cString:path),isDirectory:true)
    }
    public func install() throws -> Int { try install(beforePublish:{ _ in }) }
    /// Fault injection is a library testing SPI, never an XPC selector.
    @_spi(Testing) public func install(beforePublish: (Int) throws -> Void) throws -> Int {
        guard Set(profiles).isSubset(of:Set(Self.browsers)) else { throw BrowserSetupError.unsafePath }
        guard !profiles.isEmpty else { throw BrowserSetupError.noBrowser }
        for (_,url) in hosts {
            // Registration only needs executable metadata. A separate XPC
            // sandbox need not gain read access to the parent app's payload.
            let fd = open(url.path,O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno),userInfo:[NSFilePathErrorKey:url.path]) }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o111 != 0, info.st_mode & 0o022 == 0 else { throw BrowserSetupError.invalidHost }
        }
        var directories: [Directory] = []
        defer { for directory in directories { close(directory.fd) } }
        for browser in profiles {
            let parent = home.appendingPathComponent("Library/Application Support/" + browser)
            do {
                let parentFD = try Self.openDirectory(parent,create:true)
                defer { close(parentFD) }
                var parentInfo = stat()
                guard fstat(parentFD,&parentInfo) == 0, parentInfo.st_uid == getuid(), parentInfo.st_mode & 0o022 == 0 else { throw BrowserSetupError.unsafePath }
                let leaf = "NativeMessagingHosts"
                if mkdirat(parentFD,leaf,0o700) != 0 && errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
                let fd = openat(parentFD,leaf,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw Self.pathError() }
                var info = stat()
                guard fstat(fd,&info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
                      info.st_mode & 0o022 == 0 else { close(fd); throw BrowserSetupError.unsafePath }
                directories.append(.init(fd:fd))
            }
        }
        guard !directories.isEmpty else { throw BrowserSetupError.noBrowser }
        var leases: [Int32] = []
        defer { for fd in leases { close(fd) } }
        for directory in directories {
            let fd = openat(directory.fd,".cassini-connect.lock",O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,0o600)
            guard fd >= 0 else { throw Self.pathError() }
            var info = stat()
            guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_nlink == 1, info.st_mode & 0o077 == 0 else { close(fd); throw BrowserSetupError.unsafePath }
            guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { close(fd); throw BrowserSetupError.unavailable }
            leases.append(fd)
        }
        var publications: [Publication] = []
        for directory in directories {
            for (name,url) in hosts {
                let file = name + ".json"
                let old = try Self.read(directory.fd,file)
                let manifest: [String:Any] = ["name":name,"description":"Cassini local meeting recorder","path":url.path,"type":"stdio","allowed_origins":[Self.origin]]
                // Compare JSON meaning, not formatting or member order. In particular,
                // preserve the inode and mtime of an unchanged registration.
                if let old, let object = try? JSONSerialization.jsonObject(with:old) as? NSDictionary,
                   object.isEqual(to:manifest) { continue }
                publications.append(.init(directory:directory.fd,name:file,old:old,data:try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys])))
            }
            // D27: only retire registrations written by Cassini. A matching
            // extension origin alone does not establish ownership. Unsafe,
            // malformed and unrelated legacy entries remain untouched.
            for name in ["com.codemyriad.cassini","com.codemyriad.cassini.control"] {
                let file = name + ".json"
                guard let old = try? Self.read(directory.fd,file),
                      let manifest = try? JSONSerialization.jsonObject(with:old) as? [String:Any],
                      manifest["name"] as? String == name,
                      let path = manifest["path"] as? String,
                      hosts.contains(where:{ $0.1.lastPathComponent == URL(fileURLWithPath:path).lastPathComponent }) else { continue }
                publications.append(.init(directory:directory.fd,name:file,old:old,data:nil))
            }
        }
        var published: [Publication] = []
        do {
            for publication in publications {
                try beforePublish(published.count)
                try Self.publish(publication.data,directory:publication.directory,name:publication.name)
                published.append(publication)
            }
        } catch {
            // Each manifest is atomic. Restore every earlier publication if a
            // later one fails. A process crash can leave a subset registered;
            // Connect is idempotent and repairs that subset on the next attempt.
            var rollbackFailed = false
            for publication in published.reversed() {
                do {
                    try Self.publish(publication.old,directory:publication.directory,name:publication.name)
                } catch { rollbackFailed = true }
            }
            if rollbackFailed { throw BrowserSetupError.unavailable }
            throw error
        }
        return directories.count * hosts.count
    }
    private struct Directory { let fd: Int32 }
    private struct Publication { let directory: Int32; let name: String; let old: Data?; let data: Data? }
    private static func openDirectory(_ url: URL, create: Bool = false) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw BrowserSetupError.unsafePath }
        var fd = open("/",O_SEARCH | O_CLOEXEC)
        guard fd >= 0 else { throw Self.pathError() }
        do {
            for component in url.pathComponents.dropFirst() {
                guard component != ".", component != ".." else { throw BrowserSetupError.unsafePath }
                var next = openat(fd,component,O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(fd,component,0o700) == 0 || errno == EEXIST else { throw Self.pathError() }
                    next = openat(fd,component,O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw Self.pathError() }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    private static func pathError() -> Error {
        if errno == ELOOP || errno == ENOTDIR { return BrowserSetupError.unsafePath }
        return POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)
    }
    private static func read(_ directory: Int32, _ name: String) throws -> Data? {
        let fd = openat(directory,name,O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw Self.pathError() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o022 == 0, info.st_size >= 0, info.st_size <= 65536 else { throw BrowserSetupError.unsafePath }
        var data = Data(), buffer = [UInt8](repeating:0,count:8192)
        while true {
            let count = Darwin.read(fd,&buffer,buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw BrowserSetupError.unavailable }
            if count == 0 { return data }
            guard data.count + count <= 65536 else { throw BrowserSetupError.tooLarge }
            data.append(contentsOf:buffer.prefix(count))
        }
    }
    private static func publish(_ data: Data?, directory: Int32, name: String) throws {
        if let data { try write(data,directory:directory,name:name) }
        else if unlinkat(directory,name,0) != 0 && errno != ENOENT { throw Self.pathError() }
    }
    private static func write(_ data: Data, directory: Int32, name: String) throws {
        let temporary = ".cassini-connect-" + UUID().uuidString
        let fd = openat(directory,temporary,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        defer { close(fd); unlinkat(directory,temporary,0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Self.pathError() }
                offset += written
            }
        }
        guard fsync(fd) == 0, renameat(directory,temporary,directory,name) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
    }
}
