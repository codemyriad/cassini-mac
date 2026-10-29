// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CassiniKit
import CassiniLibrary

public enum BrowserPeerRole: String, Codable, Sendable { case control, audio }
public struct BrowserPeer: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public let role: BrowserPeerRole
    public let browser: String?
    init(id: UUID, role: BrowserPeerRole, browser: String?) {
        version = 1; self.id = id; self.role = role
        self.browser = browser.flatMap { ["Chrome","Chromium","Microsoft Edge","Brave"].contains($0) ? $0 : nil }
    }
}

enum PipeFiles {
    static let entries = ["request","reply","lease","peer.json"]
    static var standardRoot: URL { LibraryLocation.userHome.appendingPathComponent("Music/.cassini-browser-control",isDirectory:true) }
    static func directory(_ url: URL, create: Bool = false) throws {
        if create, mkdir(url.path,0o700) != 0 && errno != EEXIST { throw BrowserIPCError.unavailable }
        var info = stat()
        guard lstat(url.path,&info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw BrowserIPCError.unsafePath }
    }
    static func openFile(_ url: URL, flags: Int32, kind: mode_t = S_IFREG, create: Bool = false) throws -> Int32 {
        let fd = open(url.path,flags | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW | (create ? O_CREAT | O_EXCL : 0),0o600)
        guard fd >= 0 else { throw BrowserIPCError.unavailable }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == kind, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else { close(fd); throw BrowserIPCError.unsafePath }
        return fd
    }
    static func held(_ fd: Int32) -> Bool {
        while true {
            if flock(fd,LOCK_EX | LOCK_NB) == 0 { flock(fd,LOCK_UN); return false }
            if errno == EINTR { continue }
            return errno == EWOULDBLOCK
        }
    }
    /// Only the fixed children of a private validated peer directory are removed.
    static func retire(_ folder: URL) {
        guard (try? directory(folder)) != nil else { return }
        for name in entries { unlink(folder.appendingPathComponent(name).path) }
        rmdir(folder.path)
    }
}

/// One reader and one ordered writer per peer. Cancellation never closes an FD
/// underneath another thread; each owning I/O queue closes its own descriptors.
public final class BrowserPipeConnection: @unchecked Sendable {
    public let peer: BrowserPeer
    private let input: Int32, output: Int32, lease: Int32
    private let requestDummy: Int32?
    private let cancellation = Cancellation()
    private let writer: DispatchQueue
    private let lock = NSLock()
    private let readerDone = DispatchGroup()
    private var queued = 0
    private let ownsLease: Bool
    private let folder: URL?
    private var started = false
    private var stopped = false
    private let received: @Sendable (BrowserPipeConnection,Data) throws -> Void
    private let ended: @Sendable (BrowserPeer) -> Void

    init(peer: BrowserPeer, input: Int32, output: Int32, lease: Int32, dummy: Int32? = nil,
         ownsLease: Bool, folder: URL? = nil,
         received: @escaping @Sendable (BrowserPipeConnection,Data) throws -> Void,
         ended: @escaping @Sendable (BrowserPeer) -> Void) {
        self.peer = peer; self.input = input; self.output = output; self.lease = lease
        requestDummy = dummy; self.ownsLease = ownsLease; self.folder = folder
        self.received = received; self.ended = ended
        writer = DispatchQueue(label:"io.codemyriad.cassini.pipe-write." + peer.id.uuidString)
        readerDone.enter()
    }
    public func send(_ data: Data, closeAfter: Bool = false) throws {
        let packet = try FrameIO.normalized(data)
        lock.lock()
        guard !stopped else { lock.unlock(); throw BrowserIPCError.closed }
        guard queued + packet.count <= 2 * FrameIO.maximum else {
            lock.unlock(); close(); throw BrowserIPCError.backpressure
        }
        queued += packet.count
        writer.async { [self] in
            defer { lock.lock(); queued -= packet.count; lock.unlock() }
            do { try FrameIO.writeFrame(output,data:packet,cancel:cancellation); if closeAfter { close() } }
            catch { close() }
        }
        lock.unlock()
    }
    func start() {
        lock.lock(); guard !started else { lock.unlock(); return }; started = true; lock.unlock()
        DispatchQueue.global(qos:.userInitiated).async { [self] in
            var dummy = requestDummy
            defer { if let dummy { Darwin.close(dummy) }; Darwin.close(input); Darwin.close(lease); readerDone.leave(); close() }
            do {
                while !cancellation.isCancelled {
                    // Poll the lease without abandoning a partially read frame.
                    let packet = try FrameIO.read(input,cancel:cancellation,alive:{ [self] in ownsLease || PipeFiles.held(lease) })
                    guard let packet else { break }
                    if let held = dummy { Darwin.close(held); dummy = nil }
                    try received(self,FrameIO.normalized(packet))
                }
            } catch { /* The owner observes one disconnect; no invented stop packet. */ }
        }
    }
    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }; stopped = true; cancellation.cancel()
        writer.async { [self] in
            Darwin.close(output)
            readerDone.notify(queue:writer) { [self] in
                if let folder { PipeFiles.retire(folder) }
                ended(peer)
            }
        }
    }
}

