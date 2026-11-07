// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import CassiniLibrary

enum SessionTransportState { case paused, waiting, playing }
/// Native clocks can stop on the audio frame just before a requested millisecond.
/// Share the same 1 ms end-position precision across transport and owner checks.
enum SessionBoundary { static let toleranceMs = 1.0 }
@MainActor protocol SessionTransport: AnyObject {
    var onState: ((SessionTransportState) -> Void)? { get set }
    var onEnd: (() -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    var onPosition: ((Double) -> Void)? { get set }
    var positionMs: Double { get }
    func play()
    func pause()
    func rewind(_ completion: @escaping @MainActor @Sendable (Bool) -> Void)
    func close()
    func seek(toMs: Double, completion: @escaping @MainActor @Sendable (Bool) -> Void)
    func setRate(_ rate: Float)
    func setBoundary(atMs: Double, completion: @escaping @MainActor @Sendable () -> Void)
    func clearBoundary()
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
    @ObservationIgnored private var userPaused = false
    @ObservationIgnored private var rewinding = false
    @ObservationIgnored private var seekSerial = 0
    @ObservationIgnored private var requestedPosition: Double?
    @ObservationIgnored private var pendingDuration: Double?
    @ObservationIgnored weak var listener: ListenController?
    struct Span {
        let endMs: Double
        let done: @MainActor @Sendable () -> Void
    }
    @ObservationIgnored private var span: Span?
    @ObservationIgnored private var spanSerial = 0
    @ObservationIgnored private var spanEnded = false
    public var durationMs: Double { timeline?.durationMs ?? pendingDuration ?? 0 }
    /// Commands use the live media position; an outstanding seek uses its requested
    /// position so stepping can never jump back to the clock the seek is replacing.
    public var playheadMs: Double { rewinding || isPreparing ? positionMs : (transport?.positionMs ?? positionMs) }
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
            pause(); return
        }
        guard meeting.canPlaySession else { return }
        userPaused = false
        if key == meeting.libraryKey, isPreparing { wantsPlay = true; return }
        if key == meeting.libraryKey, let transport {
            wantsPlay = true; isPlaying = true
            if !rewinding {
                if span != nil {
                    let current = generation, serial = seekSerial
                    installBoundary(generation:current,seek:serial)
                    guard current == generation, serial == seekSerial, wantsPlay else { return }
                    transport.play()
                }
                else if positionMs >= durationMs, durationMs > 0 { seek(toMs:0) }
                else if spanEnded { seek(toMs:positionMs) }
                else { transport.play() }
            }
            return
        }
        prepare(meeting, autoplay: true)
    }
    /// An explicit pause fences a queued EOF independently of the backend's natural paused state.
    public func pause() {
        userPaused = true; wantsPlay = false; spanSerial += 1; transport?.clearBoundary()
        if !rewinding, let transport { positionMs = transport.positionMs; requestedPosition = positionMs }
        transport?.pause(); isPlaying = false
    }
    /// An explicit Play from here action must also resume paused or preparing
    /// playback. It cannot toggle an already queued Play back off.
    public func play(_ meeting: LibraryMeeting, fromMs: Double) {
        guard meeting.canPlaySession, fromMs.isFinite else { return }
        prepare(meeting)
        userPaused = false; wantsPlay = true
        seek(toMs:fromMs)
    }
    /// D70: an uncapped span, with no position restore. Its completion is delivered
    /// once, after the precise transport boundary (or the clamped physical end).
    @discardableResult public func play(_ meeting: LibraryMeeting, fromMs: Double, untilMs: Double,
                                      onDone: @escaping @MainActor @Sendable () -> Void) -> Bool {
        guard meeting.canPlaySession, fromMs.isFinite, untilMs.isFinite,
              untilMs > max(0,fromMs) else { return false }
        prepare(meeting)
        replaceSpan(.init(endMs:untilMs,done:onDone))
        userPaused = false; wantsPlay = true; isPlaying = true
        seek(toMs:fromMs,following:false)
        return true
    }
    /// Remove the current stop without pausing or moving the playhead. A completed
    /// segment still needs a seek at the same position before ordinary play resumes.
    public func clearSpan() {
        let completed = spanEnded
        replaceSpan(nil); spanEnded = completed
    }
    private func replaceSpan(_ request: Span?) {
        spanSerial += 1; span = request; spanEnded = false
        transport?.clearBoundary()
    }
    public func prepare(_ meeting: LibraryMeeting, autoplay: Bool = false) {
        guard meeting.canPlaySession, key != meeting.libraryKey else { return }
        stop(); Self.active?.stop(); Self.active = self
        key = meeting.libraryKey; sources = meeting.audioTracks; isPreparing = true
        pendingDuration = meeting.durationMs.map { max(0,Double($0)) }
        userPaused = !autoplay; wantsPlay = autoplay
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
                    self.listener?.positionChanged(ms)
                }
                transport.setRate(self.rate)
                self.isPlaying = self.wantsPlay
                if let position = self.requestedPosition { self.seek(toMs: position,following:false) }
                else if self.wantsPlay { transport.play() }
            } catch is CancellationError {
                if let self, current == self.generation { self.stop() }
            }
            catch { self?.failed(error, generation: current) }
        }
    }
    public func seek(toMs: Double) {
        seek(toMs:toMs,following:true)
    }
    private func seek(toMs: Double, following: Bool) {
        guard toMs.isFinite else { return }
        let limit = timeline?.durationMs ?? pendingDuration ?? Double.greatestFiniteMagnitude
        let target = min(limit,max(0,toMs))
        spanEnded = false
        if following {
            if let listener { replaceSpan(listener.follow(target)) }
            else if let span, target >= span.endMs { replaceSpan(nil) }
        }
        requestedPosition = target; positionMs = target
        guard let transport else { return }
        seekSerial += 1
        let serial = seekSerial, current = generation
        rewinding = true; transport.clearBoundary(); transport.pause()
        transport.seek(toMs: target) { [weak self] finished in
            guard let self, current == self.generation, serial == self.seekSerial else { return }
            self.rewinding = false
            guard finished else { self.failed(CocoaError(.fileReadUnknown), generation: current); return }
            self.installBoundary(generation:current,seek:serial)
            guard current == self.generation, serial == self.seekSerial else { return }
            if self.wantsPlay { transport.play(); self.isPlaying = true }
        }
    }
    private func installBoundary(generation current: Int, seek serial: Int) {
        guard wantsPlay, let span, let transport else { return }
        let end = min(span.endMs,durationMs), token = spanSerial
        guard end > playheadMs else { completeSpan(generation:current,seek:serial,token:token,end:end); return }
        transport.setBoundary(atMs:end) { [weak self] in
            self?.completeSpan(generation:current,seek:serial,token:token,end:end)
        }
    }
    private func completeSpan(generation current: Int, seek serial: Int, token: Int, end: Double) {
        guard current == generation, serial == seekSerial, token == spanSerial, !rewinding, wantsPlay, let span else { return }
        wantsPlay = false; isPlaying = false; positionMs = end; requestedPosition = end
        replaceSpan(nil); spanEnded = true
        transport?.pause()
        span.done()
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
        guard current == generation, !rewinding, !userPaused, let transport else { return }
        if let span {
            guard wantsPlay, transport.positionMs >= min(span.endMs,durationMs)-SessionBoundary.toleranceMs else { return }
            completeSpan(generation:current,seek:seekSerial,token:spanSerial,end:min(span.endMs,durationMs)); return
        }
        guard !spanEnded else { return }
        if let listener {
            wantsPlay = false; isPlaying = false; spanEnded = true
            positionMs = durationMs; requestedPosition = positionMs; transport.pause()
            listener.playbackReachedEnd()
            return // listening never rewinds, including a free seek past its last turn
        }
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
        let listening = listener; listener = nil
        generation += 1
        lifetime.task?.cancel(); lifetime.task = nil
        transport?.close(); transport = nil; timeline = nil
        key = nil; sources = []; wantsPlay = false; rewinding = false
        requestedPosition = nil; pendingDuration = nil; positionMs = 0; seekSerial += 1
        isPlaying = false; isPreparing = false
        spanSerial += 1; span = nil; spanEnded = false
        listening?.playbackStopped()
        if Self.active === self { Self.active = nil }
    }
}
