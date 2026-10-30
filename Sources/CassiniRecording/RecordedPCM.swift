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
/// Called on the input callback after admission unlock. Implementations must
/// only offer to bounded memory and return; never perform analysis or file I/O.
public protocol RecordedPCMObserver: AnyObject, Sendable {
    func offer(source: RecordedPCMSource, pcm: Data, offsetMs: Double)
    func sourceEnded(id: String)
}
public extension RecordedPCMObserver { func sourceEnded(id: String) {} }
/// Shared by one session's span writers. UI disappearance clears/subscribes the
/// observer independently of slow writes, without retaining its view hierarchy.
public final class RecordedPCMObservers: @unchecked Sendable {
    private let lock = NSLock()
    private weak var observer: (any RecordedPCMObserver)?
    public init() {}
    public func set(_ value: (any RecordedPCMObserver)?) { lock.withLock { observer = value } }
    public func offer(source: RecordedPCMSource, pcm: Data, offsetMs: Double) {
        current?.offer(source:source,pcm:pcm,offsetMs:offsetMs)
    }
    public func sourceEnded(id: String) { current?.sourceEnded(id:id) }
    fileprivate var current: (any RecordedPCMObserver)? { lock.withLock { observer } }
}
/// Only this small metadata lock crosses the callback boundary. It is never
/// held across a write. A staged writer forwards here only after activation;
/// its readiness PCM cannot reach the observer before selection commits.
public final class RecordedPCMPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private let observers: RecordedPCMObservers
    private var sources: [String:RecordedPCMSource] = [:]
    private var target: RecordedPCMPolicy?
    public init(observers: RecordedPCMObservers = .init()) { self.observers = observers }
    public func publish(_ source: RecordedPCMSource, for inputID: String) {
        lock.withLock { sources[inputID] = source }
    }
    public func forward(to value: RecordedPCMPolicy?) {
        precondition(value !== self)
        lock.withLock { target = value }
    }
    public func offer(inputID: String, pcm: Data, offsetMs: Double) {
        offer(inputID:inputID,pcm:pcm,offsetMs:offsetMs,depth:0)
    }
    private func offer(inputID: String, pcm: Data, offsetMs: Double, depth: Int) {
        guard depth < 3 else { return }
        let next = lock.withLock { target }
        if let next { next.offer(inputID:inputID,pcm:pcm,offsetMs:offsetMs,depth:depth+1); return }
        guard let observer = observers.current, let source = lock.withLock({ sources[inputID] }) else { return }
        observer.offer(source:source,pcm:pcm,offsetMs:offsetMs)
    }
}
