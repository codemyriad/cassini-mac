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
    private let changed: @Sendable ([BrowserControlPeerSnapshot]) -> Void
    private let audio: (any BrowserAudioHandler)?
    private let completed: @Sendable (BrowserControlOutcome,Bool) -> Void
    private let canStart: @Sendable () -> Bool
    public init(changed: @escaping @Sendable ([BrowserControlPeerSnapshot]) -> Void,
                completed: @escaping @Sendable (BrowserControlOutcome,Bool) -> Void, audio: (any BrowserAudioHandler)? = nil,
                canStart: @escaping @Sendable () -> Bool = { true },
                clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds / 1_000_000 }) {
        self.changed = changed; self.completed = completed; self.audio = audio; self.canStart = canStart; self.clock = clock
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
            let requests = registry.startAll(microphone:microphone,choices:choices)
            send(requests); publish(); issued(requests)
        }
    }
    public func recordMeeting(_ key: BrowserMeetingKey, microphone: Bool) {
        queue.async { [self] in
            do {
                guard canStart() else { throw BrowserIPCError.unavailable }
                send([try registry.start(key,microphone:microphone)]); publish()
            }
            catch { completed(.init(requestID:UUID().uuidString,key:key,action:.start,ok:false,error:nil),false) }
        }
    }
    /// D52.1 R67: ask the extension to join a native stand-in. `armed` receives the
    /// selected call generation before the command is sent, so the native resume
    /// can be validated; a failure is reported and never retried as a fresh Start.
    public func resumeMeeting(_ key: BrowserMeetingKey, captureID: String, timelineOriginMs: Int, armed: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            do {
                guard canStart() else { throw BrowserIPCError.unavailable }
                let (request,generation) = try registry.resume(key,captureID:captureID,timelineOriginMs:timelineOriginMs)
                armed(generation); send([request]); publish()
            }
            catch { armed(nil); completed(.init(requestID:UUID().uuidString,key:key,action:.start,ok:false,error:nil),false) }
        }
    }
    /// D52.5: calls whose recording is on system/lost; they are resumed, never auto-Started.
    public func setLostCalls(_ calls: Set<BrowserControlRegistry.LostCall>) {
        queue.async { [self] in registry.setLostCalls(calls); reconcile() }
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
        queue.async { [self] in send(registry.stopAll(userInitiated:reason == .user || reason == .appQuit,reason:reason)); publish() }
    }
    public func stop() {
        sync {
            timer?.cancel(); timer = nil
            server?.stop(); server = nil
            for id in Array(connections.keys) { disconnect(id) }
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
                heartbeats[connection.peer.id]?.hello(capabilities:message["capabilities"]?.array?.compactMap(\.string) ?? [],at:clock())
            } else { heartbeats[connection.peer.id]?.inbound(message["type"]?.string,at:clock()) }
            if message["type"]?.string == "result", let id = message["requestId"]?.string,
               let (request,_) = deadlines[id], request.key.peer == connection.peer.id,
               let outcome = registry.outcomes.last, outcome.requestID == id {
                deadlines.removeValue(forKey:id)
                let wasAutomatic = automatic.remove(id) != nil
                completed(outcome,wasAutomatic)
            }
            reconcile()
        } catch { connection.close(); disconnect(connection.peer.id) }
    }
    private func reconcile() {
        registry.setRetainedCaptureIDs(audio?.retainedCaptureIDs ?? [])
        send(registry.drainStops())
        if autoRecord && canStart() { send(registry.automaticStarts(microphone:microphone),automatic:true) }
        publish()
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
    private func disconnect(_ id: UUID) {
        guard connections.removeValue(forKey:id) != nil else { return }
        heartbeats.removeValue(forKey:id)
        let requests = deadlines.values.map(\.0).filter { $0.key.peer == id }
        registry.disconnect(id)
        for request in requests {
            deadlines.removeValue(forKey:request.id)
            let wasAutomatic = automatic.remove(request.id) != nil
            completed(.init(requestID:request.id,key:request.key,action:request.action,ok:false,error:nil),wasAutomatic)
        }
        publish()
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
        for id in peers { connections[id]?.close(); disconnect(id) }
        reconcile()
    }
    private func publish() { changed(registry.snapshots) }
    deinit {
        timer?.cancel(); server?.stop()
        for connection in connections.values { connection.close() }
    }
}
