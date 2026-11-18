// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Identity and clock of the actual recorded span, after source-selection trim.
public struct RecordedPCMSource: Sendable, Equatable {
    public let id: String, kind: String
    public let sampleRate: Int, channels: Int
    public let startOffsetMs: Double
    public init(id: String, kind: String, sampleRate: Int, channels: Int, startOffsetMs: Double) {
        precondition((8000...192000).contains(sampleRate) && (1...2).contains(channels) && startOffsetMs.isFinite && startOffsetMs >= 0)
        self.id = id; self.kind = kind; self.sampleRate = sampleRate; self.channels = channels; self.startOffsetMs = startOffsetMs
    }
}
/// Called after admission unlock. Implementations only offer bounded memory;
/// never perform analysis or file I/O, including when bootstrap PCM is replayed.
public protocol RecordedPCMObserver: AnyObject, Sendable {
    func offer(source: RecordedPCMSource, pcm: Data, offsetMs: Double)
    func sourceEnded(id: String)
}
public extension RecordedPCMObserver { func sourceEnded(id: String) {} }
/// App-local PCM for inference. Frame gaps reveal preview backpressure or source discontinuities.
public enum LivePCMEvent: Sendable {
    case audio(source: RecordedPCMSource, pcm16LE: Data, offsetMs: Double)
    case ended(id: String)
}

/// Keep source ends independently of the lossy PCM budget. All operations
/// except next() are synchronous and bounded on capture producer threads.
private final class LivePCMFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [LivePCMEvent] = []
    private var audioCount = 0
    private var endIDs: Set<String> = []
    private var waiting: CheckedContinuation<LivePCMEvent?, Never>?
    private var closed = false

    func next() async -> LivePCMEvent? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { reply in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    reply.resume(returning: nil)
                } else if !queue.isEmpty {
                    let event = queue.removeFirst()
                    switch event {
                    case .audio: audioCount -= 1
                    case let .ended(id): endIDs.remove(id)
                    }
                    lock.unlock()
                    reply.resume(returning: event)
                } else if closed {
                    lock.unlock()
                    reply.resume(returning: nil)
                } else {
                    precondition(waiting == nil, "The live PCM feed supports one consumer")
                    waiting = reply
                    lock.unlock()
                }
            }
        } onCancel: { self.close(discard: true) }
    }

    func offer(_ event: LivePCMEvent) {
        let reply = lock.withLock {
            () -> CheckedContinuation<LivePCMEvent?, Never>? in
            guard !closed else { return nil }
            if let waiting {
                self.waiting = nil
                return waiting
            }
            switch event {
            case .audio:
                if audioCount == 32, let old = queue.firstIndex(where: {
                    if case .audio = $0 { return true }
                    return false
                }) {
                    queue.remove(at: old)
                    audioCount -= 1
                }
                audioCount += 1
            case let .ended(id):
                guard endIDs.count < 64, endIDs.insert(id).inserted else { return nil }
            }
            queue.append(event)
            return nil
        }
        reply?.resume(returning: event)
    }

    func close(discard: Bool = false) {
        let reply = lock.withLock {
            closed = true
            if discard {
                queue.removeAll()
                endIDs.removeAll()
                audioCount = 0
            }
            let active = waiting
            waiting = nil
            return active
        }
        reply?.resume(returning: nil)
    }
}

/// A session's visual observer and independent bounded inference subscription.
public final class RecordedPCMObservers: @unchecked Sendable {
    private final class WeakPolicy { weak var value: RecordedPCMPolicy?; init(_ value: RecordedPCMPolicy) { self.value = value } }
    private let lock = NSLock()
    private weak var observer: (any RecordedPCMObserver)?
    private var policies: [WeakPolicy] = []
    private var live: (id: UUID, feed: LivePCMFeed)?
    private var liveFinished = false
    public init() {}
    deinit { live?.feed.close() }
    public func set(_ value: (any RecordedPCMObserver)?) {
        let clear: [RecordedPCMPolicy] = lock.withLock {
            observer = value; policies.removeAll { $0.value == nil }
            return value == nil && live == nil ? policies.compactMap(\.value) : []
        }
        // Release bootstrapping buffers immediately when all views disappear.
        // Never hold the subscription lock while entering a policy lock.
        clear.forEach { $0.clearPending() }
    }
    fileprivate func register(_ policy: RecordedPCMPolicy) {
        lock.withLock { policies.removeAll { $0.value == nil }; policies.append(WeakPolicy(policy)) }
    }
    /// The oldest preview blocks may be displaced when recognition falls behind.
    /// Calling again replaces the previous inference subscription.
    public func livePCM() -> AsyncStream<LivePCMEvent> {
        let id = UUID()
        let feed = LivePCMFeed()
        let (closed, previous) = lock.withLock {
            if liveFinished { return (true, nil as LivePCMFeed?) }
            let previous = live?.feed
            live = (id, feed)
            return (false, previous)
        }
        previous?.close(discard: true)
        if closed { feed.close() }
        return AsyncStream(unfolding: { await feed.next() }, onCancel: { [weak self] in
            feed.close(discard: true)
            self?.removeLive(id: id)
        })
    }

    private func removeLive(id: UUID) {
        let clear: [RecordedPCMPolicy] = lock.withLock {
            guard live?.id == id else { return [] }
            live = nil
            return observer == nil ? policies.compactMap(\.value) : []
        }
        clear.forEach { $0.clearPending() }
    }

    func finishLive() {
        let (feed, clear) = lock.withLock {
            liveFinished = true
            let feed = live?.feed
            live = nil
            return (feed, observer == nil ? policies.compactMap(\.value) : [])
        }
        feed?.close()
        clear.forEach { $0.clearPending() }
    }

