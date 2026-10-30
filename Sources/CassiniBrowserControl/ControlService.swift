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
    private var deadlines: [String:(BrowserControlRequest,UInt64)] = [:]
    private var callbacks: [String:Bool] = [:]
    private var autoRecord = false, microphone = true
    private let changed: @Sendable ([BrowserControlPeerSnapshot]) -> Void
    private let audio: (any BrowserAudioHandler)?
    private let completed: @Sendable (BrowserControlOutcome,Bool) -> Void
    private let canStart: @Sendable () -> Bool
    public init(changed: @escaping @Sendable ([BrowserControlPeerSnapshot]) -> Void,
                completed: @escaping @Sendable (BrowserControlOutcome,Bool) -> Void, audio: (any BrowserAudioHandler)? = nil,
                canStart: @escaping @Sendable () -> Bool = { true }) {
        self.changed = changed; self.completed = completed; self.audio = audio; self.canStart = canStart; queue.setSpecific(key:key,value:1)
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
    public func rememberUserStop(captureID: String, key: BrowserMeetingKey?) {
        queue.async { [self] in registry.rememberUserStop(key:key,captureID:captureID) }
    }
    public func stopMeeting(_ meeting: BrowserMeetingKey, captureID: String? = nil, userInitiated: Bool = true) {
        queue.async { [self] in
            // UI publication may lag the new status by one actor hop. Route a
            // fresh Stop by its exact owned capture, without re-keying requests
            // which were already issued on the old connection.
            let current = captureID.flatMap { id in
                registry.snapshots.flatMap { $0.captures + $0.interrupted }
                    .first { $0.captureID.map { Data($0.utf8) == Data(id.utf8) } == true }?.key
            } ?? meeting
            if let request = try? registry.stop(current,captureID:captureID,userInitiated:userInitiated) { send([request]) }
            publish()
        }
    }
    public func stopRecordings() {
        queue.async { [self] in send(registry.stopAll()); publish() }
    }
    public func stop() {
        sync {
            timer?.cancel(); timer = nil
            server?.stop(); server = nil
            for id in Array(connections.keys) { disconnect(id) }
            registry.finishReconnects(); publish()
        }
    }
    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key:key) != nil { return try body() }
        return try queue.sync(execute:body)
    }
    private func connect(_ connection: BrowserPipeConnection) {
        guard server != nil, connection.peer.role == .control else { connection.close(); return }
        do { try registry.connect(connection.peer); connections[connection.peer.id] = connection; publish() }
        catch { connection.close() }
    }
    private func receive(_ data: Data, from connection: BrowserPipeConnection) {
        guard connections[connection.peer.id] === connection else { return }
        do {
            let message = try JSONParser.parse(data)
            try registry.receive(data,from:connection.peer.id)
            if message["type"]?.string == "result", let id = message["requestId"]?.string,
               deadlines[id]?.0.connectionID == connection.peer.id,
               registry.outcomes.contains(where:{ $0.requestID == id }) {
                deadlines.removeValue(forKey:id)
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
        // One failed write can disconnect every request in this batch before
        // the loop reaches the others. Register their completions first.
        for request in requests { callbacks[request.id] = isAutomatic }
        for request in requests {
            do {
                guard let connection = connections[request.connectionID] else { throw BrowserIPCError.closed }
                try connection.send(request.data)
                deadlines[request.id] = (request,DispatchTime.now().uptimeNanoseconds + 30_000_000_000)
            } catch {
                if let connection = connections[request.connectionID] { connection.close(); disconnect(request.connectionID) }
                else { registry.failed(request) }
            }
        }
    }
    private func disconnect(_ id: UUID) {
        guard connections.removeValue(forKey:id) != nil else { return }
        let requests = deadlines.values.map(\.0).filter { $0.connectionID == id }
        registry.disconnect(id)
        for request in requests {
            deadlines.removeValue(forKey:request.id)
        }
        publish()
    }
    private func expire() {
        registry.expireRememberedStops()
        let now = DispatchTime.now().uptimeNanoseconds
        let peers = Set(deadlines.values.filter { $0.1 <= now }.map { $0.0.connectionID })
        // An unacknowledged Start may already be recording. Reconnect reconciles
        // fresh status; it never resends that command or stops its audio host.
        for id in peers { connections[id]?.close(); disconnect(id) }
        reconcile()
    }
    private func publish() {
        changed(registry.snapshots)
        for outcome in registry.takeOutcomes() {
            if let wasAutomatic = callbacks.removeValue(forKey:outcome.requestID) { completed(outcome,wasAutomatic) }
        }
    }
    deinit {
        timer?.cancel(); server?.stop()
        for connection in connections.values { connection.close() }
    }
}
