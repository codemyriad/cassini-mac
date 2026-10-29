// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit
import CassiniRecording

public protocol BrowserAudioHandler: Sendable {
    func connected(_ connection: BrowserPipeConnection)
    func received(_ data: Data, from connection: BrowserPipeConnection)
    func disconnected(_ peer: BrowserPeer)
}
public struct BrowserAudioStart: Sendable {
    public let captureID: String
    public let timelineOriginMs: Int
    public let microphone: Bool
}
public typealias BrowserNativeStop = @Sendable (OwnedBrowserCapture,@escaping @Sendable (String?) -> Void) -> Void

/// One native audio peer/owner per recording. The registry lock protects pointers
/// and reservations only; disk I/O and device shutdown run outside that lock.
public final class BrowserAudioBroker: BrowserAudioHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [UUID:AudioPeer] = [:]
    private var captures: [UUID:OwnedBrowserCapture] = [:]
    private var reservations: [Data:UUID] = [:]
    private var identities: [UUID:Data] = [:]
    private let finalization = CaptureFinalization()
    private let make: @Sendable (String,Bool) throws -> OwnedBrowserCapture
    private let created: @Sendable (OwnedBrowserCapture,BrowserAudioStart) -> Void
    private let stopNative: BrowserNativeStop
    public init(make: @escaping @Sendable (String,Bool) throws -> OwnedBrowserCapture,
                created: @escaping @Sendable (OwnedBrowserCapture,BrowserAudioStart) -> Void,
                stopNative: @escaping BrowserNativeStop) {
        self.make = make; self.created = created; self.stopNative = stopNative
    }
    public var activeCaptures: [OwnedBrowserCapture] {
        lock.lock(); defer { lock.unlock() }; return Array(captures.values)
    }
    public func connected(_ connection: BrowserPipeConnection) {
        guard connection.peer.role == .audio else { connection.close(); return }
        lock.lock(); defer { lock.unlock() }
        guard peers.count < 100, peers[connection.peer.id] == nil else { connection.close(); return }
        peers[connection.peer.id] = AudioPeer(connection:connection,broker:self)
    }
    public func received(_ data: Data, from connection: BrowserPipeConnection) {
        lock.lock(); let peer = peers[connection.peer.id]; lock.unlock()
        peer?.receive(data)
    }
    public func disconnected(_ peer: BrowserPeer) {
        lock.lock()
        let value = peers.removeValue(forKey:peer.id)
        lock.unlock()
        value?.disconnected()
    }
    fileprivate func begin(_ info: BrowserAudioStart, title: String, peer: UUID) throws -> OwnedBrowserCapture {
        let identity = Data(info.captureID.utf8)
        lock.lock()
        guard reservations[identity] == nil else { lock.unlock(); throw BrowserProtocolError("state","Capture is already active.") }
        reservations[identity] = peer; lock.unlock()
        let capture: OwnedBrowserCapture
        do { capture = try make(title,info.microphone) }
        catch {
            lock.lock(); if reservations[identity] == peer { reservations.removeValue(forKey:identity) }; lock.unlock(); throw error
        }
        lock.lock(); captures[capture.snapshot.manifest.id] = capture; identities[capture.snapshot.manifest.id] = identity; lock.unlock()
        DispatchQueue.global().async { [created] in if capture.snapshot.phase == .recording { created(capture,info) } }
        return capture
    }
    public func finish(_ capture: OwnedBrowserCapture, problem: String? = nil) async throws {
        try await finalization.run(capture) { try await self.finishOnce(capture,problem:problem) }
    }
    private func finishOnce(_ capture: OwnedBrowserCapture, problem: String?) async throws {
        guard lock.withLock({ captures[capture.snapshot.manifest.id] === capture }) else { return }
        let nativeProblem = await withCheckedContinuation { continuation in
            let barrier = StopReply { continuation.resume(returning:$0) }
            DispatchQueue.global().async { [stopNative] in stopNative(capture) { barrier.complete($0) } }
            DispatchQueue.global().asyncAfter(deadline:.now() + 30) { barrier.complete("Native inputs did not finish stopping; the recording may be incomplete.") }
        }
        defer {
            lock.withLock {
                let id = capture.snapshot.manifest.id
                captures.removeValue(forKey:id)
                if let identity = identities.removeValue(forKey:id) { reservations.removeValue(forKey:identity) }
            }
        }
        try await capture.finish(problem:problem ?? nativeProblem)
    }
    /// App Quit/Stop handles native input shutdown before closing the IPC server.
    /// Browser Stop commands should be sent first so the page can flush its tail.
    public func finishAll(problem: String? = nil) async {
        let values = activeCaptures
        await withTaskGroup(of:Void.self) { group in
            for capture in values { group.addTask { try? await self.finish(capture,problem:problem) } }
        }
    }
}
/// App Stop, a browser Stop and Quit may arrive together. They share one native
/// drain and final checkpoint; a completed owner's snapshot rejects later work.
private actor CaptureFinalization {
    private var tasks: [UUID:Task<Void,Error>] = [:]
    func run(_ capture: OwnedBrowserCapture, operation: @escaping @Sendable () async throws -> Void) async throws {
        let id = capture.snapshot.manifest.id
        if let task = tasks[id] { return try await task.value }
        guard capture.snapshot.phase != .saved else { return }
        let task = Task { try await operation() }
        tasks[id] = task
        defer { tasks.removeValue(forKey:id) }
        try await task.value
    }
}
private final class StopReply: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let reply: @Sendable (String?) -> Void
    init(_ reply: @escaping @Sendable (String?) -> Void) { self.reply = reply }
    func complete(_ issue: String?) {
        lock.lock(); guard !done else { lock.unlock(); return }; done = true; lock.unlock(); reply(issue)
    }
}
private final class AudioPeer: @unchecked Sendable {
    private let connection: BrowserPipeConnection
    private weak var broker: BrowserAudioBroker?
    // receive/disconnected are serialized by this connection's reader lifetime.
    private var owner: OwnedBrowserCapture?
    private var completed = false, failed = false
    private var originUptime: TimeInterval?
    init(connection: BrowserPipeConnection, broker: BrowserAudioBroker) { self.connection = connection; self.broker = broker }
    private func string(_ json: JSON, _ key: String, optional: Bool = false, code: String = "source") throws -> String? {
        guard let value = json[key], !value.isNull else {
            if optional { return nil }; throw BrowserProtocolError(code,"Missing source information.")
        }
        guard let value = value.string else { throw BrowserProtocolError(code,"Invalid source information.") }; return value
    }
    private func integer(_ value: JSON?, code: String = "source") throws -> Int {
        guard let value = value?.int, (0...9007199254740991).contains(value) else { throw BrowserProtocolError(code,"Expected a safe integer literal.") }; return value
    }
    func receive(_ data: Data) {
        guard !failed else { return }
        do {
            guard !data.isEmpty, data.count <= FrameIO.maximum else { throw BrowserProtocolError("framing","Invalid native frame size.") }
            let json: JSON
            do { json = try JSONParser.parse(data) } catch { throw BrowserProtocolError("framing","Invalid JSON message.") }
            guard let type = json["type"]?.string, json.object != nil else { throw BrowserProtocolError("framing","Expected a message object.") }
            guard !completed else { throw BrowserProtocolError("state","Recording is already stopped.") }
            guard ["start","track","audio","stop"].contains(type) else { throw BrowserProtocolError("version","Unknown browser message type.") }
            var response: JSON = .object([("type",.string("ack"))])
            if type == "start" {
                guard owner == nil else { throw BrowserProtocolError("state","Recording has already started.") }
                if let version = json["version"], !version.isNull, try integer(version,code:"version") != 1 { throw BrowserProtocolError("version","Unsupported protocol version.") }
                guard json["independent"]?.bool == true else { throw BrowserProtocolError("source","Independent capture is required.") }
                let id = try string(json,"captureId")!
                guard !id.isEmpty, id.unicodeScalars.count <= 128 else { throw BrowserProtocolError("source","Invalid capture identity.") }
                let origin = try integer(json["timelineOriginMs"])
                var mic = true
                if let value = json["microphone"], !value.isNull {
                    guard let value = value.bool else { throw BrowserProtocolError("source","Invalid microphone choice.") }; mic = value
                }
                guard let broker else { throw BrowserProtocolError("io","Recording broker is unavailable.") }
                let capture = try broker.begin(.init(captureID:id,timelineOriginMs:origin,microphone:mic),title:try string(json,"title",optional:true) ?? "Browser recording",peer:connection.peer.id)
                originUptime = ProcessInfo.processInfo.systemUptime - (Date().timeIntervalSince1970*1000 - Double(origin))/1000
                owner = capture; response = .object([("type",.string("started")),("path",.string(capture.snapshot.directory.path))])
            } else {
                guard let owner else { throw BrowserProtocolError("state","No active recording.") }
                switch type {
                case "track":
                    try owner.browserTrack(id:string(json,"id")!,label:string(json,"label",optional:true) ?? string(json,"kind")!,kind:string(json,"kind")!,sampleRate:integer(json["sampleRate"]),channels:integer(json["channels"]))
                case "audio":
                    let id = try string(json,"id")!, sequence = try integer(json["sequence"],code:"sequence")
                    guard let encoded = try string(json,"pcm",code:"chunk"), encoded.utf8.count <= 349528,
                          let pcm = Data(base64Encoded:encoded), let offset = json["offsetMs"]?.double, offset.isFinite else { throw BrowserProtocolError("chunk","Invalid audio chunk.") }
                    try owner.browserAudio(id:id,sequence:sequence,offsetMs:offset,pcm:pcm)
                case "stop":
                    let reason = try string(json,"failureReason",optional:true), problem = try string(json,"problem",optional:true)
                    guard reason == nil || reason == "lost" else { throw BrowserProtocolError("source","Invalid failure reason.") }
                    if reason == "lost" { try owner.browserLost(atMs:lossTime) }
                    else if let broker {
                        let done = DispatchSemaphore(value:0), outcome = FinishResult()
                        Task {
                            do { try await broker.finish(owner,problem:problem); outcome.store(.success(())) }
                            catch { outcome.store(.failure(error)) }
                            done.signal()
                        }
                        guard done.wait(timeout:.now() + 60) == .success else { throw BrowserProtocolError("io","Recording is still saving.") }
                        try outcome.get()
                    }
                    completed = true
                    var fields: [(String,JSON)] = [("type",.string("stopped")),("path",.string(owner.snapshot.directory.path))]
                    if let problem = owner.snapshot.manifest.problem { fields.append(("problem",.string(problem))) }
                    response = .object(fields)
                default: throw BrowserProtocolError("version","Unknown browser message type.")
                }
            }
            try connection.send(response.encoded(maximumBytes:FrameIO.maximum))
        } catch {
            failed = true
            let fields: [(String,JSON)] = [("type",.string("error")),("code",.string((error as? BrowserProtocolError)?.code ?? "io")),("message",.string(error.localizedDescription))]
            if let bytes = try? JSON.object(fields).encoded(maximumBytes:FrameIO.maximum) { try? connection.send(bytes,closeAfter:true) }
            else { connection.close() }
        }
    }
    private var lossTime: Double {
        max(0,(ProcessInfo.processInfo.systemUptime - (originUptime ?? ProcessInfo.processInfo.systemUptime))*1000)
    }
    func disconnected() {
        guard !completed, let owner else { return }
        try? owner.browserLost(atMs:lossTime)
    }
}
private final class FinishResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void,Error>?
    func store(_ value: Result<Void,Error>) { lock.withLock { result = value } }
    func get() throws { try lock.withLock { try result?.get() } }
}
