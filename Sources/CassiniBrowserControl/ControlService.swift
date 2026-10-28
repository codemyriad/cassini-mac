// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

/// Owns only browser management. Each audio session will have a separate owner;
/// closing this service never sends Stop or finalizes an audio writer.
public final class BrowserControlService: @unchecked Sendable {
    private let queue = DispatchQueue(label:"com.codemyriad.cassini.control-state")
    private let key = DispatchSpecificKey<UInt8>()
    private var server: BrowserPipeServer?
    private var timer: DispatchSourceTimer?
    private var registry = BrowserControlRegistry()
    private var connections: [UUID:BrowserPipeConnection] = [:]
    private var deadlines: [String:(BrowserControlRequest,UInt64)] = [:]
    private var automatic: Set<String> = []
    private var autoRecord = false, microphone = true
    private let changed: @Sendable ([BrowserControlPeerSnapshot]) -> Void
    private let completed: @Sendable (BrowserControlOutcome,Bool) -> Void
    public init(changed: @escaping @Sendable ([BrowserControlPeerSnapshot]) -> Void,
                completed: @escaping @Sendable (BrowserControlOutcome,Bool) -> Void) {
        self.changed = changed; self.completed = completed; queue.setSpecific(key:key,value:1)
    }
    public func start(root: URL = BrowserPipeServer.standardRoot) throws {
        try sync {
            guard server == nil else { throw BrowserIPCError.unavailable }
            let transport = BrowserPipeServer(root:root,connected:{ [weak self] connection in
                self?.queue.async { [weak self] in self?.connect(connection) }
            },received:{ [weak self] connection,data in
                self?.queue.async { [weak self] in self?.receive(data,from:connection) }
            },disconnected:{ [weak self] peer in
                self?.queue.async { [weak self] in self?.disconnect(peer.id) }
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
    public func recordAll(microphone: Bool) {
        queue.async { [self] in send(registry.startAll(microphone:microphone)); publish() }
    }
    public func stopMeeting(_ meeting: BrowserMeetingKey) {
        queue.async { [self] in
            if let request = try? registry.stop(meeting) { send([request]) }
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
        send(registry.drainStops())
        if autoRecord { send(registry.automaticStarts(microphone:microphone),automatic:true) }
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
        let requests = deadlines.values.map(\.0).filter { $0.key.peer == id }
        registry.disconnect(id)
        for request in requests {
            deadlines.removeValue(forKey:request.id)
            let wasAutomatic = automatic.remove(request.id) != nil
            completed(.init(requestID:request.id,key:request.key,action:request.action,ok:false,error:nil),wasAutomatic)
        }
        publish()
    }
    private func expire() {
        let now = DispatchTime.now().uptimeNanoseconds
        let peers = Set(deadlines.values.filter { $0.1 <= now }.map { $0.0.key.peer })
        // An unacknowledged Start may already be recording. Reconnect reconciles
        // fresh status; it never resends that command or stops its audio host.
        for id in peers { connections[id]?.close(); disconnect(id) }
    }
    private func publish() { changed(registry.snapshots) }
    deinit {
        timer?.cancel(); server?.stop()
        for connection in connections.values { connection.close() }
    }
}