/// The app owns the broker lease. Clients publish a fully constructed directory
/// with one rename; no common multi-writer audio pipe can interleave frames.
public final class BrowserPipeServer: @unchecked Sendable {
    public static var standardRoot: URL { PipeFiles.standardRoot }
    public let root: URL
    private let queue = DispatchQueue(label:"io.codemyriad.cassini.pipe-discovery")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let cancellation = Cancellation()
    private var lease: Int32 = -1
    private var timer: DispatchSourceTimer?
    private var peers: [UUID:BrowserPipeConnection] = [:]
    private var scanCursor = 0
    private var pendingCursor = 0
    private let retired = DispatchGroup()
    private let connected: @Sendable (BrowserPipeConnection) -> Void
    private let received: @Sendable (BrowserPipeConnection,Data) throws -> Void
    private let disconnected: @Sendable (BrowserPeer) -> Void
    public init(root: URL,
                connected: @escaping @Sendable (BrowserPipeConnection) -> Void,
                received: @escaping @Sendable (BrowserPipeConnection,Data) throws -> Void,
                disconnected: @escaping @Sendable (BrowserPeer) -> Void) {
        self.root = root; self.connected = connected; self.received = received; self.disconnected = disconnected
        queue.setSpecific(key:queueKey,value:1)
    }
    public func start() throws {
        guard lease == -1, !cancellation.isCancelled else { throw BrowserIPCError.unavailable }
        signal(SIGPIPE,SIG_IGN)
        try FileManager.default.createDirectory(at:root.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try PipeFiles.directory(root,create:true)
        let clients = root.appendingPathComponent("clients",isDirectory:true)
        try PipeFiles.directory(clients,create:true)
        let lockFile = root.appendingPathComponent("server.lease")
        let fd: Int32
        if FileManager.default.fileExists(atPath:lockFile.path) { fd = try PipeFiles.openFile(lockFile,flags:O_RDWR) }
        else { fd = try PipeFiles.openFile(lockFile,flags:O_RDWR,create:true) }
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw BrowserIPCError.unavailable }
        lease = fd
        let source = DispatchSource.makeTimerSource(queue:queue)
        source.schedule(deadline:.now(),repeating:.milliseconds(100))
        source.setEventHandler { [weak self] in self?.discover(clients) }
        timer = source; source.resume()
    }
    private func discover(_ clients: URL) {
        guard !cancellation.isCancelled, let names = try? FileManager.default.contentsOfDirectory(atPath:clients.path) else { return }
        // A host killed before its atomic publication can leave a staging
        // directory. Never remove a live lease or a recently created directory.
        let pending = names.filter { $0.hasPrefix(".pending-") && UUID(uuidString:String($0.dropFirst(9))) != nil }.sorted()
        let pendingCount = min(128,pending.count)
        for offset in 0..<pendingCount {
            let folder = clients.appendingPathComponent(pending[(pendingCursor + offset) % pending.count],isDirectory:true)
            guard (try? PipeFiles.directory(folder)) != nil else { continue }
            var info = stat()
            guard lstat(folder.path,&info) == 0, Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) > 30 else { continue }
            if let fd = try? PipeFiles.openFile(folder.appendingPathComponent("lease"),flags:O_RDWR) {
                let live = PipeFiles.held(fd); Darwin.close(fd)
                if live { continue }
            }
            PipeFiles.retire(folder)
        }
        if !pending.isEmpty { pendingCursor = (pendingCursor + pendingCount) % pending.count }
        let published = names.filter { UUID(uuidString:$0) != nil }.sorted()
        let count = min(256,published.count)
        let batch = (0..<count).map { published[(scanCursor + $0) % published.count] }
        if !published.isEmpty { scanCursor = (scanCursor + count) % published.count }
        for name in batch {
            guard let id = UUID(uuidString:name), peers[id] == nil, peers.count < 128 else { continue }
            let folder = clients.appendingPathComponent(name,isDirectory:true)
            do {
                try PipeFiles.directory(folder)
                let leaseURL = folder.appendingPathComponent("lease")
                let leaseFD: Int32
                do { leaseFD = try PipeFiles.openFile(leaseURL,flags:O_RDWR) }
                catch {
                    var info = stat()
                    if lstat(leaseURL.path,&info) != 0 && errno == ENOENT { PipeFiles.retire(folder) }
                    continue
                }
                guard PipeFiles.held(leaseFD) else { Darwin.close(leaseFD); PipeFiles.retire(folder); continue }
                var descriptors = [leaseFD]
                var adopted = false
                defer { if !adopted { for descriptor in descriptors { Darwin.close(descriptor) } } }
                let infoFD = try PipeFiles.openFile(folder.appendingPathComponent("peer.json"),flags:O_RDONLY)
                let handle = FileHandle(fileDescriptor:infoFD,closeOnDealloc:true)
                var fileInfo = stat()
                guard fstat(infoFD,&fileInfo) == 0, (0...4096).contains(fileInfo.st_size) else { throw BrowserIPCError.framing }
                let data = try handle.read(upToCount:4097) ?? Data(); try handle.close()
                guard data.count <= 4096, try JSONParser.parse(data)["version"]?.int == 1 else { throw BrowserIPCError.framing }
                let peer = try JSONDecoder().decode(BrowserPeer.self,from:data)
                guard peer.id == id, peer.browser == nil || ["Chrome","Chromium","Microsoft Edge","Brave"].contains(peer.browser!) else { throw BrowserIPCError.framing }
                let input = try PipeFiles.openFile(folder.appendingPathComponent("request"),flags:O_RDONLY,kind:S_IFIFO); descriptors.append(input)
                let dummy = try PipeFiles.openFile(folder.appendingPathComponent("request"),flags:O_WRONLY,kind:S_IFIFO); descriptors.append(dummy)
                let output = try PipeFiles.openFile(folder.appendingPathComponent("reply"),flags:O_WRONLY,kind:S_IFIFO); descriptors.append(output)
                let ready = try JSONEncoder().encode(["ready":id.uuidString.lowercased()])
                try FrameIO.writeFrame(output,data:ready,cancel:cancellation)
                let retired = self.retired
                let connection = BrowserPipeConnection(peer:peer,input:input,output:output,lease:leaseFD,dummy:dummy,ownsLease:false,folder:folder,
                    received:received,ended:{ [weak self] peer in
                        self?.queue.async { [weak self] in self?.peers.removeValue(forKey:peer.id) }
                        self?.disconnected(peer)
                        retired.leave()
                    })
                adopted = true; retired.enter(); peers[id] = connection; connected(connection); connection.start()
            } catch { /* An invalid peer never becomes a command or file destination. */ }
        }
    }
    public func stop() {
        cancellation.cancel()
        let finish = { [self] in
            timer?.cancel(); timer = nil
            for peer in peers.values { peer.close() }; peers.removeAll()
            if lease >= 0 {
                let fd = lease; lease = -1
                retired.notify(queue:.global()) { Darwin.close(fd) }
            }
        }
        if DispatchQueue.getSpecific(key:queueKey) != nil { finish() } else { queue.sync(execute:finish) }
    }
    deinit {
        cancellation.cancel(); timer?.cancel()
        for peer in peers.values { peer.close() }
        if lease >= 0 { let fd = lease; retired.notify(queue:.global()) { Darwin.close(fd) } }
    }
}

