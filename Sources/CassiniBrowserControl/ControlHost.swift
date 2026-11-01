// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit
import Darwin
import CassiniLibrary

protocol ControlEndpoint: AnyObject, Sendable {
    func send(_ data: Data) throws
    func receive() throws -> Data?
    func stop()
}

/// The Unix socket is only the isolated shared-conformance adapter. Production
/// uses file-scoped IPC and never asks the sandboxed app to open a socket.
final class TestSocketEndpoint: ControlEndpoint, @unchecked Sendable {
    private let fd: Int32
    private let cancellation = Cancellation()
    private var buffer = Data()
    init(path: String) throws {
        var info = stat()
        guard lstat(path,&info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK,
              info.st_mode & 0o077 == 0 else { throw BrowserIPCError.unsafePath }
        let parent = URL(fileURLWithPath:path).deletingLastPathComponent().path
        guard lstat(parent,&info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else { throw BrowserIPCError.unsafePath }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Data(path.utf8) + Data([0])
        guard bytes.count <= MemoryLayout.size(ofValue:address.sun_path) else { throw BrowserIPCError.unsafePath }
        _ = withUnsafeMutableBytes(of:&address.sun_path) { bytes.copyBytes(to:$0) }
        let socketFD = socket(AF_UNIX,SOCK_STREAM,0)
        guard socketFD >= 0 else { throw BrowserIPCError.unavailable }
        let connected = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) {
            Darwin.connect(socketFD,$0,socklen_t(MemoryLayout<sockaddr_un>.size))
        } }
        var uid: uid_t = 0, gid: gid_t = 0
        guard connected == 0, getpeereid(socketFD,&uid,&gid) == 0, uid == getuid() else {
            close(socketFD); throw BrowserIPCError.unavailable
        }
        do { try FrameIO.prepare(socketFD) } catch { close(socketFD); throw error }
        fd = socketFD
    }
    deinit { close(fd) }
    func send(_ data: Data) throws { try FrameIO.write(fd,bytes:FrameIO.normalized(data) + Data([10]),cancel:cancellation) }
    func receive() throws -> Data? {
        while true {
            if let end = buffer.firstIndex(of:10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                return try FrameIO.normalized(line)
            }
            guard buffer.count <= FrameIO.maximum else { throw BrowserIPCError.framing }
            try FrameIO.wait(fd,Int16(POLLIN),cancel:cancellation)
            var bytes = [UInt8](repeating:0,count:8192)
            let size = Darwin.read(fd,&bytes,bytes.count)
            if size < 0 && [EAGAIN,EINTR].contains(errno) { continue }
            if size == 0 { guard buffer.isEmpty else { throw BrowserIPCError.framing }; return nil }
            guard size > 0 else { throw BrowserIPCError.closed }
            buffer.append(contentsOf:bytes.prefix(size))
        }
    }
    func stop() { cancellation.cancel() }
}

private final class HostState: @unchecked Sendable {
    let cancellation = Cancellation()
    private let lock = NSLock()
    private var failure: String?
    private var reported = false
    private var errorCode = "io"
    private let replies = NSCondition()
    private var pending = 0
    func submittedRequest() { replies.lock(); pending += 1; replies.unlock() }
    func forwardedResponse() { replies.lock(); pending = max(0,pending-1); replies.broadcast(); replies.unlock() }
    func readerFinished() { cancellation.cancel(); replies.lock(); replies.broadcast(); replies.unlock() }
    func drainResponses(seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        replies.lock(); defer { replies.unlock() }
        while pending > 0 && !cancellation.isCancelled {
            if !replies.wait(until:deadline) { return false }
        }
        return pending == 0
    }
    func reportProtocolError() { lock.lock(); reported = true; lock.unlock(); fail(BrowserIPCError.closed) }
    func needsErrorFrame() -> String? { lock.lock(); defer { lock.unlock() }; return failure != nil && !reported ? errorCode : nil }
    func fail(_ error: Error) {
        lock.lock()
        if failure == nil {
            failure = String(describing:error)
            if let ipc = error as? BrowserIPCError, case .framing = ipc { errorCode = "framing" }
        }
        lock.unlock(); readerFinished()
    }
    func error() -> String? { lock.lock(); defer { lock.unlock() }; return failure }
}

