// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Testable seam over `AudioProcessTap` for native system-audio capture.
public protocol SystemAudioTap: AnyObject, Sendable {
    func start(
        onFormatChange: @escaping @Sendable () -> Void,
        receive: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void
    ) throws
    func stop()
}

/// Manages a system-audio tap on a dedicated serial executor so Core Audio teardown
/// and recreation during output-device / Bluetooth reconfiguration never block the
/// main actor (including Stop). Generation checks ensure a Stop cancels any pending
/// or in-flight restart.
public final class OutputTapDriver: @unchecked Sendable {
    private let makeTap: @Sendable () -> any SystemAudioTap
    private let executor: DispatchQueue
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var stopped = true
    private var failed = false

    // Accessed exclusively on `executor`.
    private var activeTap: (any SystemAudioTap)?
    private var activeTapID: UInt64 = 0

    public init(
        makeTap: @escaping @Sendable () -> any SystemAudioTap,
        queueLabel: String = "io.codemyriad.cassini.output-tap-lifecycle"
    ) {
        self.makeTap = makeTap
        self.executor = DispatchQueue(label: queueLabel, qos: .userInitiated)
    }

    public func start(
        sink: RecordingSink,
        label: String,
        changedMessage: String,
        failure: @escaping @Sendable (String) -> Void
    ) throws {
        let currentGeneration: UInt64 = lock.withLock {
            generation &+= 1
            stopped = false
            failed = false
            return generation
        }
        do {
            try executor.sync {
                if let existing = activeTap {
                    existing.stop()
                    activeTap = nil
                }
                guard isActive(generation: currentGeneration) else { return }
                let tapID = nextTapID()
                let tap = makeTap()
                try startTap(
                    tap,
                    tapID: tapID,
                    generation: currentGeneration,
                    sink: sink,
                    label: label,
                    changedMessage: changedMessage,
                    failure: failure
                )
                guard isActive(generation: currentGeneration) else {
                    tap.stop()
                    return
                }
                activeTap = tap
                activeTapID = tapID
            }
        } catch {
            stop()
            throw error
        }
    }

    /// Non-blocking: immediately invalidates the active generation so any queued or
    /// in-flight restart aborts, and schedules tap teardown on the serial executor.
    public func stop() {
        lock.withLock {
            generation &+= 1
            stopped = true
        }
        executor.async { [self] in
            if let tap = activeTap {
                tap.stop()
                activeTap = nil
            }
            activeTapID = 0
        }
    }

    /// Waits for all queued lifecycle operations on the serial executor to complete.
    public func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            executor.async {
                continuation.resume()
            }
        }
    }

    private func isActive(generation expected: UInt64) -> Bool {
        lock.withLock { !stopped && !failed && generation == expected }
    }

    private func nextTapID() -> UInt64 {
        activeTapID &+= 1
        if activeTapID == 0 { activeTapID = 1 }
        return activeTapID
    }

    private func startTap(
        _ tap: any SystemAudioTap,
        tapID: UInt64,
        generation expected: UInt64,
        sink: RecordingSink,
        label: String,
        changedMessage: String,
        failure: @escaping @Sendable (String) -> Void
    ) throws {
        try tap.start(
            onFormatChange: { [weak self] in
                self?.scheduleRestart(
                    tapID: tapID,
                    generation: expected,
                    sink: sink,
                    label: label,
                    changedMessage: changedMessage,
                    failure: failure
                )
            },
            receive: { [weak self] buffer, host in
                guard let self, self.isActive(generation: expected) else { return }
                sink.receive(buffer, hostTime: host, id: "output", label: label, kind: "system")
            }
        )
    }

    private func scheduleRestart(
        tapID: UInt64,
        generation expected: UInt64,
        sink: RecordingSink,
        label: String,
        changedMessage: String,
        failure: @escaping @Sendable (String) -> Void
    ) {
        guard isActive(generation: expected) else { return }
        executor.async { [weak self] in
            guard let self else { return }
            guard self.isActive(generation: expected), self.activeTapID == tapID else { return }
            if let existing = self.activeTap {
                existing.stop()
                self.activeTap = nil
            }
            guard self.isActive(generation: expected) else {
                self.activeTapID = 0
                return
            }
            let nextID = self.nextTapID()
            let nextTap = self.makeTap()
            do {
                try self.startTap(
                    nextTap,
                    tapID: nextID,
                    generation: expected,
                    sink: sink,
                    label: label,
                    changedMessage: changedMessage,
                    failure: failure
                )
                guard self.isActive(generation: expected) else {
                    nextTap.stop()
                    self.activeTapID = 0
                    return
                }
                self.activeTap = nextTap
                self.activeTapID = nextID
            } catch {
                let shouldReport: Bool = self.lock.withLock {
                    guard !self.stopped, !self.failed, self.generation == expected else { return false }
                    self.failed = true
                    self.stopped = true
                    self.generation &+= 1
                    return true
                }
                self.activeTapID = 0
                if shouldReport {
                    failure(changedMessage)
                }
            }
        }
    }

    deinit {
        let tap = activeTap
        activeTap = nil
        tap?.stop()
    }
}
