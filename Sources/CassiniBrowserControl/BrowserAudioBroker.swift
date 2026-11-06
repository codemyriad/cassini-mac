// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit
import CassiniRecording

public protocol BrowserAudioHandler: Sendable {
    var retainedCaptureIDs: [String] { get }
    func connected(_ connection: BrowserPipeConnection)
    func received(_ data: Data, from connection: BrowserPipeConnection)
    func disconnected(_ peer: BrowserPeer)
    /// D57: a control status reported this capture's page state and documentGeneration.
    func documentChanged(captureID: String, page: BrowserCallLifecycle.Page?, documentGeneration: String?)
}
public extension BrowserAudioHandler {
    func documentChanged(captureID: String, page: BrowserCallLifecycle.Page?, documentGeneration: String?) {}
}
public struct BrowserAudioStart: Sendable {
    public let captureID: String
    public let timelineOriginMs: Int
    public let microphone: Bool
    /// The call the Start names (D52.5: its identity), recorded before the app hears of it.
    public let callGeneration: String?
    public init(captureID: String, timelineOriginMs: Int, microphone: Bool, callGeneration: String? = nil) {
        self.captureID = captureID; self.timelineOriginMs = timelineOriginMs; self.microphone = microphone; self.callGeneration = callGeneration
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
    /// D52.1 R67: native stand-ins a selected call may resume, by capture identity.
    /// D58 #10 (protocol #37): an unanswered resume ask, by its control requestId and the
    /// session time it was asked at. The first answer (its own refused result, or the native
    /// refusal carrying its id) records it once; an attach or a Stop forgets it silently.
    private struct ResumeAsk { let id: Data; let atMs: Double }
    private struct StandIn { let capture: UUID; let origin: Int; var expected: String?; var asks: [ResumeAsk] = [] }
    /// GNOME keeps 8 as well: the oldest unanswered ask past it is forgotten and records nothing.
    static let resumeAskLimit = 8
    private var standIns: [Data:StandIn] = [:]
    private let finalization = CaptureFinalization()
    private let creating = DispatchGroup()
    private var admissionClosed = false
    private let make: @Sendable (String,Bool) throws -> OwnedBrowserCapture
    private let created: @Sendable (OwnedBrowserCapture,BrowserAudioStart) -> Void
    private let stopNative: BrowserNativeStop
    private let persistRecord: @Sendable (RecordingManifest,URL) throws -> Void
    /// Observes each audio transport's end after the broker has applied it (the owner's loss
    /// and the stand-in identity), so a caller can wait on it instead of polling.
    fileprivate let transportClosed: @Sendable () -> Void
    /// D52.5: fed synchronously with each transport loss and resume (see CallOwnership).
    fileprivate let ownership: CallOwnershipStore?
    private var recordAttempts: [UUID:Int] = [:]
    static let recordAttemptLimit = 5
    /// D52.4 PCM_STALE_AFTER, 45 s per D52.5: the extension's longest source retry (30 s)
    /// plus its 10 s acknowledgement limit, with margin, and below the 60 s span cut.
    public static let pcmStaleAfter = AudioTransportWatchdog.staleAfter
    fileprivate let clock: @Sendable () -> UInt64
    private var watchdog: DispatchSourceTimer?
    public init(make: @escaping @Sendable (String,Bool) throws -> OwnedBrowserCapture,
                created: @escaping @Sendable (OwnedBrowserCapture,BrowserAudioStart) -> Void,
                stopNative: @escaping BrowserNativeStop,
                persistRecord: @escaping @Sendable (RecordingManifest,URL) throws -> Void = { try CaptureRecordWriter.write($0,directory:$1) },
                clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds / 1_000_000 },
                transportClosed: @escaping @Sendable () -> Void = {}, ownership: CallOwnershipStore? = nil) {
        self.make = make; self.created = created; self.stopNative = stopNative; self.persistRecord = persistRecord; self.clock = clock
        self.transportClosed = transportClosed; self.ownership = ownership
        let timer = DispatchSource.makeTimerSource(queue:.global(qos:.utility))
        timer.schedule(deadline:.now() + 1,repeating:1)
        timer.setEventHandler { [weak self] in self?.closeStaleTransports() }
        timer.resume(); watchdog = timer
    }
    deinit { watchdog?.cancel() }
    /// Re-evaluated every second: closes each audio transport whose open, PCM-delivering
    /// span has had no frame for PCM_STALE_AFTER. Closing takes the ordinary EOF path, so
    /// the recording keeps running and falls back to computer sound (D52.4 Q3).
    public func closeStaleTransports() {
        let now = clock()
        let stale = lock.withLock { peers.values.filter { $0.isStale(at:now) } }
        for peer in stale { peer.closeStale() }
    }
    /// D57: the recording's control status, fed as it arrives. A transport whose status
    /// arrives after its PCM_STALE_AFTER deadline closes through the EOF path.
    public func documentChanged(captureID: String, page: BrowserCallLifecycle.Page?, documentGeneration: String?) {
        let now = clock()
        let matching = lock.withLock { peers.values.filter { $0.watches(captureID) } }
        for peer in matching where !peer.document(page:page,generation:documentGeneration,at:now) { peer.closeStale() }
    }
    public var activeCaptures: [OwnedBrowserCapture] {
        lock.lock(); defer { lock.unlock() }; return Array(captures.values)
    }
    /// Every capture identity this app still owns: browser captures and active native
    /// stand-ins (a resumed stand-in keeps its identity, so after a browser restart the
    /// registry knows the recovered call is already being recorded).
    public var retainedCaptureIDs: [String] {
        lock.withLock { (Array(identities.values) + Array(standIns.keys)).compactMap { String(data:$0,encoding:.utf8) } }
    }
    /// Native standalone capture shares the same finalization owner without a
    /// browser reservation. No browser-provided path can enter this API.
    public func ownNative(_ capture: OwnedBrowserCapture, timelineOriginMs: Int? = nil, standInID: String? = nil) throws {
        try lock.withLock {
            let snapshot = capture.snapshot
            guard !admissionClosed, snapshot.manifest.source == "macos", snapshot.phase == .recording,
                  captures[snapshot.manifest.id] == nil else { throw BrowserIPCError.unavailable }
            let identity = standInID ?? "native-"+snapshot.manifest.id.uuidString.lowercased()
            guard !identity.isEmpty, identity.utf8.count <= 128 else { throw BrowserIPCError.unavailable }
            captures[snapshot.manifest.id] = capture
            if let timelineOriginMs, (0...253402300799000).contains(timelineOriginMs) {
                standIns[Data(identity.utf8)] = .init(capture:snapshot.manifest.id,origin:timelineOriginMs,expected:nil)
            }
        }
    }
    /// The identity and origin a resume command must name for this native stand-in.
    public func standInIdentity(_ capture: OwnedBrowserCapture) -> (captureID: String, timelineOriginMs: Int)? {
        lock.withLock {
            standIns.first { $0.value.capture == capture.snapshot.manifest.id }.flatMap { entry in
                String(data:entry.key,encoding:.utf8).map { ($0,entry.value.origin) }
            }
        }
    }
    /// Arm exactly one resume for the call generation the app selected; nil disarms
    /// it (Stop, call change) and forgets its unanswered asks. A resume that was not
    /// armed is refused. `ask` is the resume command's requestId and session time.
    public func expectResume(_ capture: OwnedBrowserCapture, callGeneration: String?, ask: (requestID: String, atMs: Double)? = nil) {
        lock.withLock {
            guard let key = standIns.first(where:{ $0.value.capture == capture.snapshot.manifest.id })?.key else { return }
            standIns[key]?.expected = callGeneration
            if callGeneration == nil { standIns[key]?.asks = [] }
            else if let ask {
                standIns[key]?.asks.append(.init(id:Data(ask.requestID.utf8),atMs:ask.atMs))
                if let count = standIns[key]?.asks.count, count > Self.resumeAskLimit { standIns[key]?.asks.removeFirst(count - Self.resumeAskLimit) }
            }
        }
    }
    /// D58 #10: the outcome of a resume ask. Only a browser ok:false answer records; its result
    /// code, if any, is the message (R82 1b). A closed connection or a local failure records
    /// nothing, and a late, duplicate or unknown answer records nothing either. A timeout is the
    /// app no longer waiting (protocol 08ad6f6 `forget`): the ask is dropped, so its late native
    /// refusal records nothing; a closed connection's ask stays answerable by its own refusal.
    public func resumeAnswered(_ outcome: BrowserControlOutcome) {
        guard outcome.resume, !outcome.ok else { return }
        if outcome.failure == "timeout" { forgetAsk(Data(outcome.requestID.utf8)); return }
        guard outcome.failure == nil else { return }
        refuseAsk(Data(outcome.requestID.utf8),message:outcome.code)
    }
    private func forgetAsk(_ id: Data) {
        lock.withLock { for key in Array(standIns.keys) { standIns[key]?.asks.removeAll { $0.id == id } } }
    }
    /// Unanswered resume asks of a stand-in, oldest first (tests).
    func pendingResumeAsks(_ capture: OwnedBrowserCapture) -> [String] {
        lock.withLock {
            standIns.values.first { $0.capture == capture.snapshot.manifest.id }?.asks.compactMap { String(data:$0.id,encoding:.utf8) } ?? []
        }
    }
    /// Records `startRejected/resumeRefused` at the ask's own time, in the recording it asked to
    /// join, once. The refusal is written after the broker lock is released, on the recording's
    /// own queue: a slow Library disk never blocks the caller (the main actor, #120 review).
    fileprivate func refuseAsk(_ id: Data, message: String?) {
        let target: (OwnedBrowserCapture,Double)? = lock.withLock {
            for (key,var standIn) in standIns {
                guard let index = standIn.asks.firstIndex(where:{ $0.id == id }) else { continue }
                let ask = standIn.asks.remove(at:index); standIns[key] = standIn
                return captures[standIn.capture].map { ($0,ask.atMs) }
            }
            return nil
        }
        guard let (capture,atMs) = target,
              let entry = CaptureRefusal(atMs:atMs,side:"browser",code:CaptureRefusal.startRejected,detail:"resumeRefused",message:message) else { return }
        capture.refuseLater(entry)
    }
    fileprivate func resume(captureID: String, timelineOriginMs: Int, callGeneration: String, peer: UUID) throws -> OwnedBrowserCapture {
        let identity = Data(captureID.utf8)
        let capture: OwnedBrowserCapture = try lock.withLock {
            guard !admissionClosed, let standIn = standIns[identity], let capture = captures[standIn.capture],
                  standIn.origin == timelineOriginMs, standIn.expected.map({ Data($0.utf8) == Data(callGeneration.utf8) }) == true,
                  reservations[identity] == nil else { throw BrowserProtocolError("state","The recording cannot be resumed.") }
            reservations[identity] = peer
            return capture
        }
        do { try capture.attachResumedBrowser() }
        catch { lock.withLock { if reservations[identity] == peer { reservations.removeValue(forKey:identity) } }; throw error }
        ownership?.update { $0.transportResumed(capture.snapshot.manifest.id) }
        lock.withLock { standIns[identity]?.expected = nil; standIns[identity]?.asks = [] } // The attach answers every ask.
        return capture
    }
    /// D52.4: once its audio transport closed, a browser recording is a resume target under
    /// its own capture identity and origin (attachResumedBrowser admits only system/lost).
    /// Its identity stays taken: a fresh Start reusing it is still refused.
    fileprivate func transportLost(_ capture: OwnedBrowserCapture, captureID: String, timelineOriginMs: Int, peer: UUID) {
        lock.withLock {
            let id = capture.snapshot.manifest.id, identity = Data(captureID.utf8)
            guard captures[id] === capture, identities[id] == identity, standIns[identity] == nil,
                  (0...253402300799000).contains(timelineOriginMs) else { return }
            standIns[identity] = .init(capture:id,origin:timelineOriginMs,expected:nil)
            if reservations[identity] == peer { reservations.removeValue(forKey:identity) }
        }
    }
    /// A failed or ended resumed transport releases its claim; the stand-in keeps recording.
    fileprivate func releaseResume(captureID: String, peer: UUID) {
        lock.withLock { let identity = Data(captureID.utf8); if reservations[identity] == peer, standIns[identity] != nil { reservations.removeValue(forKey:identity) } }
    }
    public func closeAdmission() { lock.withLock { admissionClosed = true } }
    public func connected(_ connection: BrowserPipeConnection) {
        guard connection.peer.role == .audio else { connection.close(); return }
        lock.lock(); defer { lock.unlock() }
        guard peers.count < 100, peers[connection.peer.id] == nil else { connection.close(); return }
        peers[connection.peer.id] = AudioPeer(connection:connection,broker:self,clock:clock)
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
        guard !admissionClosed, reservations[identity] == nil, standIns[identity] == nil else { lock.unlock(); throw BrowserProtocolError("state","Capture is unavailable or already active.") }
        reservations[identity] = peer; creating.enter(); lock.unlock()
        defer { creating.leave() }
        let capture: OwnedBrowserCapture
        do { capture = try make(title,info.microphone) }
        catch {
            lock.lock(); if reservations[identity] == peer { reservations.removeValue(forKey:identity) }; lock.unlock(); throw error
        }
        capture.setTimelineOrigin(ProcessInfo.processInfo.systemUptime - (Date().timeIntervalSince1970*1000-Double(info.timelineOriginMs))/1000)
        lock.lock(); captures[capture.snapshot.manifest.id] = capture; identities[capture.snapshot.manifest.id] = identity; lock.unlock()
        // The recording holds its call before anyone hears of it (No second recording).
        if let generation = info.callGeneration { ownership?.update { $0.started(capture.snapshot.manifest.id,callGeneration:generation) } }
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
        let id = capture.snapshot.manifest.id
        let attempts = lock.withLock { recordAttempts[id, default:0] }
        // D52.1 R65: the portable record is written before the capture is saved. A failed write
        // keeps it saving and owned (retryPendingRecords) for a bounded number of attempts.
        let persist = attempts < Self.recordAttemptLimit ? persistRecord : nil
        do {
            try await capture.finish(problem:problem ?? nativeProblem,reason:reason,atMs:atMs,persist:persist)
        } catch where capture.recordPending {
            lock.withLock { recordAttempts[id] = attempts + 1 }
            throw error
        } catch { release(id); throw error }
        release(id)
    }
    private func release(_ id: UUID) {
        lock.withLock {
            captures.removeValue(forKey:id); recordAttempts.removeValue(forKey:id)
            if let identity = identities.removeValue(forKey:id) { reservations.removeValue(forKey:identity) }
            for (identity,standIn) in standIns where standIn.capture == id { standIns.removeValue(forKey:identity); reservations.removeValue(forKey:identity) }
        }
    }
    /// Retries the portable record of captures whose audio is saved but whose record write
    /// failed; after the attempt limit the capture is saved without it.
    public func retryPendingRecords() async {
        // Copy the references under the lock; the pending state is read from each capture's
        // cached snapshot after releasing it, so a stalled disk never holds the broker lock.
        let (owned,observe) = lock.withLock { (Array(captures.values),retryScanObserver) }
        for capture in owned where capture.snapshot.recordPending {
            // Test observation point: the pending state was read and the lock released;
            // finalization has not been awaited yet.
            observe?(capture)
            try? await finish(capture)
        }
    }
    private var retryScanObserver: (@Sendable (OwnedBrowserCapture) -> Void)?
    /// Tests only: called by `retryPendingRecords` after it read a capture's pending state
    /// and released the broker lock, before it awaits that capture's finalization.
    func observeRetryScan(_ observer: (@Sendable (OwnedBrowserCapture) -> Void)?) { lock.withLock { retryScanObserver = observer } }
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
    private var resumed = false
    private var timelineOriginMs: Int?
    /// PCM_STALE_AFTER for this transport (D52.5: every frame on it counts).
    private let liveness = NSLock()
    private let clock: @Sendable () -> UInt64
    private var watchdog = AudioTransportWatchdog()
    init(connection: BrowserPipeConnection, broker: BrowserAudioBroker, clock: @escaping @Sendable () -> UInt64) {
        self.connection = connection; self.broker = broker; self.clock = clock
    }
    /// The capture this transport carries, readable from the control queue.
    private var watched: Data?
    func isStale(at now: UInt64) -> Bool { liveness.withLock { watchdog.isStale(at:now) } }
    func watches(_ id: String) -> Bool { liveness.withLock { watched == Data(id.utf8) } }
    func document(page: BrowserCallLifecycle.Page?, generation: String?, at now: UInt64) -> Bool {
        liveness.withLock { watchdog.document(page:page,generation:generation,at:now) }
    }
    private func watch(_ id: String) { liveness.withLock { watched = Data(id.utf8) } }
    func closeStale() { connection.close() }
    private func accepted(_ frame: AudioTransportWatchdog.Frame) { liveness.withLock { watchdog.apply(frame) } }
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
        // Set once the host accepted the frame: a later failure (writing the reply) is the
        // connection's, never a refusal of the source that sent it.
        var acceptedFrame = false
        do {
            guard !data.isEmpty, data.count <= FrameIO.maximum else { throw BrowserProtocolError("framing","Invalid native frame size.") }
            do { json = try JSONParser.parse(data) } catch { throw BrowserProtocolError("framing","Invalid JSON message.") }
            guard let kind = json["type"]?.string, json.object != nil else { throw BrowserProtocolError("framing","Expected a message object.") }
            packetType = kind
            let frameID = json["id"]?.string ?? ""
            let frame: AudioTransportWatchdog.Frame = switch kind {
            case "track": .track(frameID,generation:json["documentGeneration"]?.string)
            case "audio": .audio(frameID)
            case "trackEnd": .trackEnd(frameID)
            case "stop": .stop
            default: .other
            }
            // Every frame is activity; a frame at or after the PCM_STALE_AFTER deadline is too
            // late: close instead. Its span transition applies only once the host accepts it.
            guard liveness.withLock({ watchdog.activity(at:clock()) }) else { closeStale(); return }
            guard ["start","resume","track","audio","stop"].contains(kind) || (sourceOutcomes && ["trackEnd","sources"].contains(kind)) else { throw BrowserProtocolError("version","Unknown browser message type.") }
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
                completed = true; accepted(frame); acceptedFrame = true
                try connection.send(JSON.object([("type",.string("stopped")),("path",.string(owner.snapshot.directory.path))]).encoded(maximumBytes:FrameIO.maximum)); return
            }
            guard !completed else { throw BrowserProtocolError("state","Recording is already stopped.") }
            let type = kind
            var response: JSON = .object([("type",.string("ack"))])
            if type == "resume" {
                // Protocol #37: the resume command's requestId. A refusal is booked only on the
                // unanswered ask it names; one outside the control requestId domain is refused.
                var ask: Data?
                if let value = json["requestId"] {
                    if let number = value.int, (0...9007199254740991).contains(number) {}  // Mac asks use string ids.
                    else if let text = value.string, !text.isEmpty, text.unicodeScalars.count <= 128 { ask = Data(text.utf8) }
                    else { throw BrowserProtocolError("source","Invalid resume request.") }
                }
                do {
                    // D52.1 R67: join the exact active native stand-in. Every check precedes
                    // any change; a refusal closes only this transport and creates nothing.
                    guard owner == nil else { throw BrowserProtocolError("state","Recording has already started.") }
                    guard try integer(json["version"],code:"version") == 1 else { throw BrowserProtocolError("version","Unsupported protocol version.") }
                    guard json["independent"]?.bool == true else { throw BrowserProtocolError("source","Independent capture is required.") }
                    let id = try string(json,"captureId")!, generation = try string(json,"callGeneration")!
                    guard !id.isEmpty, id.utf8.count <= 128, !generation.isEmpty, generation.unicodeScalars.count <= 200 else { throw BrowserProtocolError("source","Invalid capture identity.") }
                    let origin = try integer(json["timelineOriginMs"])
                    guard origin <= 253402300799000 else { throw BrowserProtocolError("source","Invalid capture origin.") }
                    guard let list = json["features"]?.array, list.count <= 8 else { throw BrowserProtocolError("version","Invalid recording features.") }
                    var features: [String] = []
                    for item in list {
                        guard let feature = item.string, feature.unicodeScalars.count <= 64, !features.contains(feature) else { throw BrowserProtocolError("version","Invalid recording features.") }
                        features.append(feature)
                    }
                    guard features.contains("resume-capture-v1") else { throw BrowserProtocolError("version","Resume requires resume-capture-v1.") }
                    guard let broker else { throw BrowserProtocolError("io","Recording broker is unavailable.") }
                    let capture = try broker.resume(captureID:id,timelineOriginMs:origin,callGeneration:generation,peer:connection.peer.id)
                    originUptime = ProcessInfo.processInfo.systemUptime - (Date().timeIntervalSince1970*1000 - Double(origin))/1000
                    owner = capture; captureID = id; resumed = true; watch(id)
                    var granted = ["resume-capture-v1"]
                    if features.contains("source-outcomes-v1") { capture.enableSourceOutcomes(); sourceOutcomes = capture.sourceOutcomesEnabled }
                    if sourceOutcomes { granted.insert("source-outcomes-v1",at:0) }
                    response = .object([("type",.string("started")),("path",.string(capture.snapshot.directory.path)),("features",.array(granted.map { .string($0) })),
                                        ("resumed",.bool(true)),("captureId",.string(id)),("timelineOriginMs",.number(String(origin))),("callGeneration",.string(generation))])
                } catch {
                    if let ask { broker?.refuseAsk(ask,message:(error as? BrowserProtocolError)?.message ?? error.localizedDescription) }
                    throw error
                }
            } else if type == "start" {
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
                // The call this Start names: the recording holds it from its first moment, even if
                // its audio closes before any status tells the app its tab.
                let generation = json["callGeneration"]?.string.flatMap { !$0.isEmpty && $0.unicodeScalars.count <= 200 ? $0 : nil }
                let capture = try broker.begin(.init(captureID:id,timelineOriginMs:origin,microphone:mic,callGeneration:generation),title:try string(json,"title",optional:true) ?? "Browser recording",peer:connection.peer.id)
                originUptime = ProcessInfo.processInfo.systemUptime - (Date().timeIntervalSince1970*1000 - Double(origin))/1000
                owner = capture; captureID = id; timelineOriginMs = origin; watch(id)
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
                    // D61: clock facts copied as received; documentGeneration only feeds the watchdog.
                    try owner.browserTrack(id:string(json,"id")!,label:string(json,"label",optional:true) ?? string(json,"kind")!,kind:string(json,"kind")!,sampleRate:integer(json["sampleRate"]),channels:integer(json["channels"]),
                                           sourceTrackId:sourceOutcomes || json["sourceTrackId"]?.isNull == false ? string(json,"sourceTrackId",optional:true) : nil,
                                           clock:ClockFacts.parse(json))
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
                    // A valid Stop ends every span now: the save below may take longer than
                    // PCM_STALE_AFTER and must not let the watchdog close the pipe under it.
                    accepted(frame)
                    if reason == "lost" {
                        try owner.browserLost(atMs:lossTime)
                        // The recording runs on in its fallback. Like an EOF, this loss makes it a
                        // resume target now: the app may ask before the extension closes the pipe.
                        registerLoss()
                    }
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
                    // D69.2: the extension shows this text; the stored D69 writer sentence is never shown.
                    if let problem = owner.snapshot.manifest.stoppedProblem {
                        fields.append(("problem",.string(problem)))
                    }
                    response = .object(fields)
                default: throw BrowserProtocolError("version","Unknown browser message type.")
                }
            }
            accepted(frame); acceptedFrame = true
            try connection.send(response.encoded(maximumBytes:FrameIO.maximum))
        } catch {
            if !acceptedFrame, sourceOutcomes, let refusal = scoped(error,type:packetType,json:json),
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
        // An overlap, conflicting re-declaration or suspension gap leaves the span and source as
        // they are, and so does any refused re-declaration of an id that is still live.
        if error is KeptSourceRefusal || (type == "track" && owner.isLive(id)) { return reply("source",id:id) }
        let retired = owner.refuseSource(id:id,code:code)
        // The owner closed this span for good; it never arms the stale watchdog again.
        if owner.isRetired(id) { liveness.withLock { watchdog.retire(id) } }
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
        defer { broker?.transportClosed() }
        if resumed, let captureID { broker?.releaseResume(captureID:captureID,peer:connection.peer.id) }
        guard !completed, let owner else { return }
        // A resumed transport's EOF keeps the native recording and its fallback (D33).
        try? owner.browserLost(atMs:lossTime)
        registerLoss()
    }
    /// D52.4: after an EOF or a loss Stop the call may resume this recording onto its system/lost
    /// fallback. A fresh capture becomes a resume target under its own identity; a resumed
    /// transport releases its claim so the stand-in can be resumed again. Idempotent.
    private func registerLoss() {
        guard let owner, let captureID else { return }
        // Before anything else can observe the loss: the control service reads it at admission.
        broker?.ownership?.update { $0.transportLost(owner.snapshot.manifest.id) }
        if resumed { broker?.releaseResume(captureID:captureID,peer:connection.peer.id) }
        else if let timelineOriginMs { broker?.transportLost(owner,captureID:captureID,timelineOriginMs:timelineOriginMs,peer:connection.peer.id) }
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
