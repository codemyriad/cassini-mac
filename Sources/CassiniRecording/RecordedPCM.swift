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
/// A session's one analyser subscription, independent of slow file writes.
public final class RecordedPCMObservers: @unchecked Sendable {
    private final class WeakPolicy { weak var value: RecordedPCMPolicy?; init(_ value: RecordedPCMPolicy) { self.value = value } }
    private let lock = NSLock()
    private weak var observer: (any RecordedPCMObserver)?
    private var policies: [WeakPolicy] = []
    public init() {}
    public func set(_ value: (any RecordedPCMObserver)?) {
        let clear: [RecordedPCMPolicy] = lock.withLock {
            observer = value; policies.removeAll { $0.value == nil }
            return value == nil ? policies.compactMap(\.value) : []
        }
        // Release bootstrapping buffers immediately when all views disappear.
        // Never hold the subscription lock while entering a policy lock.
        clear.forEach { $0.clearPending() }
    }
    fileprivate func register(_ policy: RecordedPCMPolicy) {
        lock.withLock { policies.removeAll { $0.value == nil }; policies.append(WeakPolicy(policy)) }
    }
    public func offer(source: RecordedPCMSource, pcm: Data, offsetMs: Double) {
        current?.offer(source:source,pcm:pcm,offsetMs:offsetMs)
    }
    public func sourceEnded(id: String) { current?.sourceEnded(id:id) }
    fileprivate var current: (any RecordedPCMObserver)? { lock.withLock { observer } }
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
            guard let observer = observers.current else { clearPending(); lock.withLock { _ = flushing.remove(inputID) }; return }
            for chunk in chunks.sorted(by: { $0.offset < $1.offset }) {
                deliver(source:source,pcm:chunk.pcm,offsetMs:chunk.offset,observer:observer)
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
        let observer = observers.current
        let action: Action = lock.withLock {
            guard enabled else { return .none }
            // Decide forwarding and buffering under the same lock as activation:
            // an offer cannot append to a staged buffer after it was transferred.
            if let target { return .forward(target) }
            guard observer != nil, observers.current != nil else { return .none }
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
            if let observer { deliver(source:source,pcm:pcm,offsetMs:offsetMs,observer:observer) }
        }
    }

    private func deliver(source: RecordedPCMSource, pcm: Data, offsetMs: Double, observer: any RecordedPCMObserver) {
        let frameBytes = source.channels*2
        guard pcm.count%frameBytes == 0 else { return }
        let before = max(0,(source.startOffsetMs-offsetMs)*Double(source.sampleRate)/1000)
        // The stored start is already on this input's sample grid. Avoid losing
        // an extra sample to floating-point cancellation at long session times.
        let nearest = before.rounded()
        let frames = abs(before-nearest) < 0.00001 ? nearest : ceil(before)
        let trim = Int(min(Double(pcm.count/frameBytes),frames))
        guard trim*frameBytes < pcm.count else { return }
        observer.offer(source:source,pcm:trim == 0 ? pcm : Data(pcm.dropFirst(trim*frameBytes)),
                       offsetMs:offsetMs+Double(trim)/Double(source.sampleRate)*1000)
    }
}
