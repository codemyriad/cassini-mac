// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniRecording

/// A single native side. The production microphone and system drivers are
/// separate objects; a device-free test can drive these same sink lifetimes.
@MainActor public protocol CaptureInput: AnyObject {
    func authorize() async throws
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws
    func stop()
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
    }
    private let capture: OwnedBrowserCapture
    private let origin: UInt64
    private let microphone: @MainActor () -> any CaptureInput
    private let system: @MainActor () -> any CaptureInput
    private let failure: @Sendable (String) -> Void
    private var inputs: [CaptureSide:Input] = [:]
    private var tail: Task<Void,Never>?
    private var closed = false
    private var stopping: Task<Void,Error>?
    private var authorizations: [UUID:CheckedContinuation<Void,Error>] = [:]
    public private(set) var failedSides: Set<CaptureSide> = []
    public var hasRunningInputs: Bool { inputs.keys.contains { !failedSides.contains($0) } }
    public init(capture: OwnedBrowserCapture, originHostTime: UInt64,
                microphone: @escaping @MainActor () -> any CaptureInput,
                system: @escaping @MainActor () -> any CaptureInput,
                failure: @escaping @Sendable (String) -> Void) {
        self.capture = capture; origin = originHostTime
        self.microphone = microphone; self.system = system; self.failure = failure
    }
    public func start() async throws { try await enqueue { try await self.reconcile() } }
    /// Browser loss only requests a system input when Others is selected. A
    /// management reconnect never restarts browser capture or switches it back.
    public func update() async throws { try await enqueue { try await self.reconcile() } }
    public func select(me: Bool, others: Bool, atMs: Double) async throws {
        guard atMs.isFinite, atMs >= 0, me || others else { throw RecordingError.invalid("Invalid recording selection.") }
        let requested = ProcessInfo.processInfo.systemUptime
        try await enqueue {
            guard !self.closed, self.capture.snapshot.phase == .recording else { throw BrowserIPCError.closed }
            let before = self.capture.snapshot
            var prepared: [CaptureSide:Input] = [:]
            var paused: Set<CaptureSide> = []
            let previousFailures = self.failedSides
            do {
                if others && !before.browserAlive && (self.inputs[.others] == nil || self.failedSides.contains(.others)) {
                    prepared[.others] = try await self.prepare(.others,driver:self.system())
                }
                if me && (self.inputs[.me] == nil || self.failedSides.contains(.me)) {
                    prepared[.me] = try await self.prepare(.me,driver:self.microphone())
                }
                guard !self.closed else { throw BrowserIPCError.closed }
                for side in prepared.keys where self.failedSides.contains(side) { try await self.end(side) }
                for side in [CaptureSide.me,.others] where (side == .me ? !me : !others) && self.inputs[side] != nil {
                    let value = self.inputs[side]!
                    self.inputs[side]?.paused = true; paused.insert(side)
                    value.driver.stop()
                    let sink = value.sink
                    try await Task.detached { try sink.pause() }.value
                }
                guard !self.closed else { throw BrowserIPCError.closed }
                let appliedAt = atMs + max(0,ProcessInfo.processInfo.systemUptime-requested)*1000
                try await self.capture.select(me:me,others:others,atMs:appliedAt,reservingNative:Set(prepared.keys))
            } catch {
                for value in prepared.values { await self.discard(value) }
                if !self.closed {
                    self.failedSides = previousFailures
                    for side in paused {
                        guard let value = self.inputs[side] else { continue }
                        do {
                            try value.sink.resume()
                            try value.driver.start(sink:value.sink,failure:self.report(side,generation:value.generation,stage:value.stage))
                            self.inputs[side]?.paused = false
                        } catch { self.failedSides.insert(side); self.failure(error.localizedDescription) }
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
                guard let stage = value.stage else { continue }
                let writer = self.capture.nativeWriter(side:side)
                do { try await Task.detached { try stage.activate(writer) }.value }
                catch { self.report(side,generation:value.generation,stage:stage)(error.localizedDescription) }
            }
        }
    }
    private func prepare(_ side: CaptureSide, driver: any CaptureInput) async throws -> Input {
        try await authorize(driver)
        guard !closed else { throw BrowserIPCError.closed }
        let generation = UUID(), stage = StagedNativeWriter()
        let report = report(side,generation:generation,stage:stage)
        let sink = RecordingSink(session:stage,originHostTime:origin,onFailure:report)
        let value = Input(generation:generation,driver:driver,sink:sink,stage:stage)
        do {
            try driver.start(sink:sink,failure:report)
            await Task.detached { sink.flush() }.value
            guard !closed, stage.recordingProblem == nil else { throw RecordingError.invalid("The new audio input could not start.") }
            return value
        } catch { await discard(value); throw error }
    }
    private func discard(_ value: Input) async {
        value.driver.stop(); value.stage?.discard()
        let sink = value.sink
        try? await Task.detached { try sink.finish(problem:nil) }.value
    }
    private func report(_ side: CaptureSide, generation: UUID, stage: StagedNativeWriter? = nil) -> @Sendable (String) -> Void {
        { [weak self] message in
            stage?.fail(message)
            Task { @MainActor in await self?.failed(side,generation:generation,message:message) }
        }
    }
    public func stop() async throws {
        closed = true
        let waiting = Array(authorizations.values); authorizations.removeAll()
        for request in waiting { request.resume(throwing:BrowserIPCError.closed) }
        if let stopping { try await stopping.value; return }
        let task = Task { @MainActor in
            try await self.enqueue {
                var first: Error?
                for side in [CaptureSide.me,.others] {
                    do { try await self.end(side) } catch { first = first ?? error }
                }
                if let first { throw first }
            }
        }
        stopping = task
        try await task.value
    }
    /// The OS request can outlive Stop. Only this waiter is cancelled: a late
    /// reply cannot start a driver or prevent existing inputs from draining.
    private func authorize(_ driver: any CaptureInput) async throws {
        guard !closed else { throw BrowserIPCError.closed }
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            authorizations[id] = continuation
            Task { @MainActor [weak self] in
                guard self?.authorizations[id] != nil else { return }
                let result: Result<Void,Error>
                do { try await driver.authorize(); result = .success(()) }
                catch { result = .failure(error) }
                self?.authorizations.removeValue(forKey:id)?.resume(with:result)
            }
        }
    }
    public func retry(_ side: CaptureSide) async throws {
        try await enqueue {
            guard !self.closed, self.capture.snapshot.phase == .recording,
                  side == .me ? self.capture.snapshot.me : self.capture.snapshot.others else { return }
            try await self.end(side)
            try await self.reconcile()
        }
    }
    public typealias Status = (levels: [String:Float],frames: [String:UInt64],droppedMs: Double,gapMs: Double,warnings: [String])
    public func status() -> [CaptureSide:Status] {
        inputs.mapValues { $0.sink.status() }
    }
    private func reconcile(preparedMicrophone: (any CaptureInput)? = nil) async throws {
        guard !closed, capture.snapshot.phase == .recording else { return }
        var first: Error?
        if capture.snapshot.needsSystem && inputs[.others] == nil && !failedSides.contains(.others) {
          do {
            let driver = system(); try await self.authorize(driver)
            guard !closed, capture.snapshot.needsSystem else { return }
            try begin(.others,driver:driver)
          } catch { if closed { return }; failedSides.insert(.others); first = first ?? error }
        }
        if capture.snapshot.me && inputs[.me] == nil && !failedSides.contains(.me) {
          do {
            let driver = preparedMicrophone ?? microphone()
            if preparedMicrophone == nil { try await self.authorize(driver) }
            guard !closed, capture.snapshot.phase == .recording else { return }
            try begin(.me,driver:driver)
          } catch { if closed { return }; failedSides.insert(.me); first = first ?? error }
        }
        if let first { throw first }
    }
    private func begin(_ side: CaptureSide, driver: any CaptureInput) throws {
        let generation = UUID()
        let report: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor in await self?.failed(side,generation:generation,message:message) }
        }
        let sink = capture.nativeSink(side:side,originHostTime:origin,failure:report)
        do { try driver.start(sink:sink,failure:report); inputs[side] = .init(generation:generation,driver:driver,sink:sink) }
        catch {
            driver.stop()
            // Even a partially-started driver can have admitted callbacks.
            // Retain its sink for the caller's awaited stop/drain.
            inputs[side] = .init(generation:generation,driver:driver,sink:sink)
            throw error
        }
    }
    private func failed(_ side: CaptureSide, generation: UUID, message: String) async {
        try? await enqueue {
            guard !self.closed, self.inputs[side]?.generation == generation else { return }
            try? await self.end(side,problem:message)
            self.failedSides.insert(side)
            self.failure(message)
        }
    }
    private func end(_ side: CaptureSide, problem: String? = nil) async throws {
        failedSides.remove(side)
        guard let input = inputs.removeValue(forKey:side) else { return }
        if !input.paused { input.driver.stop() }
        let sink = input.sink
        try await Task.detached(priority:.userInitiated) { try sink.finish(problem:problem) }.value
    }
    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tail
        let task = Task { @MainActor in await previous?.value; try await operation() }
        tail = Task { _ = try? await task.value }
        try await task.value
    }
}