    public func offer(source: RecordedPCMSource, pcm: Data, offsetMs: Double) {
        let (visual, inference) = lock.withLock { (observer, live?.feed) }
        inference?.offer(.audio(source: source, pcm16LE: pcm, offsetMs: offsetMs))
        visual?.offer(source: source, pcm: pcm, offsetMs: offsetMs)
    }
    public func sourceEnded(id: String) {
        let (visual, inference) = lock.withLock { (observer, live?.feed) }
        inference?.offer(.ended(id: id))
        visual?.sourceEnded(id: id)
    }
    fileprivate var hasObservers: Bool { lock.withLock { observer != nil || live != nil } }
}
/// Independent metadata lock, never held across a write or analyser callback.
/// Keep bounded admitted PCM until the first write establishes its real span
/// identity/offset. This avoids dropping a nondeterministic first input buffer.
public final class RecordedPCMPolicy: @unchecked Sendable {
    private struct Chunk { let pcm: Data, offset: Double }
    private enum Action { case none, forward(RecordedPCMPolicy), deliver(RecordedPCMSource) }
    private let lock = NSLock()
    private let observers: RecordedPCMObservers
    private var sources: [String:RecordedPCMSource] = [:]
    private var target: RecordedPCMPolicy?
    private var pending: [String:[Chunk]] = [:]
    private var pendingBytes = 0
    private var flushing: Set<String> = []
    private var enabled = true
    private(set) var bootstrapDrops: UInt64 = 0
    public init(observers: RecordedPCMObservers = .init()) {
        self.observers = observers; observers.register(self)
    }
    public func publish(_ source: RecordedPCMSource, for inputID: String) {
        let drain = lock.withLock {
            guard enabled else { return false }
            sources[inputID] = source
            return flushing.insert(inputID).inserted
        }
        guard drain else { return }
        while true {
            let chunks: [Chunk] = lock.withLock {
                let batch = pending.removeValue(forKey:inputID) ?? []
                pendingBytes -= batch.reduce(0) { $0+$1.pcm.count }
                if batch.isEmpty { flushing.remove(inputID) }
                return batch
            }
            guard !chunks.isEmpty else { return }
            guard observers.hasObservers else { clearPending(); lock.withLock { _ = flushing.remove(inputID) }; return }
            for chunk in chunks.sorted(by: { $0.offset < $1.offset }) {
                deliver(source:source,pcm:chunk.pcm,offsetMs:chunk.offset)
            }
        }
    }
    public func forward(to value: RecordedPCMPolicy?) {
        precondition(value !== self)
        let buffered = lock.withLock { () -> [String:[Chunk]] in
            guard enabled else { return [:] }
            target = value
            let buffered = pending; pending = [:]; pendingBytes = 0
            return value == nil ? [:] : buffered
        }
        // A staged target is new and has no source metadata yet. Its first
        // publication sorts these chunks together with any racing live input.
        if let value {
            for (id,chunks) in buffered { for chunk in chunks { value.offer(inputID:id,pcm:chunk.pcm,offsetMs:chunk.offset) } }
        }
    }
    public func cancel() { lock.withLock { enabled = false; target = nil; pending = [:]; pendingBytes = 0 } }
    fileprivate func clearPending() { lock.withLock { pending = [:]; pendingBytes = 0 } }
    var bufferedBytes: Int { lock.withLock { pendingBytes } }
    public func offer(inputID: String, pcm: Data, offsetMs: Double) {
        offer(inputID:inputID,pcm:pcm,offsetMs:offsetMs,depth:0)
    }
    private func offer(inputID: String, pcm: Data, offsetMs: Double, depth: Int) {
        guard depth < 3, offsetMs.isFinite, offsetMs >= 0, !pcm.isEmpty else { return }
        let action: Action = lock.withLock {
            guard enabled else { return .none }
            // Decide forwarding and buffering under the same lock as activation:
            // an offer cannot append to a staged buffer after it was transferred.
            if let target { return .forward(target) }
            guard observers.hasObservers else { return .none }
            if let value = sources[inputID], !flushing.contains(inputID) { return .deliver(value) }
            guard pendingBytes+pcm.count <= 1_048_576, pending.count < 64 || pending[inputID] != nil,
                  pending[inputID,default:[]].count < 64 else { bootstrapDrops &+= 1; return .none }
            pending[inputID,default:[]].append(.init(pcm:pcm,offset:offsetMs)); pendingBytes += pcm.count
            return .none
        }
        switch action {
        case .none: break
        case .forward(let next): next.offer(inputID:inputID,pcm:pcm,offsetMs:offsetMs,depth:depth+1)
        case .deliver(let source):
            deliver(source:source,pcm:pcm,offsetMs:offsetMs)
        }
    }

    private func deliver(source: RecordedPCMSource, pcm: Data, offsetMs: Double) {
        let frameBytes = source.channels*2
        guard pcm.count%frameBytes == 0 else { return }
        let before = max(0,(source.startOffsetMs-offsetMs)*Double(source.sampleRate)/1000)
        // The stored start is already on this input's sample grid. Avoid losing
        // an extra sample to floating-point cancellation at long session times.
        let nearest = before.rounded()
        let frames = abs(before-nearest) < 0.00001 ? nearest : ceil(before)
        let trim = Int(min(Double(pcm.count/frameBytes),frames))
        guard trim*frameBytes < pcm.count else { return }
        observers.offer(source:source,pcm:trim == 0 ? pcm : Data(pcm.dropFirst(trim*frameBytes)),
                       offsetMs:offsetMs+Double(trim)/Double(source.sampleRate)*1000)
    }
}
