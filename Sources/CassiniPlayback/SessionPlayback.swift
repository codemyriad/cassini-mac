// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import CassiniLibrary

enum SessionTransportState { case paused, waiting, playing }
@MainActor protocol SessionTransport: AnyObject {
    var onState: ((SessionTransportState) -> Void)? { get set }
    var onEnd: (() -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    func play()
    func pause()
    func rewind(_ completion: @escaping @MainActor @Sendable (Bool) -> Void)
    func close()
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
    @ObservationIgnored public var onFailure: ((Error) -> Void)?
    @ObservationIgnored private let build: @Sendable ([LibraryAudioTrack]) async throws -> SessionTimeline
    @ObservationIgnored private let makeTransport: (SessionTimeline) -> any SessionTransport
    @ObservationIgnored private let lifetime = PreparationLifetime()
    @ObservationIgnored private var transport: (any SessionTransport)?
    @ObservationIgnored private var timeline: SessionTimeline?
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var sources: [LibraryAudioTrack] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var wantsPlay = false
    @ObservationIgnored private var rewinding = false
    private static weak var active: SessionPlayback?
    var preparation: Task<Void, Never>? { lifetime.task }

    public init() {
        build = { try await SessionComposition.make(tracks: $0) }
        makeTransport = { AVSessionTransport($0) }
    }
    init(build: @escaping @Sendable ([LibraryAudioTrack]) async throws -> SessionTimeline, makeTransport: @escaping (SessionTimeline) -> any SessionTransport) {
        self.build = build; self.makeTransport = makeTransport
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
        guard meeting.canPlaySession, !isPreparing else { return }
        if key == meeting.libraryKey, let transport {
            wantsPlay = true; isPlaying = true
            if !rewinding { transport.play() }
            return
        }
        stop(); Self.active?.stop(); Self.active = self
        key = meeting.libraryKey; sources = meeting.audioTracks; isPreparing = true
        let current = generation, builder = build
        lifetime.task = Task { [weak self] in
            do {
                let result = try await builder(meeting.audioTracks)
                try Task.checkCancellation()
                guard let self, current == self.generation else { return }
                let transport = self.makeTransport(result)
                self.timeline = result; self.transport = transport
                self.isPreparing = false; self.lifetime.task = nil
                transport.onState = { [weak self] state in self?.changed(state, generation: current) }
                transport.onEnd = { [weak self] in self?.ended(generation: current) }
                transport.onFailure = { [weak self] error in self?.failed(error, generation: current) }
                self.wantsPlay = true; self.isPlaying = true; transport.play()
            } catch is CancellationError {
                if let self, current == self.generation { self.stop() }
            }
            catch { self?.failed(error, generation: current) }
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
        transport.pause()
        transport.rewind { [weak self] finished in
            guard let self, current == self.generation else { return }
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
        isPlaying = false; isPreparing = false
        if Self.active === self { Self.active = nil }
    }
}
