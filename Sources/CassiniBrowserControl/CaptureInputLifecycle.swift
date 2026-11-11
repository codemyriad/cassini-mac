// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AVFoundation
import CassiniRecording

/// A single native side. The production microphone and system drivers are
/// separate objects; a device-free test can drive these same sink lifetimes.
@MainActor public protocol CaptureInput: AnyObject {
    func authorize() async throws
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws
    func stop()
}

/// Invalidated on the main actor, checked again on the owner's serial I/O queue.
private final class SourceChangeToken: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.withLock { valid } }
    func invalidate() { lock.withLock { valid = false } }
    func check() throws { if !isValid { throw CancellationError() } }
}

/// Owns native admission for one meeting, never a global device/session. Disk
/// drains run outside the main actor and before a source's off transition.
@MainActor public final class CaptureInputLifecycle {
    private struct Input {
        let generation: UUID
        let driver: any CaptureInput
        let sink: RecordingSink
        var paused = false
        var stage: StagedNativeWriter? = nil
        /// D58: this generation's first-buffer admission, and the time it is refused at if an
        /// explicit error ends it before that first buffer (D58.1: a start side, a turn-on, or
        /// the browser fallback's system input; nil for any other attempt).
        var firstBuffer: FirstBufferSignal? = nil
        var refusingAt: Double? = nil
    }
    private let capture: OwnedBrowserCapture
    private let origin: UInt64
    // Injectable host clock for deterministic event-stamp tests, never a UI counter.
    var hostTime: () -> UInt64 = { mach_absolute_time() }
    private let microphone: @MainActor () -> any CaptureInput
    private let system: @MainActor () -> any CaptureInput
    private let failure: @Sendable (String) -> Void
    private let admission: @MainActor () -> Bool
    private let inputGate: BrowserSignalInputGate?
    private var inputs: [CaptureSide:Input] = [:]
    private var tail: Task<Void,Never>?
    private var closed = false
    private var stopping: Task<Void,Error>?
    private struct Authorization {
        let side: CaptureSide
        let source: SourceChangeToken?
        let continuation: CheckedContinuation<Void,Error>
    }
    private var authorizations: [UUID:Authorization] = [:]
    private var permissionTasks: [CaptureSide:UUID] = [:]
    private var sourceChange = SourceChangeToken()
    public private(set) var sourceRevision: UInt64 = 0
    /// Release only automatic source waiters. The OS request can finish later;
    /// it is shared by any subsequent request for the same native side.
    public func cancelSourceChange() {
        sourceChange.invalidate(); sourceChange = SourceChangeToken(); sourceRevision &+= 1
        let cancelled = authorizations.filter { $0.value.source != nil }
        for (id,request) in cancelled {
            authorizations.removeValue(forKey:id)
            request.continuation.resume(throwing:CancellationError())
        }
    }
    private func token(for revision: UInt64?) throws -> SourceChangeToken {
        guard revision == nil || revision == sourceRevision else { throw CancellationError() }
        return sourceChange
    }
    public func observeBrowserLoss(atMs: Double, transportAlive: Bool, revision: UInt64) async throws {
        let token = try token(for:revision), capture = capture
        try await Task.detached {
            try capture.browserLost(atMs:atMs,transportAlive:transportAlive,allowed:{ token.isValid })
        }.value
    }
    public private(set) var failedSides: Set<CaptureSide> = [] { didSet { observer?() } }
    /// Called on every change of the side sets below, and after each refusal is delivered
    /// (tests wait on it instead of polling, E1).
    var observer: (@MainActor () -> Void)?
    // Internal event fences after registration and after a failure callback settles.
    var authorizationWaiting: (@MainActor () -> Void)?
    var failureHandled: (@MainActor () -> Void)?
    var authorizationHandled: (@MainActor () -> Void)?
    public var hasRunningInputs: Bool { inputs.keys.contains { !failedSides.contains($0) } }
    /// D58: sides that admitted a first buffer at least once in this recording.
    public private(set) var openedSides: Set<CaptureSide> = [] { didSet { observer?() } }
    /// Sides whose opening bound passed before a first buffer (terminal for that attempt).
    private(set) var expiredSides: Set<CaptureSide> = [] { didSet { observer?() } }
    /// D58: the refusal code of each side refused at start or at its last turn-on attempt.
    public private(set) var refusedSides: [CaptureSide:String] = [:] { didSet { observer?() } }
    /// D58.1: the others' side was refused because macOS denied permission. Only then does the UI
    /// ask the user to allow recording this computer's sound; any other failure is unavailable.
    public var othersDenied: Bool { refusedSides[.others] == CaptureRefusal.permissionDenied }
    /// The 3 s first-buffer bound (D58); tests replace it with an event they control.
    public static let openBound: @Sendable () async -> Void = { try? await Task.sleep(for:.seconds(3)) }
    private let bound: @Sendable () async -> Void
    private let refused: @MainActor (CaptureSide,CaptureRefusal) -> Void
    public init(capture: OwnedBrowserCapture, originHostTime: UInt64,
                microphone: @escaping @MainActor () -> any CaptureInput,
                system: @escaping @MainActor () -> any CaptureInput,
                failure: @escaping @Sendable (String) -> Void,
                refused: @escaping @MainActor (CaptureSide,CaptureRefusal) -> Void = { _,_ in },
                openBound: @escaping @Sendable () async -> Void = CaptureInputLifecycle.openBound,
                admission: @escaping @MainActor () -> Bool = { true }, inputGate: BrowserSignalInputGate? = nil) {
        self.inputGate = inputGate
        self.admission = admission
        self.capture = capture; origin = originHostTime
        self.microphone = microphone; self.system = system; self.failure = failure
        self.refused = refused; bound = openBound
    }
    /// Records a side that never opened. Refusals write no event or track and never change
    /// state, problem, othersSource or the outcome, so `failure` (which can) is not called.
    private func refuse(_ side: CaptureSide, _ reason: CaptureOpenRefusal, atMs: Double) async {
        guard let entry = CaptureRefusal(atMs:atMs,side:side == .me ? "me" : "others",code:reason.code,
                                         message:reason.code == CaptureRefusal.permissionDenied ? nil : reason.message) else { return }
        refusedSides[side] = reason.code
        let capture = capture
        try? await Task.detached { try capture.refuse(entry) }.value
        refused(side,entry)
        observer?()
    }
    /// A failure to open, not a closed recording, a cancelled source change or a stale request.
    private static func isOpenFailure(_ error: Error) -> Bool {
        !(error is CancellationError) && (error as? BrowserIPCError) != .closed
    }
    /// Opens the requested native sides. A side that fails to open, or admits no buffer within
    /// the 3 s bound, is refused at 0 (D58) and stays unopened; the others keep recording.
    public func start() async throws { try await enqueue { try await self.reconcile(refusingAt:0) } }
    /// Browser loss only requests a system input when Others is selected. A
    /// management reconnect never restarts browser capture or switches it back.
    /// #140 review: every attempt is judged on its own generation, so an explicit error before an
    /// updated or retried input's first buffer is a refusal at the time it was attempted (D58.1).
    public func update() async throws { try await enqueue { try await self.reconcile(refusingAt:self.recordingMs()) } }
    /// Returns the sides whose turn-on was refused (D58), with their codes. A refused turn-on
    /// leaves that side's selection unchanged and writes no selection event for it.
    /// Stamp a person’s action from the recording clock without truncating it
    /// through the whole-millisecond counter used by UI labels.
    @discardableResult
    public func select(me: Bool, others: Bool) async throws -> [CaptureSide:String] {
        try await select(me:me,others:others,atMs:recordingMs())
    }
    @discardableResult
    public func select(me: Bool, others: Bool, atMs: Double) async throws -> [CaptureSide:String] {
        guard atMs.isFinite, atMs >= 0, me || others else { throw RecordingError.invalid("Invalid recording selection.") }
        cancelSourceChange()
        let selectionToken = capture.snapshot.managedBrowser ? sourceChange : nil
        let requested = hostTime()
        let refusedNow = RefusedTurnOns()
        try await enqueue {
            guard !self.closed, self.capture.snapshot.phase == .recording else { throw BrowserIPCError.closed }
            let before = self.capture.snapshot
            var prepared: [CaptureSide:Input] = [:]
            var paused: Set<CaptureSide> = []
            let previousFailures = self.failedSides
            var me = me, others = others
            do {
                // Each side opens on its own: a refused turn-on keeps that side as it was.
                if others && !before.browserAlive && !before.restoreReady && (self.inputs[.others] == nil || self.failedSides.contains(.others)) {
                    prepared[.others] = try await self.turnOn(.others,turningOn:!before.others,into:refusedNow) {
                        try await self.prepare(.others,driver:self.system(),source:selectionToken,refusingAt:atMs)
                    }
                }
                if self.capture.nativeMe && me && (self.inputs[.me] == nil || self.failedSides.contains(.me)) {
                    prepared[.me] = try await self.turnOn(.me,turningOn:!before.me,into:refusedNow) {
                        try await self.prepare(.me,driver:self.microphone(),refusingAt:atMs)
                    }
                }
                if refusedNow.sides[.me] != nil { me = before.me }
                if refusedNow.sides[.others] != nil { others = before.others }
                // A selection never ends with nothing: when a refusal would leave no side, the
                // previous selection stands whole and only the refusal is recorded.
                if !me && !others { me = before.me; others = before.others }
                guard !self.closed else { throw BrowserIPCError.closed }
                if !refusedNow.sides.isEmpty, prepared.isEmpty, me == before.me, others == before.others {
                    for (side,reason) in refusedNow.ordered { await self.refuse(side,reason,atMs:atMs) }
                    return
                }
                for side in prepared.keys where self.failedSides.contains(side) { try await self.end(side) }
                for side in [CaptureSide.me,.others] where (side == .me ? !me : !others) && self.inputs[side] != nil {
                    let value = self.inputs[side]!
                    self.inputs[side]?.paused = true; paused.insert(side)
                    value.driver.stop()
                    let sink = value.sink
                    try await Task.detached { try sink.pause() }.value
                }
                guard !self.closed else { throw BrowserIPCError.closed }
                guard prepared.values.allSatisfy({ $0.stage?.recordingProblem == nil }) else {
                    throw RecordingError.invalid("The new audio input stopped before the selection could be applied.")
                }
                if prepared[.others] != nil { try selectionToken?.check() }
                let finished = self.hostTime()
                let appliedAt = atMs + (finished > requested ? AVAudioTime.seconds(forHostTime:finished-requested)*1000 : 0)
                try await self.capture.select(me:me,others:others,atMs:appliedAt,reservingNative:Set(prepared.keys))
            } catch {
                for value in prepared.values { await self.discard(value) }
                if !self.closed {
                    self.failedSides = previousFailures
                    for side in paused {
                        guard let value = self.inputs[side] else { continue }
                        do {
                            try value.sink.resume()
                            try self.startDriver(value.driver,sink:value.sink,failure:self.report(side,generation:value.generation,stage:value.stage))
                            self.inputs[side]?.paused = false
                        } catch { await self.restartFailed(side,value,error) }
                    }
                }
                throw error
            }
            // Selection is committed. Old inputs were drained without closing
            // their files, and can now be retired without losing their tail.
            for side in paused { do { try await self.end(side) } catch { self.failure(error.localizedDescription) } }
            for (side,value) in prepared {
                guard !self.closed else { await self.discard(value); continue }
                self.inputs[side] = value; self.failedSides.remove(side)
                // D58.1: a system input that has heard nothing yet opens on its first buffer.
                self.opens(side,value)
                guard let stage = value.stage else { continue }
                let writer = self.capture.nativeWriter(side:side)
                do { try await Task.detached { try stage.activate(writer) }.value }
                catch { self.report(side,generation:value.generation,stage:stage)(error.localizedDescription) }
            }
            for (side,reason) in refusedNow.ordered { await self.refuse(side,reason,atMs:atMs) }
        }
        return refusedNow.sides.mapValues(\.code)
    }
    /// A side's open attempt during a selection. A failed turn-on (not a closed recording, a
    /// cancelled source change or a stale request) is refused instead of failing the selection.
    private func turnOn(_ side: CaptureSide, turningOn: Bool, into refused: RefusedTurnOns,
                        _ make: @MainActor () async throws -> Input) async throws -> Input? {
        do { return try await make() }
        catch {
            guard turningOn, !closed, Self.isOpenFailure(error) else { throw error }
            refused.sides[side] = CaptureOpenRefusal.classify(error)
            return nil
        }
    }
    /// Stage computer sound without disturbing the microphone. Failed device
    /// authorization/start cannot publish a system source or its samples.
    public func fallback(revision: UInt64? = nil) async throws {
        let token = try token(for:revision)
        try await enqueue { try await self.startFallback(token:token) }
    }
    private func startFallback(token: SourceChangeToken) async throws {
        try token.check()
        guard !self.closed, self.capture.snapshot.phase == .recording,
              self.capture.snapshot.others, !self.capture.snapshot.browserAlive,
              self.inputs[.others] == nil else { return }
        let candidate: Input, at = recordingMs()
        do { candidate = try await self.prepare(.others,driver:self.system(),source:token,refusingAt:at) }
        catch {
            if !self.closed, !(error is CancellationError) {
                self.failedSides.insert(.others)
                // D58.1: an explicit open failure of the fallback's system input is recorded as a
                // refusal, so a permission denial reads as one and anything else as unavailable.
                if Self.isOpenFailure(error) { await self.refuse(.others,CaptureOpenRefusal.classify(error),atMs:at) }
            }
            throw error
        }
        do {
            try token.check()
            guard !self.closed, candidate.stage?.recordingProblem == nil else { throw BrowserIPCError.closed }
            try await self.capture.requestSystemFallback(allowed:{ token.isValid })
            try token.check()
            self.inputs[.others] = candidate; self.failedSides.remove(.others)
            self.opens(.others,candidate)
            if let stage = candidate.stage {
                try await self.capture.activateNative(stage,side:.others,allowed:{ token.isValid })
            }
        } catch {
            if error is CancellationError {
                self.inputs.removeValue(forKey:.others)
                await self.discard(candidate)
            } else if self.inputs[.others]?.generation == candidate.generation {
                self.report(.others,generation:candidate.generation,stage:candidate.stage)(error.localizedDescription)
            } else {
                await self.discard(candidate)
                if !self.closed { self.failedSides.insert(.others) }
            }
            throw error
        }
    }
    /// The original browser transport must have a returned source. Pause only
    /// this meeting's computer sound; a rejected checkpoint resumes its exact
    /// existing writer/clock, without stopping or replacing the microphone.
    public func restoreBrowser(atMs: Double, notBeforeMs: Double? = nil, revision: UInt64? = nil) async throws {
        guard atMs.isFinite, atMs >= 0, notBeforeMs.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw RecordingError.invalid("Invalid restoration time.") }
        let token = try token(for:revision)
        let requested = ProcessInfo.processInfo.systemUptime
        try await enqueue {
            try token.check()
            guard !self.closed, self.capture.snapshot.phase == .recording,
                  self.capture.snapshot.others, self.capture.snapshot.restoreReady,
                  self.capture.snapshot.browserReturnPCMAt.map({ $0 >= (notBeforeMs ?? 0) }) == true else { throw BrowserIPCError.closed }
            let input = self.inputs[.others]
            do {
                if let input {
                    self.inputs[.others]?.paused = true; input.driver.stop()
                    let sink = input.sink
                    try await Task.detached { try sink.pause() }.value
                }
                guard !self.closed else { throw BrowserIPCError.closed }
                let appliedAt = atMs + max(0,ProcessInfo.processInfo.systemUptime-requested)*1000
                try token.check()
                try await self.capture.restoreBrowser(atMs:appliedAt,notBeforeMs:notBeforeMs,allowed:{ token.isValid })
            } catch {
                if !self.closed, let input {
                    do {
                        try input.sink.resume()
                        try self.startDriver(input.driver,sink:input.sink,failure:self.report(.others,generation:input.generation,stage:input.stage))
                        self.inputs[.others]?.paused = false
                    } catch { await self.restartFailed(.others,input,error) }
                }
                throw error
            }
            try await self.end(.others)
        }
    }
    private func prepare(_ side: CaptureSide, driver: any CaptureInput, source: SourceChangeToken? = nil, refusingAt atMs: Double? = nil) async throws -> Input {
        try await authorize(driver,side:side,source:source)
        try source?.check()
        guard !closed else { throw BrowserIPCError.closed }
        guard admission() else { throw CancellationError() }
        let generation = UUID(), stage = StagedNativeWriter(observers:capture.pcmObservers), signal = FirstBufferSignal()
        let report = report(side,generation:generation,stage:stage)
        let sink = RecordingSink(session:stage,originHostTime:origin,onFailure:report,admit:{ signal.admit() })
        let value = Input(generation:generation,driver:driver,sink:sink,stage:stage,firstBuffer:signal,refusingAt:atMs)
        do {
            try startDriver(driver,sink:sink,failure:report)
            await Task.detached { sink.flush() }.value
            // D58: the side opened only once its first buffer is admitted within the bound.
            // D58.1: the others' side (the system tap) is never refused for silence or a missing
            // buffer: a quiet Mac or a quiet call is the normal case. It stays armed and records
            // from its first buffer, however late; only an explicit error refuses it.
            if side == .me, !signal.hasFired {
                guard await signal.wait(bound:bound) else { throw CaptureOpenRefusal.noSample }
                await Task.detached { sink.flush() }.value
            }
            try source?.check()
            guard !closed, stage.recordingProblem == nil else { throw RecordingError.invalid("The new audio input could not start.") }
            return value
        } catch { await discard(value); throw error }
    }
    /// A paused input whose restart failed during a rollback. One that never admitted a buffer
    /// never opened (D58.1): it is refused at its attempt time, without a recording failure.
    private func restartFailed(_ side: CaptureSide, _ value: Input, _ error: Error) async {
        guard let atMs = value.refusingAt, let signal = value.firstBuffer, !signal.hasFired else {
            failedSides.insert(side); failure(error.localizedDescription); return
        }
        try? await end(side,unopened:true)
        failedSides.insert(side)
        await refuse(side,CaptureOpenRefusal.classify(error),atMs:atMs)
    }
    /// D58.1: a committed input counts as opened only once it admitted a buffer; until then a
    /// pre-buffer error is a refusal (`failed`), and the first buffer opens it however late.
    private func opens(_ side: CaptureSide, _ value: Input) {
        guard let signal = value.firstBuffer, !signal.hasFired else {
            openedSides.insert(side); refusedSides.removeValue(forKey:side); return
        }
        watchFirstBuffer(side,generation:value.generation,signal:signal,refusingAt:value.refusingAt)
    }
    /// Milliseconds since the recording's host-time origin: the time of a refusal that no
    /// selection stamps (the browser fallback's system input).
    private func recordingMs() -> Double {
        let now = hostTime()
        return now > origin ? AVAudioTime.seconds(forHostTime:now - origin) * 1000 : 0
    }
    private func discard(_ value: Input) async {
        value.driver.stop(); value.stage?.discard()
        let sink = value.sink
        // Never committed: its failure, if any, is the refusal's, not the recording's.
        try? await Task.detached { try sink.finishUnopened() }.value
    }
    private func report(_ side: CaptureSide, generation: UUID, stage: StagedNativeWriter? = nil) -> @Sendable (String) -> Void {
        { [weak self] message in
            stage?.fail(message)
            Task { @MainActor in
                await self?.failed(side,generation:generation,message:message)
                self?.failureHandled?()
            }
        }
    }
    public func stop() async throws {
        closed = true
        cancelSourceChange()
        let waiting = Array(authorizations.values); authorizations.removeAll()
        for request in waiting { request.continuation.resume(throwing:BrowserIPCError.closed) }
        if let stopping { try await stopping.value; return }
        let task = Task { @MainActor in
            try await self.enqueue {
                var first: Error?
                // #120 r3: a start side whose sink failed before admitting a buffer (an
                // unsupported first buffer just before Stop) never opened, whether or not its
                // failure handler has run: it is refused here, after its quiet drain in end().
                // #140 review: judged by this input generation's own first buffer, not by whether
                // the side opened earlier in the recording.
                var refusing: [(CaptureSide,Double)] = []
                for side in [CaptureSide.me,.others] {
                    if let input = self.inputs[side], let atMs = input.refusingAt, let signal = input.firstBuffer, !signal.hasFired,
                       input.sink.hasFailed { refusing.append((side,atMs)) }
                    do { try await self.end(side) } catch { first = first ?? error }
                }
                for (side,atMs) in refusing { await self.refuse(side,.init(code:CaptureRefusal.deviceUnavailable),atMs:atMs) }
                if let first { throw first }
            }
        }
        stopping = task
        try await task.value
    }
    /// The OS request can outlive Stop. Only this waiter is cancelled: a late
    /// reply cannot start a driver or prevent existing inputs from draining.
    private func authorize(_ driver: any CaptureInput, side: CaptureSide, source: SourceChangeToken? = nil) async throws {
        guard !closed else { throw BrowserIPCError.closed }
        try source?.check()
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            authorizations[id] = .init(side:side,source:source,continuation:continuation)
            guard permissionTasks[side] == nil else { authorizationWaiting?(); return }
            let taskID = UUID(); permissionTasks[side] = taskID
            Task { @MainActor [weak self] in
                guard self?.permissionTasks[side] == taskID,
                      self?.authorizations.values.contains(where:{ $0.side == side }) == true else {
                    if self?.permissionTasks[side] == taskID { self?.permissionTasks.removeValue(forKey:side) }
                    return
                }
                defer { self?.authorizationHandled?() }
                // The waiter has joined an existing request or the OS task has
                // entered. Observing before this point can cancel an unstarted task.
                self?.authorizationWaiting?()
                let result: Result<Void,Error>
                do { try await driver.authorize(); result = .success(()) }
                catch { result = .failure(error) }
                guard let self, self.permissionTasks[side] == taskID else { return }
                self.permissionTasks.removeValue(forKey:side)
                let waiting = self.authorizations.filter { $0.value.side == side }
                for (id,request) in waiting {
                    self.authorizations.removeValue(forKey:id)
                    if request.source?.isValid == false { request.continuation.resume(throwing:CancellationError()) }
                    else { request.continuation.resume(with:result) }
                }
            }
        }
    }
    public func retry(_ side: CaptureSide) async throws {
        let token = sourceChange
        try await enqueue {
            guard !self.closed, self.capture.snapshot.phase == .recording,
                  side == .me ? self.capture.snapshot.me : self.capture.snapshot.others else { return }
            if side == .others { try token.check() }
            try await self.end(side)
            // A new attempt: an earlier attempt's refusal code no longer describes this side.
            self.refusedSides.removeValue(forKey:side)
            if side == .others, self.capture.snapshot.managedBrowser, !self.capture.snapshot.browserAlive {
                try await self.startFallback(token:token)
            } else { try await self.reconcile(refusingAt:self.recordingMs()) }
        }
    }
    public typealias Status = (levels: [String:Float],frames: [String:UInt64],droppedMs: Double,gapMs: Double,warnings: [String])
    public func status() -> [CaptureSide:Status] {
        inputs.mapValues { $0.sink.status() }
    }
    private func reconcile(preparedMicrophone: (any CaptureInput)? = nil, refusingAt atMs: Double? = nil) async throws {
        if closed { if !admission() { throw CancellationError() }; return }
        guard capture.snapshot.phase == .recording else { return }
        var first: Error?
        // A start side that never opened is refused (D58); any later failure keeps its P10 path.
        // Both start sides are attempted together, so their refusals are written me first.
        var refusing: [CaptureSide:CaptureOpenRefusal] = [:]
        func noteFailure(_ side: CaptureSide, _ error: Error, opened: Bool) {
            failedSides.insert(side)
            if atMs != nil, !opened, Self.isOpenFailure(error) {
                refusing[side] = CaptureOpenRefusal.classify(error)
            } else { first = first ?? error }
        }
        if !capture.snapshot.managedBrowser && capture.snapshot.needsSystem && inputs[.others] == nil && !failedSides.contains(.others) {
          let signal = FirstBufferSignal()
          do {
            guard !closed, admission() else { throw CancellationError() }
            let driver = system(); try await self.authorize(driver,side:.others)
            if closed { if !admission() { throw CancellationError() }; return }
            guard admission() else { throw CancellationError() }
            guard capture.snapshot.needsSystem else { return }
            try begin(.others,driver:driver,signal:signal,refusingAt:atMs)
          } catch {
              if error is CancellationError || (closed && !admission()) { throw CancellationError() }
              if closed { return }; noteFailure(.others,error,opened:signal.hasFired)
          }
        }
        if capture.nativeMe && capture.snapshot.me && inputs[.me] == nil && !failedSides.contains(.me) {
          let signal = FirstBufferSignal()
          do {
            guard !closed, admission() else { throw CancellationError() }
            let driver = preparedMicrophone ?? microphone()
            if preparedMicrophone == nil { try await self.authorize(driver,side:.me) }
            if closed { if !admission() { throw CancellationError() }; return }
            guard admission() else { throw CancellationError() }
            guard capture.snapshot.phase == .recording else { return }
            try begin(.me,driver:driver,signal:signal,refusingAt:atMs)
          } catch {
              if error is CancellationError || (closed && !admission()) { throw CancellationError() }
              if closed { return }; noteFailure(.me,error,opened:signal.hasFired)
          }
        }
        if let atMs {
            for (side,reason) in refusing.sorted(by:{ $0.key == .me && $1.key != .me }) { await refuse(side,reason,atMs:atMs) }
        }
        if let first { throw first }
    }
    private func startDriver(_ driver: any CaptureInput, sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws {
        if let inputGate { try inputGate.admit { try driver.start(sink:sink,failure:failure) } }
        else { try driver.start(sink:sink,failure:failure) }
    }
    private func begin(_ side: CaptureSide, driver: any CaptureInput, signal: FirstBufferSignal = FirstBufferSignal(), refusingAt atMs: Double? = nil) throws {
        guard admission(), capture.snapshot.phase == .recording else { throw CancellationError() }
        let generation = UUID()
        let report: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor in
                await self?.failed(side,generation:generation,message:message)
                self?.failureHandled?()
            }
        }
        let sink = RecordingSink(session:capture.nativeWriter(side:side),originHostTime:origin,onFailure:report,admit:{ signal.admit() })
        do { try startDriver(driver,sink:sink,failure:report); inputs[side] = .init(generation:generation,driver:driver,sink:sink,firstBuffer:signal,refusingAt:atMs) }
        catch {
            driver.stop()
            // Even a partially-started driver can have admitted callbacks.
            // Retain its sink for the caller's awaited stop/drain.
            inputs[side] = .init(generation:generation,driver:driver,sink:sink)
            throw error
        }
        watchFirstBuffer(side,generation:generation,signal:signal,refusingAt:atMs)
    }
    /// D58: a started side that admits no buffer within the bound never opened. At start it is
    /// refused and closed without a problem; otherwise only `openedSides` is updated.
    /// D58.1: the others' side has no bound. It opens on its first buffer, however late, and is
    /// refused only for an explicit error (`failed`), never for silence.
    private func watchFirstBuffer(_ side: CaptureSide, generation: UUID, signal: FirstBufferSignal, refusingAt atMs: Double?) {
        if side == .others {
            signal.onOpen { [weak self] in
                Task { @MainActor in
                    guard let self, self.inputs[side]?.generation == generation else { return }
                    self.openedSides.insert(side); self.refusedSides.removeValue(forKey:side)
                }
            }
            return
        }
        let bound = bound
        Task { @MainActor [weak self] in
            let opened = await signal.wait(bound:bound)
            guard let self else { return }
            if !opened, self.inputs[side]?.generation == generation { self.expiredSides.insert(side) }
            if opened {
                if self.inputs[side]?.generation == generation { self.openedSides.insert(side); self.refusedSides.removeValue(forKey:side) }
                return
            }
            guard let atMs else { return }
            try? await self.enqueue {
                guard !self.closed, self.inputs[side]?.generation == generation, !signal.hasFired else { return }
                try? await self.end(side,unopened:true)
                self.failedSides.insert(side)
                await self.refuse(side,.noSample,atMs:atMs)
            }
        }
    }
    private func failed(_ side: CaptureSide, generation: UUID, message: String) async {
        try? await enqueue {
            guard !self.closed, let input = self.inputs[side], input.generation == generation else { return }
            // D58 (#120 review): a start side that fails before its first buffer never opened.
            // It is refused and closed without a problem, and the recording is not failed.
            // #140 review: whether this input generation ever admitted a buffer decides, not whether
            // the side opened before: a re-enabled Others that fails in silence is a refusal too.
            if let atMs = input.refusingAt, let signal = input.firstBuffer, !signal.hasFired {
                try? await self.end(side,unopened:true)
                self.failedSides.insert(side)
                // The driver's text can be localized copy: the refusal carries none (D58).
                await self.refuse(side,.init(code:CaptureRefusal.deviceUnavailable),atMs:atMs)
                return
            }
            try? await self.end(side,problem:message)
            self.failedSides.insert(side)
            self.failure(message)
        }
    }
    /// `unopened`: a refused side that never admitted a buffer; its sink's own failure stays out
    /// of the recording (D58).
    private func end(_ side: CaptureSide, problem: String? = nil, unopened: Bool = false) async throws {
        failedSides.remove(side)
        guard let input = inputs.removeValue(forKey:side) else { return }
        if !input.paused { input.driver.stop() }
        let sink = input.sink
        // #120 r3: decided here, from the input's own first-buffer decision, not from whichever
        // callback ran first: an input that never admitted a buffer drains without its failure.
        let quiet = unopened || input.firstBuffer.map { !$0.hasFired } ?? false
        try await Task.detached(priority:.userInitiated) { quiet ? try sink.finishUnopened() : try sink.finish(problem:problem) }.value
    }
    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tail
        let task = Task { @MainActor in await previous?.value; try await operation() }
        tail = Task { _ = try? await task.value }
        try await task.value
    }
}

/// The turn-on refusals of one selection, written me first.
@MainActor private final class RefusedTurnOns {
    var sides: [CaptureSide:CaptureOpenRefusal] = [:]
    var ordered: [(CaptureSide,CaptureOpenRefusal)] { sides.sorted { $0.key == .me && $1.key != .me }.map { ($0.key,$0.value) } }
}
