// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

@objc public protocol CassiniBrowserSetupService {
    func connect(audioHostBookmark: Data, controlHostBookmark: Data, reply: @escaping @Sendable (Int,NSError?) -> Void)
}
public enum BrowserSetupError: Error { case unavailable, unsafePath, invalidHost, tooLarge }

/// Only the XPC service chooses production paths. Its RPC cannot choose a
/// destination, extension ID, executable or shell command. Two bookmarks transfer
/// access to exactly the sibling bundled hosts, checked against its own bundle.
public struct BrowserSetupInstallation {
    public static let serviceName = "com.codemyriad.cassini-mac.browser-setup"
    public static let origin = "chrome-extension://pcafdaahfhjiolfpfnlhmljfgoabbaij/"
    public static let browsers = ["Google/Chrome","Chromium","Microsoft Edge","BraveSoftware/Brave-Browser"]
    private let home: URL
    private let hosts: [(String,URL)]
    public init(home: URL, contents: URL) {
        self.home = home
        hosts = [("com.codemyriad.cassini",contents.appendingPathComponent("MacOS/cassini-browser-host")),
                 ("com.codemyriad.cassini.control",contents.appendingPathComponent("MacOS/cassini-control-host"))]
    }
    public static var accountHome: URL? {
        guard let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath:String(cString:path),isDirectory:true)
    }
    public func install() throws -> Int { try install(beforePublish:{ _ in }) }
    /// Fault injection is a library testing SPI, never an XPC selector.
    @_spi(Testing) public func install(beforePublish: (Int) throws -> Void) throws -> Int {
        for (_,url) in hosts {
            // Registration only needs executable metadata. A separate XPC
            // sandbox need not gain read access to the parent app's payload.
            let fd = open(url.path,O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno),userInfo:[NSFilePathErrorKey:url.path]) }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o111 != 0, info.st_mode & 0o022 == 0 else { throw NSError(domain:"CassiniSetupHost",code:1,userInfo:[NSFilePathErrorKey:url.path,"mode":Int(info.st_mode)]) }
        }
        var directories: [Directory] = []
        defer { for directory in directories { close(directory.fd) } }
        for browser in Self.browsers {
            let parent = home.appendingPathComponent("Library/Application Support/" + browser)
            do {
                let parentFD = try Self.openDirectory(parent)
                defer { close(parentFD) }
                let leaf = "NativeMessagingHosts"
                if mkdirat(parentFD,leaf,0o700) != 0 && errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
                let fd = openat(parentFD,leaf,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw BrowserSetupError.unsafePath }
                var info = stat()
                guard fstat(fd,&info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
                      info.st_mode & 0o022 == 0 else { close(fd); throw BrowserSetupError.unsafePath }
                directories.append(.init(fd:fd))
            } catch let error as POSIXError where error.code == .ENOENT {
                // A supported browser that has never run has no profile tree.
                // Do not create browser profiles or change their preferences.
                continue
            }
        }
        guard !directories.isEmpty else { throw BrowserSetupError.unavailable }
        var leases: [Int32] = []
        defer { for fd in leases { close(fd) } }
        for directory in directories {
            let fd = openat(directory.fd,".cassini-connect.lock",O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,0o600)
            guard fd >= 0 else { throw BrowserSetupError.unsafePath }
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
                publications.append(.init(directory:directory.fd,name:file,old:old,data:try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys])))
            }
        }
        var published: [Publication] = []
        do {
            for publication in publications {
                try beforePublish(published.count)
                try Self.write(publication.data,directory:publication.directory,name:publication.name)
                published.append(publication)
            }
        } catch {
            // Each manifest is atomic. Restore every earlier publication if a
            // later one fails. A process crash can leave a subset registered;
            // Connect is idempotent and repairs that subset on the next attempt.
            var rollbackFailed = false
            for publication in published.reversed() {
                do {
                    if let old = publication.old { try Self.write(old,directory:publication.directory,name:publication.name) }
                    else if unlinkat(publication.directory,publication.name,0) != 0 && errno != ENOENT { throw BrowserSetupError.unavailable }
                } catch { rollbackFailed = true }
            }
            if rollbackFailed { throw BrowserSetupError.unavailable }
            throw error
        }
        return publications.count
    }
    private struct Directory { let fd: Int32 }
    private struct Publication { let directory: Int32; let name: String; let old: Data?; let data: Data }
    private static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw BrowserSetupError.unsafePath }
        var fd = open("/",O_SEARCH | O_CLOEXEC)
        guard fd >= 0 else { throw BrowserSetupError.unsafePath }
        do {
            for component in url.pathComponents.dropFirst() {
                guard component != ".", component != ".." else { throw BrowserSetupError.unsafePath }
                let next = openat(fd,component,O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    private static func read(_ directory: Int32, _ name: String) throws -> Data? {
        let fd = openat(directory,name,O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw BrowserSetupError.unsafePath }
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
    private static func write(_ data: Data, directory: Int32, name: String) throws {
        let temporary = ".cassini-connect-" + UUID().uuidString
        let fd = openat(directory,temporary,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw BrowserSetupError.unavailable }
        defer { close(fd); unlinkat(directory,temporary,0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw BrowserSetupError.unavailable }
                offset += written
            }
        }
        guard fsync(fd) == 0, renameat(directory,temporary,directory,name) == 0 else { throw BrowserSetupError.unavailable }
    }
}
