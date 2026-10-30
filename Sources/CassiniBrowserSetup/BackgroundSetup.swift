// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

/// Stable, deliberately small failure vocabulary carried across the XPC boundary.
public enum BrowserSetupFailure: Int, Error, Sendable {
    case temporary = 1, noBrowser, unwritable, unsafe
    public static let domain = "io.codemyriad.cassini.browser-setup"
    public var retryable: Bool { self == .temporary }
    public var nsError: NSError { NSError(domain:Self.domain,code:rawValue) }
    public init(_ error: Error) {
        if let failure = error as? Self { self = failure; return }
        let value = error as NSError
        if value.domain == Self.domain, let failure = Self(rawValue:value.code) { self = failure; return }
        if let error = error as? BrowserSetupError {
            switch error {
            case .noBrowser: self = .noBrowser
            case .unsafePath, .invalidHost, .tooLarge: self = .unsafe
            case .unavailable: self = .temporary
            }
        } else if value.domain == NSPOSIXErrorDomain, [EACCES,EPERM,EROFS].contains(Int32(value.code)) {
            self = .unwritable
        } else if value.domain == NSCocoaErrorDomain,
                  [NSFileReadNoPermissionError,NSFileWriteNoPermissionError,NSFileWriteVolumeReadOnlyError].contains(value.code) {
            self = .unwritable
        } else { self = .temporary }
    }
}

public struct BrowserSetupBackoff: Sendable {
    public private(set) var seconds: Double = 5
    public init() {}
    public mutating func reset() { seconds = 5 }
    /// Jitter is sampled independently per attempt. The cap applies before jitter.
    public mutating func next(unit: Double) -> Double {
        let delay = seconds * (0.8 + 0.4 * min(1,max(0,unit)))
        seconds = min(300,seconds * 2)
        return delay
    }
}

/// Serial background work. Only state publication and scheduling use the UI
/// actor; even the synchronous prefix of an installer runs on a utility task.
@MainActor @Observable public final class BackgroundBrowserSetup {
    public enum State: Equatable, Sendable { case settingUp, waiting, failed(BrowserSetupFailure) }
    public private(set) var state: State = .settingUp
    @ObservationIgnored private let install: @Sendable () async throws -> Void
    @ObservationIgnored private let sleep: @Sendable (Double) async throws -> Void
    @ObservationIgnored private let random: @Sendable () -> Double
    @ObservationIgnored private var backoff = BrowserSetupBackoff()
    @ObservationIgnored private var attempt: Task<Void,Never>?
    @ObservationIgnored private var timer: Task<Void,Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var again = false
    @ObservationIgnored private var stopped = false

    public init(install: @escaping @Sendable () async throws -> Void,
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for:.seconds($0)) },
                random: @escaping @Sendable () -> Double = { Double.random(in:0...1) }) {
        self.install = install; self.sleep = sleep; self.random = random
    }
    /// Launch, activation, update/move or explicit Try again all reset the delay.
    /// Events during a write coalesce into one follow-up rather than overlap it.
    public func trigger() {
        guard !stopped else { return }
        generation &+= 1; timer?.cancel(); timer = nil; backoff.reset()
        if attempt != nil { again = true; return }
        run()
    }
    public func stop() {
        stopped = true; generation &+= 1; timer?.cancel(); timer = nil; attempt?.cancel()
    }
    private func run() {
        state = .settingUp
        let install = self.install
        attempt = Task { [weak self] in
            let worker = Task.detached(priority:.utility) { try await install() }
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self else { return }
            self.attempt = nil
            guard !self.stopped else { return }
            if self.again { self.again = false; self.run(); return }
            switch result {
            case .success: self.state = .waiting; self.backoff.reset()
            case .failure(let error):
                let failure = BrowserSetupFailure(error)
                self.state = .failed(failure)
                if failure.retryable { self.schedule() }
            }
        }
    }
    private func schedule() {
        let delay = backoff.next(unit:random()), generation = self.generation, sleep = self.sleep
        timer = Task { [weak self] in
            do { try await sleep(delay); try Task.checkCancellation() } catch { return }
            guard let self, !self.stopped, self.generation == generation else { return }
            self.timer = nil; self.run()
        }
    }
}
