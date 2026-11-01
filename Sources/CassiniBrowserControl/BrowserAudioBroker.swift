// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit
import CassiniRecording

public protocol BrowserAudioHandler: Sendable {
    var retainedCaptureIDs: [String] { get }
    func connected(_ connection: BrowserPipeConnection)
    func received(_ data: Data, from connection: BrowserPipeConnection)
    func disconnected(_ peer: BrowserPeer)
}
public struct BrowserAudioStart: Sendable {
    public let captureID: String
    public let timelineOriginMs: Int
    public let microphone: Bool
    public init(captureID: String, timelineOriginMs: Int, microphone: Bool) {
        self.captureID = captureID; self.timelineOriginMs = timelineOriginMs; self.microphone = microphone
    }
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
    private let creating = DispatchGroup()
    private var admissionClosed = false
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
    public var retainedCaptureIDs: [String] {
        lock.withLock { identities.values.compactMap { String(data:$0,encoding:.utf8) } }
    }
    /// Native standalone capture shares the same finalization owner without a
    /// browser reservation. No browser-provided path can enter this API.
    public func ownNative(_ capture: OwnedBrowserCapture) throws {
        try lock.withLock {
            let snapshot = capture.snapshot
            guard !admissionClosed, snapshot.manifest.source == "macos", snapshot.phase == .recording,
                  captures[snapshot.manifest.id] == nil else { throw BrowserIPCError.unavailable }
            captures[snapshot.manifest.id] = capture
        }
    }
    public func closeAdmission() { lock.withLock { admissionClosed = true } }
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
        guard !admissionClosed, reservations[identity] == nil else { lock.unlock(); throw BrowserProtocolError("state","Capture is unavailable or already active.") }
        reservations[identity] = peer; creating.enter(); lock.unlock()
        defer { creating.leave() }
        let capture: OwnedBrowserCapture
        do { capture = try make(title,info.microphone) }
        catch {
            lock.lock(); if reservations[identity] == peer { reservations.removeValue(forKey:identity) }; lock.unlock(); throw error
        }
        capture.setTimelineOrigin(ProcessInfo.processInfo.systemUptime - (Date().timeIntervalSince1970*1000-Double(info.timelineOriginMs))/1000)
        lock.lock(); captures[capture.snapshot.manifest.id] = capture; identities[capture.snapshot.manifest.id] = identity; lock.unlock()
        DispatchQueue.global().async { [created] in if capture.snapshot.phase == .recording { created(capture,info) } }
        return capture
    }
    public func finish(_ capture: OwnedBrowserCapture, problem: String? = nil, reason: CaptureEndReason? = nil, atMs: Double? = nil) async throws {
        if let atMs { guard atMs.isFinite, atMs >= 0 else { throw RecordingError.invalid("Invalid recording stop time.") } }
        if let reason { capture.requestEnd(reason,atMs:atMs) }
        try await finalization.run(capture) { try await self.finishOnce(capture,problem:problem,reason:reason,atMs:atMs) }
    }
    private func finishOnce(_ capture: OwnedBrowserCapture, problem: String?, reason: CaptureEndReason?, atMs: Double?) async throws {
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
        try await capture.finish(problem:problem ?? nativeProblem,reason:reason,atMs:atMs)
    }
    /// App Quit/Stop handles native input shutdown before closing the IPC server.
    /// Browser Stop commands should be sent first so the page can flush its tail.
    @discardableResult public func finishAll(problem: String? = nil, reason: CaptureEndReason? = nil) async -> [OwnedCaptureSnapshot] {
        await withCheckedContinuation { continuation in creating.notify(queue:.global()) { continuation.resume() } }
        let values = activeCaptures
        await withTaskGroup(of:Void.self) { group in
            for capture in values { group.addTask { try? await self.finish(capture,problem:problem,reason:reason) } }
        }
        return values.map(\.snapshot)
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
    /// D52: this connection negotiated source-outcomes-v1.
    private var sourceOutcomes = false
    private var captureID: String?
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
        var packetType: String?, json: JSON = .null
        do {
            guard !data.isEmpty, data.count <= FrameIO.maximum else { throw BrowserProtocolError("framing","Invalid native frame size.") }
            do { json = try JSONParser.parse(data) } catch { throw BrowserProtocolError("framing","Invalid JSON message.") }
            guard let kind = json["type"]?.string, json.object != nil else { throw BrowserProtocolError("framing","Expected a message object.") }
            packetType = kind
            guard ["start","track","audio","stop"].contains(kind) || (sourceOutcomes && ["trackEnd","sources"].contains(kind)) else { throw BrowserProtocolError("version","Unknown browser message type.") }
            // Finalized by a browser Stop, or natively first (the app's own Stop). While saving,
            // a Stop still joins the save so its reply follows the durable metadata.
            let phase = owner?.snapshot.phase
            if sourceOutcomes, owner != nil, kind != "stop", completed || (phase != nil && phase != .recording) {
                throw ScopedRefusal("state","Capture already saved.")
            }
            if sourceOutcomes, let owner, kind == "stop", completed || phase == .saved {
                // A matching Stop after finalization still ACKs; it cannot rewrite the saved meeting.
                guard json["captureId"]?.string == captureID else { throw ScopedRefusal("state","Capture identity does not match.") }
                let summary: [CaptureLedger.Discovered]
                do { summary = try discovered(json["discoveredSources"],required:false) } catch { throw ScopedRefusal("source",error.localizedDescription) }
                guard summary.isEmpty else { throw ScopedRefusal("state","Capture already saved.") }
                completed = true
                try connection.send(JSON.object([("type",.string("stopped")),("path",.string(owner.snapshot.directory.path))]).encoded(maximumBytes:FrameIO.maximum)); return
            }
            guard !completed else { throw BrowserProtocolError("state","Recording is already stopped.") }
            let type = kind
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
                var features: [String] = []
                if let value = json["features"], !value.isNull {
                    guard let list = value.array, list.count <= 8 else { throw BrowserProtocolError("version","Invalid recording features.") }
                    for item in list {
                        guard let feature = item.string, feature.unicodeScalars.count <= 64, !features.contains(feature) else { throw BrowserProtocolError("version","Invalid recording features.") }
                        features.append(feature)
                    }
                }
                guard let broker else { throw BrowserProtocolError("io","Recording broker is unavailable.") }
                let capture = try broker.begin(.init(captureID:id,timelineOriginMs:origin,microphone:mic),title:try string(json,"title",optional:true) ?? "Browser recording",peer:connection.peer.id)
                originUptime = ProcessInfo.processInfo.systemUptime - (Date().timeIntervalSince1970*1000 - Double(origin))/1000
                owner = capture; captureID = id
                var fields: [(String,JSON)] = [("type",.string("started")),("path",.string(capture.snapshot.directory.path))]
                if features.contains("source-outcomes-v1") {
                    capture.enableSourceOutcomes(); sourceOutcomes = true
                    fields.append(("features",.array([.string("source-outcomes-v1")])))
                }
                response = .object(fields)
            } else {
                guard let owner else { throw BrowserProtocolError("state","No active recording.") }
                switch type {
                case "track":
                    try owner.browserTrack(id:string(json,"id")!,label:string(json,"label",optional:true) ?? string(json,"kind")!,kind:string(json,"kind")!,sampleRate:integer(json["sampleRate"]),channels:integer(json["channels"]),
                                           sourceTrackId:sourceOutcomes || json["sourceTrackId"]?.isNull == false ? string(json,"sourceTrackId",optional:true) : nil)
                case "trackEnd":
                    let id = try string(json,"id")!, reason = try string(json,"reason")!
                    let dropped = try integer(json["droppedFrames"])
                    guard dropped <= 2147483629 else { throw BrowserProtocolError("source","Invalid dropped frame count.") }
                    guard let end = json["endOffsetMs"], end.isNull || end.double.map({ $0.isFinite && (0...86460000).contains($0) }) == true else { throw BrowserProtocolError("source","Invalid source end time.") }
                    try owner.trackEnd(id:id,reason:reason,droppedFrames:UInt64(dropped))
                case "sources":
                    try owner.discover(try discovered(json["discoveredSources"],required:true))
                case "audio":
                    let id = try string(json,"id")!, sequence = try integer(json["sequence"],code:"sequence")
                    guard let encoded = try string(json,"pcm",code:"chunk"), encoded.utf8.count <= 349528,
                          let pcm = Data(base64Encoded:encoded), let offset = json["offsetMs"]?.double, offset.isFinite else { throw BrowserProtocolError("chunk","Invalid audio chunk.") }
                    try owner.browserAudio(id:id,sequence:sequence,offsetMs:offset,pcm:pcm)
                case "stop":
                    if sourceOutcomes {
                        // A mismatched negotiated Stop is refused without ending this capture.
                        guard json["captureId"]?.string == captureID else { throw ScopedRefusal("state","Capture identity does not match.") }
                        let summary = try discovered(json["discoveredSources"],required:false)
                        if !summary.isEmpty { try owner.discover(summary) }
                    }
                    let reason = try string(json,"failureReason",optional:true), problem = try string(json,"problem",optional:true)
                    guard reason == nil || reason == "lost" else { throw BrowserProtocolError("source","Invalid failure reason.") }
                    let terminal = try string(json,"reason",optional:true)
                    guard terminal == nil || terminal.flatMap(CaptureEndReason.init(rawValue:)) != nil else { throw BrowserProtocolError("source","Invalid recording end reason.") }
                    if reason == "lost" { try owner.browserLost(atMs:lossTime) }
                    else if let broker {
                        let stopAt = lossTime, endReason = terminal.flatMap(CaptureEndReason.init(rawValue:)) ?? .user
                        owner.requestEnd(endReason,atMs:stopAt)
                        let done = DispatchSemaphore(value:0), outcome = FinishResult()
                        Task {
                            do { try await broker.finish(owner,problem:problem,reason:endReason,atMs:stopAt); outcome.store(.success(())) }
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
            if sourceOutcomes, let refusal = scoped(error,type:packetType,json:json),
               let bytes = try? refusal.encoded(maximumBytes:FrameIO.maximum) {
                do { try connection.send(bytes); return } catch {}
            }
            failed = true
            let fields: [(String,JSON)] = [("type",.string("error")),("code",.string((error as? BrowserProtocolError)?.code ?? "io")),("message",.string(error.localizedDescription))]
            if let bytes = try? JSON.object(fields).encoded(maximumBytes:FrameIO.maximum) { try? connection.send(bytes,closeAfter:true) }
            else { connection.close() }
        }
    }
    /// D52: classify a refusal so only that source or command fails; framing,
    /// version and connection failures stay session failures.
    private func scoped(_ error: Error, type: String?, json: JSON) -> JSON? {
        let code = (error as? BrowserProtocolError)?.code ?? (error as? ScopedRefusal)?.code ?? (error as? KeptSourceRefusal)?.code ?? "io"
        func reply(_ scope: String, id: String? = nil, retired: Bool = false) -> JSON {
            var fields: [(String,JSON)] = [("type",.string("error")),("code",.string(code)),("message",.string(error.localizedDescription)),("scope",.string(scope))]
            if let id { fields.append(("id",.string(id))) }
            if retired { fields.append(("retired",.bool(true))) }
            return .object(fields)
        }
        if error is ScopedRefusal { return reply("command") }
        guard let type, !["framing","version"].contains(code) else { return nil }
        if code == "state", completed || owner?.snapshot.phase != .recording { return reply("command") }
        if type == "sources", error is BrowserProtocolError { return reply("command") }
        guard ["track","audio","trackEnd"].contains(type), let owner else { return nil }
        // An id outside the protocol bounds is neither echoed nor acted on.
        guard let id = json["id"]?.string, CaptureLedger.validIdentity(id) else { return reply("source") }
        // An overlap, conflicting re-declaration or suspension gap leaves the span and source as they are.
        if error is KeptSourceRefusal { return reply("source",id:id) }
        let retired = owner.refuseSource(id:id,code:code)
        return reply("source",id:id,retired:retired && code == "state")
    }
    private func discovered(_ value: JSON?, required: Bool) throws -> [CaptureLedger.Discovered] {
        guard let value, !value.isNull else {
            if required { throw BrowserProtocolError("source","Invalid discovered audio sources.") }; return []
        }
        guard let rows = value.array, !required || !rows.isEmpty else { throw BrowserProtocolError("source","Invalid discovered audio sources.") }
        return try rows.map { row in
            guard row.object != nil, let id = row["sourceTrackId"]?.string, CaptureLedger.validIdentity(id), let kind = row["kind"]?.string,
                  CaptureLedger.discoverableKinds.contains(kind) else { throw BrowserProtocolError("source","Invalid discovered audio source.") }
            var label: String?
            if let value = row["label"], !value.isNull {
                guard let text = value.string, text.unicodeScalars.count <= 200 else { throw BrowserProtocolError("source","Invalid discovered audio source label.") }; label = text
            }
            var failed = false
            if let value = row["failed"], !value.isNull { guard let flag = value.bool else { throw BrowserProtocolError("source","Invalid discovered audio source.") }; failed = flag }
            return .init(sourceTrackId:id,kind:kind,label:label,failed:failed)
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
/// A negotiated command refusal that leaves the capture and connection running.
private struct ScopedRefusal: LocalizedError {
    let code: String, message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var errorDescription: String? { message }
}
private final class FinishResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void,Error>?
    func store(_ value: Result<Void,Error>) { lock.withLock { result = value } }
    func get() throws { try lock.withLock { try result?.get() } }
}