public enum BrowserControlHost {
    public static func run(environment: [String:String] = ProcessInfo.processInfo.environment) -> Int32 {
        NativeHostBridge.run(role:.control,initial:nil,environment:environment)
    }
}
public enum BrowserAudioHost {
    public static func usesBroker(_ data: Data) -> Bool {
        guard let message = try? JSONParser.parse(data) else { return false }
        return message["type"]?.string == "start" && message["independent"]?.bool == true
    }
    public static func run(firstRequest: Data, environment: [String:String] = ProcessInfo.processInfo.environment) -> Int32 {
        NativeHostBridge.run(role:.audio,initial:firstRequest,environment:environment)
    }
}
private enum NativeHostBridge {
    static func run(role: BrowserPeerRole, initial: Data?, environment: [String:String]) -> Int32 {
        // Both framed stdout and protected pipe writes must report EPIPE rather
        // than killing the process before its owned IPC lease can be released.
        signal(SIGPIPE,SIG_IGN)
        let state = HostState(), readers = DispatchGroup()
        var endpoint: (any ControlEndpoint)?
        do {
            if role == .control, let path = environment["CASSINI_CONTROL_SOCKET"], !path.isEmpty { endpoint = try TestSocketEndpoint(path:path) }
            else {
                let root = environment["CASSINI_CONTROL_PIPE_ROOT"].map { URL(fileURLWithPath:$0,isDirectory:true) } ?? PipeFiles.standardRoot
                endpoint = try PipeEndpoint(root:root,role:role,browser:BrowserCompanionConnection.parentBrowserName,browserInstance:BrowserInstance.parentBrowser)
            }
            guard let connection = endpoint else { throw BrowserIPCError.unavailable }
            try FrameIO.prepare(STDIN_FILENO); try FrameIO.prepare(STDOUT_FILENO)
            readers.enter()
            DispatchQueue.global(qos:.userInitiated).async {
                defer { readers.leave(); state.readerFinished() }
                do {
                    while !state.cancellation.isCancelled, let data = try connection.receive() {
                        try FrameIO.writeFrame(STDOUT_FILENO,data:data,cancel:state.cancellation)
                        if role == .audio { state.forwardedResponse() }
                        // D52: a source- or command-scoped refusal keeps the connection;
                        // only an unscoped (session) error ends it.
                        if role == .audio, let reply = try? JSONParser.parse(data), reply["type"]?.string == "error", reply["scope"] == nil {
                            state.reportProtocolError(); connection.stop(); break
                        }
                    }
                } catch { if !state.cancellation.isCancelled { state.fail(error) } }
            }
            do {
                if let initial { if role == .audio { state.submittedRequest() }; try connection.send(initial) }
                while !state.cancellation.isCancelled, let data = try FrameIO.read(STDIN_FILENO,cancel:state.cancellation) {
                    if role == .audio { state.submittedRequest() }
                    try connection.send(data)
                }
                // EOF closes admission, not already accepted requests. Keep
                // the peer lease and response reader until every reply (in
                // particular stopped after fsync) has reached browser stdout.
                if role == .audio, state.error() == nil, !state.drainResponses(seconds:65) { throw BrowserIPCError.timeout }
            } catch { if !state.cancellation.isCancelled { state.fail(error) } }
        } catch { state.fail(error) }
        state.cancellation.cancel(); endpoint?.stop()
        let drained = readers.wait(timeout:.now() + 2) == .success
        if role == .audio, drained, let code = state.needsErrorFrame() {
            let response = JSON.object([("type",.string("error")),("code",.string(code)),("message",.string("The browser audio connection was interrupted."))])
            if let data = try? response.encoded(maximumBytes:FrameIO.maximum) {
                try? FrameIO.writeFrame(STDOUT_FILENO,data:data,cancel:Cancellation())
            }
        }
        if let error = state.error() { FileHandle.standardError.write(Data(("Cassini native host: " + error + "\n").utf8)); return 78 }
        return 0
    }
}
