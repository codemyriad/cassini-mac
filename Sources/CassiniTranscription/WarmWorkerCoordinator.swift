// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniWhistle

/// Minimal teardown/liveness contract for a managed warm worker process.
public protocol WarmWorkerManaging: AnyObject, Sendable {
    var isAlive: Bool { get }
    func shutdown()
    func terminateImmediately()
}

extension WarmWorkerManaging {
    /// Runs `shutdown()` on a dedicated non-cooperative OS thread so blocking
    /// waits (`waitUntilExit`, pipe drains, or test gates) cannot starve the
    /// Swift Concurrency cooperative thread pool.
    public func shutdownAsync() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                self.shutdown()
                continuation.resume()
            }
        }
    }

    /// Runs `terminateImmediately()` on a dedicated non-cooperative OS thread so
    /// blocking waits cannot starve the Swift Concurrency cooperative thread pool.
    public func terminateImmediatelyAsync() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                self.terminateImmediately()
                continuation.resume()
            }
        }
    }
}

extension WarmSpeechWorker: WarmWorkerManaging {}

/// Serializes warm-worker startup, preemption, handoff release, and lifecycle
/// barriers (`pauseForMove`, `waitForShutdown`, model switch, cold transcription)
/// through a single retained teardown chain so at most one worker is alive at a time
/// and barriers never return while a previous child is still tearing down.
@MainActor
public final class WarmWorkerCoordinator<Worker: WarmWorkerManaging, Token: Sendable> {
    public struct Lease: Sendable {
        public let worker: Worker
        public let engine: String
        public let token: Token
        public let followingFolder: URL

        public init(worker: Worker, engine: String, token: Token, followingFolder: URL) {
            self.worker = worker
            self.engine = engine
            self.token = token
            self.followingFolder = followingFolder
        }
    }

    public private(set) var following: URL? {
        didSet { onFollowingChanged?(following) }
    }
    public var onFollowingChanged: ((URL?) -> Void)?

    public private(set) var activeLease: Lease?
    private var followStartTask: Task<Void, Never>?
    private var followGeneration: UInt64 = 0
    private var teardownTask: Task<Void, Never>?
    private var teardownGeneration: UInt64 = 0

    public var hasActiveOrStartingWorker: Bool { activeLease != nil || followStartTask != nil }
    public var hasPendingTeardown: Bool { teardownTask != nil }

    public init() {}

    /// Immediately invalidates the current follower/startup and schedules its teardown
    /// onto the shared teardown barrier without blocking the caller.
    public func preempt() {
        followGeneration &+= 1
        let startTask = followStartTask
        followStartTask = nil
        startTask?.cancel()
        following = nil
        let lease = activeLease
        activeLease = nil
        _ = enqueueTeardown(startTask: startTask, lease: lease, graceful: false)
    }

    /// Awaits every teardown currently queued on the barrier (including any chained
    /// preemptions or handed-off shutdowns added while awaiting).
    public func waitForTeardown() async {
        while let current = teardownTask {
            await current.value
        }
    }

    /// Preempts any active or starting follower and awaits full teardown completion.
    public func terminateAndWait() async {
        preempt()
        await waitForTeardown()
    }

    /// Ensures a single warm worker is following `folder`, awaiting any prior teardown
    /// before invoking `start` to spawn a replacement worker.
    public func ensureFollowing(
        folder: URL,
        canContinue: @escaping @MainActor () -> Bool,
        start: @escaping @MainActor (_ generation: UInt64) async -> Lease?
    ) {
        let path = folder.path
        guard canContinue() else { return }
        if activeLease?.followingFolder.path == path, activeLease?.worker.isAlive == true {
            following = folder
            return
        }
        if following?.path == path, followStartTask != nil { return }

        followGeneration &+= 1
        let generation = followGeneration
        let previousStart = followStartTask
        followStartTask = nil
        previousStart?.cancel()
        let previousLease = activeLease
        activeLease = nil
        // Capture only the prior teardown task (not future tasks that will await this
        // `followStartTask`) so the dependency graph stays strictly acyclic.
        let priorTeardown = enqueueTeardown(startTask: previousStart, lease: previousLease, graceful: false)
        following = folder

        followStartTask = Task { @MainActor [weak self] in
            await priorTeardown?.value
            guard let self, !Task.isCancelled, self.followGeneration == generation, canContinue() else {
                if let self, self.followGeneration == generation {
                    self.following = nil
                    self.followStartTask = nil
                }
                return
            }
            let lease = await start(generation)
            guard let lease else {
                if self.followGeneration == generation {
                    self.following = nil
                    self.followStartTask = nil
                }
                return
            }
            guard !Task.isCancelled, self.followGeneration == generation, canContinue() else {
                await Self.tearDownOffMain(lease, graceful: false)
                if self.followGeneration == generation {
                    self.following = nil
                    self.followStartTask = nil
                }
                return
            }
            self.activeLease = lease
            self.followStartTask = nil
        }
    }

    /// Claims the active warm worker for warm handoff if it is alive and already
    /// following `folder` with `desiredEngine`.
    public func claimForHandoff(folder: URL, desiredEngine: String) -> Lease? {
        guard let lease = activeLease,
              lease.followingFolder.path == folder.path,
              lease.engine == desiredEngine,
              lease.worker.isAlive else {
            return nil
        }
        followGeneration &+= 1
        activeLease = nil
        following = nil
        return lease
    }

    /// Releases a previously handed-off warm worker onto the shared teardown barrier
    /// so subsequent spawns and lifecycle barriers wait for its shutdown to complete.
    public func releaseHandedOff(_ lease: Lease, graceful: Bool = true) {
        _ = enqueueTeardown(startTask: nil, lease: lease, graceful: graceful)
    }

    @discardableResult
    private func enqueueTeardown(
        startTask: Task<Void, Never>?,
        lease: Lease?,
        graceful: Bool
    ) -> Task<Void, Never>? {
        guard startTask != nil || lease != nil else { return teardownTask }
        let previous = teardownTask
        teardownGeneration &+= 1
        let generation = teardownGeneration
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await startTask?.value
            if let lease {
                await Self.tearDownOffMain(lease, graceful: graceful)
            }
            if let self, self.teardownGeneration == generation {
                self.teardownTask = nil
            }
        }
        teardownTask = task
        return task
    }

    private static func tearDownOffMain(_ lease: Lease, graceful: Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                if graceful {
                    lease.worker.shutdown()
                } else {
                    lease.worker.terminateImmediately()
                }
                withExtendedLifetime(lease.token) {}
                continuation.resume()
            }
        }
    }
}