final class PipeEndpoint: ControlEndpoint, @unchecked Sendable {
    private let input: Int32, output: Int32, lease: Int32, serverLease: Int32
    private let cancellation = Cancellation()
    private let folder: URL
    private let writeSeconds: UInt64
    init(root: URL, role: BrowserPeerRole, browser: String?) throws {
        try PipeFiles.directory(root)
        let clients = root.appendingPathComponent("clients",isDirectory:true); try PipeFiles.directory(clients)
        let server = try PipeFiles.openFile(root.appendingPathComponent("server.lease"),flags:O_RDWR)
        guard PipeFiles.held(server) else { Darwin.close(server); throw BrowserIPCError.unavailable }
        var descriptors = [server], adopted = false
        defer { if !adopted { for descriptor in descriptors { Darwin.close(descriptor) } } }
        let peer = BrowserPeer(id:UUID(),role:role,browser:browser)
        let pending = clients.appendingPathComponent(".pending-" + peer.id.uuidString.lowercased(),isDirectory:true)
        let published = clients.appendingPathComponent(peer.id.uuidString.lowercased(),isDirectory:true)
        try PipeFiles.directory(pending,create:true)
        defer { if !adopted { PipeFiles.retire(pending); PipeFiles.retire(published) } }
        let leaseFD = try PipeFiles.openFile(pending.appendingPathComponent("lease"),flags:O_RDWR,create:true); descriptors.append(leaseFD)
        guard flock(leaseFD,LOCK_EX | LOCK_NB) == 0 else { throw BrowserIPCError.unavailable }
        for name in ["request","reply"] { guard mkfifo(pending.appendingPathComponent(name).path,0o600) == 0 else { throw BrowserIPCError.unavailable } }
        let infoFD = try PipeFiles.openFile(pending.appendingPathComponent("peer.json"),flags:O_WRONLY,create:true)
        let info = FileHandle(fileDescriptor:infoFD,closeOnDealloc:true)
        try info.write(contentsOf:JSONEncoder().encode(peer)); try info.close()
        let readFD = try PipeFiles.openFile(pending.appendingPathComponent("reply"),flags:O_RDONLY,kind:S_IFIFO); descriptors.append(readFD)
        let dummy = try PipeFiles.openFile(pending.appendingPathComponent("reply"),flags:O_WRONLY,kind:S_IFIFO); descriptors.append(dummy)
        guard rename(pending.path,published.path) == 0 else { throw BrowserIPCError.unavailable }
        let ready = try FrameIO.read(readFD,cancel:cancellation,deadline:DispatchTime.now().uptimeNanoseconds + 3_000_000_000)
        guard let ready, try JSONParser.parse(ready)["ready"]?.string == peer.id.uuidString.lowercased() else { throw BrowserIPCError.framing }
        let writeFD = try PipeFiles.openFile(published.appendingPathComponent("request"),flags:O_WRONLY,kind:S_IFIFO); descriptors.append(writeFD)
        Darwin.close(dummy); descriptors.removeAll { $0 == dummy }
        input = readFD; output = writeFD; lease = leaseFD; serverLease = server; folder = published
        writeSeconds = role == .audio ? 15 : 5
        adopted = true
    }
    deinit {
        Darwin.close(input); Darwin.close(output); Darwin.close(lease); Darwin.close(serverLease)
        PipeFiles.retire(folder)
    }
    func send(_ data: Data) throws { try FrameIO.writeFrame(output,data:FrameIO.normalized(data),cancel:cancellation,seconds:writeSeconds) }
    func receive() throws -> Data? { try receive(deadline:nil) }
    func receive(deadline: UInt64?) throws -> Data? { try FrameIO.read(input,cancel:cancellation,deadline:deadline).map { try FrameIO.normalized($0) } }
    func stop() { cancellation.cancel() }
}
