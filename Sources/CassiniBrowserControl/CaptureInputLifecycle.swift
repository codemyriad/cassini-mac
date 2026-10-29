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
        let driver: any CaptureInput
        let sink: RecordingSink
    }
    private let capture: OwnedBrowserCapture
    private let origin: UInt64
    private let microphone: @MainActor () -> any CaptureInput
    private let system: @MainActor () -> any CaptureInput
    private let failure: @Sendable (String) -> Void
    private var inputs: [CaptureSide:Input] = [:]
    private var tail: Task<Void,Never>?
    private var closed = false
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
        let requested = ProcessInfo.processInfo.systemUptime
        try await enqueue {
            guard !self.closed, self.capture.snapshot.phase == .recording, me || others else { throw BrowserIPCError.closed }
            // Acquire permission before changing an otherwise working selection.
            var prepared: (any CaptureInput)?
            if me && !self.capture.snapshot.me {
                let driver = self.microphone(); try await driver.authorize(); prepared = driver
                guard !self.closed else { throw BrowserIPCError.closed }
            }
            if !me { try await self.end(.me) }
            if !others { try await self.end(.others) }
            let appliedAt = atMs + max(0,ProcessInfo.processInfo.systemUptime - requested)*1000
            try await self.capture.select(me:me,others:others,atMs:appliedAt)
            try await self.reconcile(preparedMicrophone:prepared)
        }
    }
    public func stop() async throws {
        closed = true // A pending permission reply cannot start a late input.
        try await enqueue {
            var first: Error?
            for side in [CaptureSide.me,.others] {
                do { try await self.end(side) } catch { first = first ?? error }
            }
            if let first { throw first }
        }
    }
    public typealias Status = (levels: [String:Float],frames: [String:UInt64],droppedMs: Double,warnings: [String])
    public func status() -> [CaptureSide:Status] {
        inputs.mapValues { $0.sink.status() }
    }
    private func reconcile(preparedMicrophone: (any CaptureInput)? = nil) async throws {
        guard !closed, capture.snapshot.phase == .recording else { return }
        if capture.snapshot.me && inputs[.me] == nil {
            let driver = preparedMicrophone ?? microphone()
            if preparedMicrophone == nil { try await driver.authorize() }
            guard !closed, capture.snapshot.phase == .recording else { return }
            try begin(.me,driver:driver)
        }
        if capture.snapshot.needsSystem && inputs[.others] == nil {
            let driver = system(); try await driver.authorize()
            guard !closed, capture.snapshot.needsSystem else { return }
            try begin(.others,driver:driver)
        }
    }
    private func begin(_ side: CaptureSide, driver: any CaptureInput) throws {
        let sink = capture.nativeSink(side:side,originHostTime:origin,failure:failure)
        do { try driver.start(sink:sink,failure:failure); inputs[side] = .init(driver:driver,sink:sink) }
        catch {
            driver.stop()
            // Even a partially-started driver can have admitted callbacks.
            // Retain its sink for the caller's awaited stop/drain.
            inputs[side] = .init(driver:driver,sink:sink)
            throw error
        }
    }
    private func end(_ side: CaptureSide) async throws {
        guard let input = inputs.removeValue(forKey:side) else { return }
        input.driver.stop()
        let sink = input.sink
        try await Task.detached(priority:.userInitiated) { try sink.finish(problem:nil) }.value
    }
    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tail
        let task = Task { @MainActor in await previous?.value; try await operation() }
        tail = Task { _ = try? await task.value }
        try await task.value
    }
}
