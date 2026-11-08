// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

/// Owns only browser management. Each audio session will have a separate owner;
/// closing this service never sends Stop or finalizes an audio writer.
public final class BrowserControlService: @unchecked Sendable {
    private let queue = DispatchQueue(label:"io.codemyriad.cassini.control-state")
    private let key = DispatchSpecificKey<UInt8>()
    private var server: BrowserPipeServer?
    private var timer: DispatchSourceTimer?
    private var registry = BrowserControlRegistry()
    private var connections: [UUID:BrowserPipeConnection] = [:]
    private var heartbeats: [UUID:ControlHeartbeat] = [:]
    private let clock: @Sendable () -> UInt64
    private var deadlines: [String:(BrowserControlRequest,UInt64)] = [:]
    private var automatic: Set<String> = []
    private var autoRecord = false, microphone = true
    private var signals = SignalCallPolicy()
    private var signalStopSent: UUID?
    private var signalInput: BrowserSignalInputGate?
    private let signalAction: @Sendable (BrowserSignalAction) -> Void
    private let changed: @Sendable ([BrowserControlPeerSnapshot]) -> Void
    private let audio: (any BrowserAudioHandler)?
    private let completed: @Sendable (BrowserControlOutcome,Bool) -> Void
    private let canStart: @Sendable () -> Bool
    private let canSignalStart: @Sendable () -> Bool
    /// Observes each control frame's type after the service has applied it (heartbeat
    /// liveness included), so a caller can wait on receipt instead of polling.
    private let received: @Sendable (String?) -> Void
    /// D52.5: which calls a recording waits to resume; read on this queue before any Start.
    private let ownership: CallOwnershipStore?
    public init(changed: @escaping @Sendable ([BrowserControlPeerSnapshot]) -> Void,
                completed: @escaping @Sendable (BrowserControlOutcome,Bool) -> Void, audio: (any BrowserAudioHandler)? = nil,
                canStart: @escaping @Sendable () -> Bool = { true },
                clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds / 1_000_000 },
                received: @escaping @Sendable (String?) -> Void = { _ in }, ownership: CallOwnershipStore? = nil,
                requireMultiStream: Bool = false,
                allowAutomaticBrowserStarts: Bool = true,
                signalAction: @escaping @Sendable (BrowserSignalAction) -> Void = { _ in },
                canSignalStart: @escaping @Sendable () -> Bool = { true }) {
        self.canSignalStart = canSignalStart
        self.signalAction = signalAction
        self.changed = changed; self.completed = completed; self.audio = audio; self.canStart = canStart; self.clock = clock; self.received = received
        self.ownership = ownership; registry.requireMultiStream = requireMultiStream
        registry.allowAutomaticBrowserStarts = allowAutomaticBrowserStarts
        queue.setSpecific(key:key,value:1)
    }
    public func start(root: URL = BrowserPipeServer.standardRoot) throws {
        try sync {
            guard server == nil else { throw BrowserIPCError.unavailable }
            let transport = BrowserPipeServer(root:root,connected:{ [weak self] connection in
                if connection.peer.role == .audio { self?.audio?.connected(connection); if self?.audio == nil { connection.close() } }
                else { self?.queue.async { [weak self] in self?.connect(connection) } }
            },received:{ [weak self] connection,data in
                if connection.peer.role == .audio { self?.audio?.received(data,from:connection) }
                else { self?.queue.async { [weak self] in self?.receive(data,from:connection) } }
            },disconnected:{ [weak self] peer in
                if peer.role == .audio { self?.audio?.disconnected(peer) }
                else { self?.queue.async { [weak self] in self?.disconnect(peer.id) } }
            })
            try transport.start(); server = transport
            let source = DispatchSource.makeTimerSource(queue:queue)
            source.schedule(deadline:.now() + .seconds(1),repeating:.seconds(1))
            source.setEventHandler { [weak self] in self?.expire() }
            timer = source; source.resume()
        }
    }
    public func setAutoRecord(_ enabled: Bool, microphone: Bool) {
        queue.async { [self] in autoRecord = enabled; self.microphone = microphone; reconcile() }
    }
    public func recordAll(microphone: Bool, choices: [BrowserMeetingKey:Bool] = [:], issued: @escaping @Sendable ([BrowserControlRequest]) -> Void = { _ in }) {
        queue.async { [self] in
            guard canStart() else { issued([]); return }
            refreshLostCalls()
            let requests = registry.startAll(microphone:microphone,choices:choices)
            send(requests); publish(); issued(requests)
        }
    }
    public func reloadMeetingTab(_ key: BrowserMeetingKey) {
        queue.async { [self] in
            do {
                guard connections[key.peer] != nil else { throw BrowserControlStateError.unavailable }
                let request = try registry.reloadTab(key)
                // A failed write must also complete the repair request, not leave its UI pending.
                deadlines[request.id] = (request,DispatchTime.now().uptimeNanoseconds+30_000_000_000)
                send([request]); publish()
            }
            catch { completed(.init(requestID:"",key:key,action:.reloadTab,ok:false,error:nil,failure:"unavailable"),false) }
        }
    }
    public func recordMeeting(_ key: BrowserMeetingKey, microphone: Bool) {
        queue.async { [self] in
            do {
                guard canStart() else { throw BrowserIPCError.unavailable }
                refreshLostCalls()
                send([try registry.start(key,microphone:microphone)]); publish()
            }
            catch { completed(.init(requestID:UUID().uuidString,key:key,action:.start,ok:false,error:nil,failure:BrowserControlOutcome.localFailure(error)),false) }
        }
    }
    /// D52.1 R67: ask the extension to join a native stand-in. `armed` receives the
    /// selected call generation and the ask's fresh requestId before the command is
    /// sent, so the native resume can be validated and its refusal booked on this ask
    /// alone (D58 #10, protocol #37); a failure is reported and never retried as a fresh Start.
    /// The owner queue hands the committed reference to this queue synchronously.
    /// Keep `armed` nonblocking: it may arm the broker and publish asynchronously,
    /// but must not synchronously call the owner or request its Stop.
    /// `expectedGeneration`: the call the caller judged (a lost recording's own call); a tab
    /// that moved on to another call since is refused, never resumed into the new call.
    public func resumeMeeting(_ key: BrowserMeetingKey, captureID: String, timelineOriginMs: Int, owner: OwnedBrowserCapture, expectedGeneration: String? = nil,
                              armed: @escaping @Sendable (String?,String?) -> Void) {
        owner.withCommittedResume { [self] reference in
            sync {
                do {
                    guard let reference, canStart() else { throw BrowserIPCError.unavailable }
                    try reference.dispatch {
                        let (request,generation) = try registry.resume(key,captureID:captureID,timelineOriginMs:timelineOriginMs,lostAtMs:reference.lostAtMs,expectedGeneration:expectedGeneration)
                        armed(generation,request.id); send([request])
                    }
                    publish()
                }
                catch { armed(nil,nil); completed(.init(requestID:UUID().uuidString,key:key,action:.start,ok:false,error:nil,failure:BrowserControlOutcome.localFailure(error),resume:true),false) }
            }
        }
    }
    /// D52.5: an ownership change that may release a call (a recording saving or retired) is
    /// applied on this queue, after every request already queued (a user's Stop memory first),
    /// and then Starts are admitted again. Taking a hold needs no ordering: it only suppresses.
    public func updateOwnership(_ body: @escaping @Sendable (inout CallOwnership) -> Void) {
        queue.async { [self] in ownership?.update(body); reconcile() }
    }
    /// D52.5: calls whose recording waits to resume are never Started afresh. They are read
    /// from the shared ownership at admission time, never from a later main-actor publication.
    private func refreshLostCalls() {
        if let ownership { registry.setLostCalls(ownership.lostCalls(among:registry.snapshots.flatMap(\.meetings))) }
    }
    public func rememberUserStop(captureID: String, key: BrowserMeetingKey?) {
        queue.async { [self] in registry.rememberUserStop(key:key,captureID:captureID) }
    }
    public func stopMeeting(_ meeting: BrowserMeetingKey, captureID: String? = nil, userInitiated: Bool? = nil, reason: CaptureEndReason = .user) {
        queue.async { [self] in
            // UI publication may lag the new status by one actor hop. Route a
            // fresh Stop by its exact owned capture, without re-keying requests
            // which were already issued on the old connection.
            let current = captureID.flatMap { id in
                registry.snapshots.flatMap { $0.captures + $0.interrupted }
                    .first { $0.captureID.map { Data($0.utf8) == Data(id.utf8) } == true }?.key
            } ?? meeting
            if let request = try? registry.stop(current,captureID:captureID,userInitiated:userInitiated,reason:reason) { send([request]) }
            publish()
        }
    }
    public func stopRecordings(reason: CaptureEndReason = .user) {
        queue.async { [self] in
            if reason == .user || reason == .appQuit { signals.suppress(reason:reason); driveSignals() }
            send(registry.stopAll(userInitiated:reason == .user || reason == .appQuit,reason:reason)); publish() }
    }
    public func stop() {
        sync {
            autoRecord = false; signals.suppress(reason:.appQuit); driveSignals()
            timer?.cancel(); timer = nil
            server?.stop(); server = nil
            for id in Array(connections.keys) { disconnect(id) }
            settleHeldStarts(shutdown:true)
        }
    }
    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key:key) != nil { return try body() }
        return try queue.sync(execute:body)
    }
    private func connect(_ connection: BrowserPipeConnection) {
        guard server != nil, connection.peer.role == .control else { connection.close(); return }
        do { try registry.connect(connection.peer); connections[connection.peer.id] = connection; heartbeats[connection.peer.id] = .init(); publish() }
        catch { connection.close() }
    }
    private func receive(_ data: Data, from connection: BrowserPipeConnection) {
        guard connections[connection.peer.id] === connection else { return }
        do {
            let message = try JSONParser.parse(data)
            try registry.receive(data,from:connection.peer.id)
            // heartbeat-v1: every inbound frame (pong included) refreshes liveness.
            if message["type"]?.string == "hello" {
                if registry.snapshots.first(where:{ $0.id == connection.peer.id })?.supportsCallSignals == true {
                    try connection.send(Data(#"{"type":"configure","capabilities":["call-signals-v1"]}"#.utf8))
                }
                heartbeats[connection.peer.id]?.hello(capabilities:message["capabilities"]?.array?.compactMap(\.string) ?? [],at:clock())
            } else { heartbeats[connection.peer.id]?.inbound(message["type"]?.string,at:clock()) }
            // D57: each status (alone or in a result) confirms its sessions' documents to the
            // stale watchdog as it arrives, not on the policy's poll.
            if message["type"]?.string == "status" || (message["type"]?.string == "result" && message["status"].map { !$0.isNull } == true),
               let audio, let peer = registry.snapshots.first(where:{ $0.id == connection.peer.id }) {
                for session in peer.captures + peer.interrupted {
                    guard let id = session.captureID else { continue }
                    audio.documentChanged(captureID:id,page:session.pageState,documentGeneration:session.documentGeneration)
                }
            }
            if message["type"]?.string == "result", let id = message["requestId"]?.string,
               let (request,_) = deadlines[id], request.key.peer == connection.peer.id,
               let outcome = registry.outcomes.last, outcome.requestID == id {
                deadlines.removeValue(forKey:id)
                let wasAutomatic = automatic.remove(id) != nil
                completed(outcome,wasAutomatic)
            }
            reconcile()
            received(message["type"]?.string)
        } catch { connection.close(); disconnect(connection.peer.id) }
    }
    /// A Start held across its link's loss completes when it settles: ok once the newer link
    /// reports its capture, disconnected at the deadline (checked on every tick) or at shutdown.
    private func settleHeldStarts(shutdown: Bool = false) {
        for outcome in registry.settleHeldStarts(shutdown:shutdown) {
            completed(outcome,automatic.remove(outcome.requestID) != nil)
        }
    }
    private func reconcile() {
        settleHeldStarts()
        registry.setRetainedCaptureIDs(audio?.retainedCaptureIDs ?? [])
        send(registry.drainStops())
        refreshLostCalls()
        driveSignals()
        if autoRecord && canStart() { send(registry.automaticStarts(microphone:microphone),automatic:true) }
        publish()
    }
    /// Called by native admission after every asynchronous permission/checkpoint boundary.
    public func signalMayOpen(_ id: UUID) -> Bool {
        sync {
            guard signals.mayOpen(id) else { return false }
            // Existing inputs belong to the reservation throughout evidence-loss
            // grace. Its disk watcher/Stop retires it; new-root admission does not.
            return signals.started || (autoRecord && canStart() && canSignalStart())
        }
    }
    public func signalEndReason(_ id: UUID) -> CaptureEndReason? { sync { signals.reservation == id ? signals.retiring : nil } }
    public func signalInputGate(_ id: UUID) -> BrowserSignalInputGate? { sync { signals.reservation == id ? signalInput : nil } }
    public func signalStarted(_ id: UUID) { queue.async { [self] in signals.didStart(id); driveSignals() } }
    public func signalReleased(_ id: UUID, failed: Bool = false) {
        queue.async { [self] in guard signals.reservation == id else { return }; signalInput?.update(false); signals.release(id,failed:failed); signalInput = nil; signalStopSent = nil; reconcile() }
    }
    public func stopSignal(_ id: UUID, userInitiated: Bool, reason: CaptureEndReason = .user) {
        sync {
            guard signals.reservation == id else { return }
            if userInitiated || signals.retiring == nil { signals.suppress(reason:reason) }
            driveSignals()
        }
    }
    private func driveSignals() {
        let peers = registry.snapshots
        let now = TimeInterval(clock()) / 1000
        if signalInput?.hasOpened == true, let id = signals.reservation { signals.didStart(id) }
        signals.update(peers.compactMap { peer in peer.callSignals.map { .init(id:peer.id,order:peer.signalConnectionOrder,snapshot:$0) } },now:now)
        signals.advance(now:now,enabled:autoRecord,blocked:{ [registry,ownership] instance,row in registry.browserOwnsSignal(instance:instance,row:row) || ownership?.snapshot.holdsSignal(tab:row.tabID,generation:row.generation) == true })
        signalInput?.update(signals.reservation.map { signals.mayOpen($0) && (signals.started || autoRecord) } ?? false)
        registry.signalOwnedCalls = Set(signals.calls.keys)
        if let id = signals.reservation, let reason = signals.retiring, signalStopSent != id {
            signalStopSent = id; signalAction(.stop(id:id,reason:reason))
        } else if autoRecord, signals.reservation == nil, signals.retiring == nil,
                  let site = signals.site, canStart(), canSignalStart(), let id = signals.reserve() {
            let gate = BrowserSignalInputGate(); gate.update(true); signalInput = gate
            signalAction(.start(id:id,site:site,microphone:microphone))
        }
    }
    private func send(_ requests: [BrowserControlRequest], automatic isAutomatic: Bool = false) {
        for request in requests {
            do {
                guard let connection = connections[request.key.peer] else { throw BrowserIPCError.closed }
                try connection.send(request.data)
                deadlines[request.id] = (request,DispatchTime.now().uptimeNanoseconds + 30_000_000_000)
                if isAutomatic { automatic.insert(request.id) }
            } catch { connections[request.key.peer]?.close(); disconnect(request.key.peer) }
        }
    }
    private func disconnect(_ id: UUID, failure: String = "disconnected") {
        guard connections.removeValue(forKey:id) != nil else { return }
        heartbeats.removeValue(forKey:id)
        let requests = deadlines.values.map(\.0).filter { $0.key.peer == id }
        // A sent Start whose link closed before its result (a worker restart, or a hung worker
        // the heartbeat gave up on) may be recording: the registry holds it until the newer link
        // reports it (see settleHeldStarts). A link closed for an unanswered command holds none.
        let held = registry.disconnect(id,holding:failure == "disconnected" ? Set(requests.map(\.id)) : [])
        for request in requests {
            deadlines.removeValue(forKey:request.id)
            if held.contains(request.id) { continue }
            let wasAutomatic = automatic.remove(request.id) != nil
            completed(.init(requestID:request.id,key:request.key,action:request.action,ok:false,error:nil,failure:failure,resume:request.resume),wasAutomatic)
        }
        driveSignals(); publish()
    }
    /// Runs the heartbeat now, as the 1 s timer does (tests drive it with an injected clock).
    func tickHeartbeats() { sync { beat() } }
    /// The latest inbound frame time across control connections (tests wait on it).
    func lastHeartbeatInbound() -> UInt64? { sync { heartbeats.values.map(\.lastInboundAt).max() } }
    private func beat() {
        let now = clock()
        for (id,var heartbeat) in heartbeats {
            let event = heartbeat.tick(at:now)
            heartbeats[id] = heartbeat
            switch event {
            case .ping(let sequence)?:
                // A ping that cannot be queued means the peer stopped reading: close it.
                guard let data = try? JSON.object([("type",.string("ping")),("seq",.number(String(sequence)))]).encoded(maximumBytes:1024),
                      (try? connections[id]?.send(data)) != nil else { connections[id]?.close(); disconnect(id); continue }
            case .lost?:
                // No inbound frame for 25 s: control is lost, exactly as for EOF. The close
                // never waits behind a stuck write; recordings keep running.
                connections[id]?.close(); disconnect(id)
            case nil: break
            }
        }
    }
    private func expire() {
        beat()
        registry.expireRememberedStops()
        let now = DispatchTime.now().uptimeNanoseconds
        let peers = Set(deadlines.values.filter { $0.1 <= now }.map { $0.0.key.peer })
        // An unacknowledged Start may already be recording. Reconnect reconciles
        // fresh status; it never resends that command or stops its audio host.
        for id in peers { connections[id]?.close(); disconnect(id,failure:"timeout") }
        reconcile()
    }
    private func publish() { changed(registry.snapshots) }
    deinit {
        timer?.cancel(); server?.stop()
        for connection in connections.values { connection.close() }
    }
}
