// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import CassiniLibrary

enum SessionTransportState { case paused, waiting, playing }
@MainActor protocol SessionTransport: AnyObject {
    var onState: ((SessionTransportState) -> Void)? { get set }
    var onEnd: (() -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    var onPosition: ((Double) -> Void)? { get set }
    func play()
    func pause()
    func rewind(_ completion: @escaping @MainActor @Sendable (Bool) -> Void)
    func close()
    func seek(toMs: Double, completion: @escaping @MainActor @Sendable (Bool) -> Void)
    func setRate(_ rate: Float)
}
private final class PreparationLifetime: @unchecked Sendable {
    var task: Task<Void, Never>?
    deinit { task?.cancel() }
}
/// Owns requested transport state separately from the player's asynchronous
/// callbacks. Eligibility never prevents pausing an already requested playback.
@MainActor @Observable public final class SessionPlayback {
    public private(set) var isPlaying = false
    public private(set) var isPreparing = false
    public private(set) var positionMs = 0.0
    public var rate: Float = 1 { didSet { transport?.setRate(rate) } }
    @ObservationIgnored public var onFailure: ((Error) -> Void)?
    @ObservationIgnored private let build: @Sendable ([LibraryAudioTrack], OthersOwnership?) async throws -> SessionTimeline
    @ObservationIgnored private let makeTransport: (SessionTimeline) -> any SessionTransport
    @ObservationIgnored private let lifetime = PreparationLifetime()
    @ObservationIgnored private var transport: (any SessionTransport)?
    @ObservationIgnored private var timeline: SessionTimeline?
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var sources: [LibraryAudioTrack] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var wantsPlay = false
    @ObservationIgnored private var rewinding = false
    @ObservationIgnored private var seekSerial = 0
    @ObservationIgnored private var requestedPosition: Double?
    @ObservationIgnored private var pendingDuration: Double?
    private static weak var active: SessionPlayback?
    var preparation: Task<Void, Never>? { lifetime.task }

    public init() {
        build = { try await SessionComposition.make(tracks: $0, ownership: $1) }
        makeTransport = { AVSessionTransport($0) }
    }
    init(build: @escaping @Sendable ([LibraryAudioTrack]) async throws -> SessionTimeline, makeTransport: @escaping (SessionTimeline) -> any SessionTransport) {
        self.build = { tracks, _ in try await build(tracks) }; self.makeTransport = makeTransport
    }
    public static func stopAll() { active?.stop() }
    public func reconcile(_ meeting: LibraryMeeting?, offline: Bool) {
        guard key != nil else { return }
        guard !offline, let meeting, meeting.libraryKey == key, meeting.canPlaySession, meeting.audioTracks == sources else { stop(); return }
    }
    public func toggle(_ meeting: LibraryMeeting) {
        if wantsPlay || isPlaying {
            wantsPlay = false; transport?.pause(); isPlaying = false; return
        }
        guard meeting.canPlaySession else { return }
        if key == meeting.libraryKey, isPreparing { wantsPlay = true; return }
        if key == meeting.libraryKey, let transport {
            wantsPlay = true; isPlaying = true
            if !rewinding { transport.play() }
            return
        }
        prepare(meeting, autoplay: true)
    }
    /// An explicit Play from here action must also resume paused or preparing
    /// playback. It cannot toggle an already queued Play back off.
    public func play(_ meeting: LibraryMeeting, fromMs: Double) {
        guard meeting.canPlaySession, fromMs.isFinite else { return }
        prepare(meeting)
        wantsPlay = true
        seek(toMs:fromMs)
    }
    public func prepare(_ meeting: LibraryMeeting, autoplay: Bool = false) {
        guard meeting.canPlaySession, key != meeting.libraryKey else { return }
        stop(); Self.active?.stop(); Self.active = self
        key = meeting.libraryKey; sources = meeting.audioTracks; isPreparing = true
        pendingDuration = meeting.durationMs.map { max(0,Double($0)) }
        wantsPlay = autoplay
        let current = generation, builder = build
        lifetime.task = Task { [weak self] in
            do {
                let result = try await builder(meeting.audioTracks, OthersOwnership(events: meeting.captureEvents))
                try Task.checkCancellation()
                guard let self, current == self.generation else { return }
                let transport = self.makeTransport(result)
                self.timeline = result; self.transport = transport
                self.isPreparing = false; self.lifetime.task = nil
                transport.onState = { [weak self] state in self?.changed(state, generation: current) }
                transport.onEnd = { [weak self] in self?.ended(generation: current) }
                transport.onFailure = { [weak self] error in self?.failed(error, generation: current) }
                transport.onPosition = { [weak self] ms in
                    guard let self, current == self.generation, !self.rewinding else { return }
                    self.positionMs = ms
                }
                transport.setRate(self.rate)
                self.isPlaying = self.wantsPlay
                if let position = self.requestedPosition { self.seek(toMs: position) }
                else if self.wantsPlay { transport.play() }
            } catch is CancellationError {
                if let self, current == self.generation { self.stop() }
            }
            catch { self?.failed(error, generation: current) }
        }
    }
    public func seek(toMs: Double) {
        guard toMs.isFinite else { return }
        let limit = timeline?.durationMs ?? pendingDuration ?? Double.greatestFiniteMagnitude
        let target = min(limit,max(0,toMs))
        requestedPosition = target; positionMs = target
        guard let transport else { return }
        seekSerial += 1
        let serial = seekSerial, current = generation
        rewinding = true; transport.pause()
        transport.seek(toMs: target) { [weak self] finished in
            guard let self, current == self.generation, serial == self.seekSerial else { return }
            self.rewinding = false
            guard finished else { self.failed(CocoaError(.fileReadUnknown), generation: current); return }
            if self.wantsPlay { transport.play(); self.isPlaying = true }
        }
    }
    private func changed(_ state: SessionTransportState, generation current: Int) {
        guard current == generation, !rewinding else { return }
        switch state {
        case .paused: wantsPlay = false; isPlaying = false
        case .waiting, .playing:
            if wantsPlay { isPlaying = true }
            else { transport?.pause(); isPlaying = false }
        }
    }
    private func ended(generation current: Int) {
        guard current == generation, !rewinding, let transport else { return }
        wantsPlay = false; isPlaying = false; rewinding = true
        requestedPosition = nil; positionMs = 0; seekSerial += 1
        let serial = seekSerial
        transport.pause()
        transport.rewind { [weak self] finished in
            guard let self, current == self.generation, serial == self.seekSerial else { return }
            self.rewinding = false
            guard finished else { self.failed(CocoaError(.fileReadUnknown), generation: current); return }
            if self.wantsPlay { self.transport?.play(); self.isPlaying = true }
        }
    }
    private func failed(_ error: Error, generation current: Int) {
        guard current == generation else { return }
        stop(); onFailure?(error)
    }
    public func stop() {
        generation += 1
        lifetime.task?.cancel(); lifetime.task = nil
        transport?.close(); transport = nil; timeline = nil
        key = nil; sources = []; wantsPlay = false; rewinding = false
        requestedPosition = nil; pendingDuration = nil; positionMs = 0; seekSerial += 1
        isPlaying = false; isPreparing = false
        if Self.active === self { Self.active = nil }
    }
}
