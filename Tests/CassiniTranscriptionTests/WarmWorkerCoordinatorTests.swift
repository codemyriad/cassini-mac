// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniTranscription

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private let sem = DispatchSemaphore(value: 0)

    func open() {
        lock.lock()
        let wasOpened = opened
        opened = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        if !wasOpened {
            for _ in 0..<16 { sem.signal() }
        }
        for c in pending { c.resume() }
    }

    func waitBlocking() {
        lock.lock()
        if opened {
            lock.unlock()
            return
        }
        lock.unlock()
        sem.wait()
    }

    func waitAsync() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class ConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var live = 0
    private var maxLive = 0
    private var events: [String] = []

    func workerStarted(_ id: String) {
        lock.lock()
        live += 1
        if live > maxLive { maxLive = live }
        events.append("start:\(id)")
        lock.unlock()
    }

    func workerExited(_ id: String) {
        lock.lock()
        live -= 1
        events.append("exit:\(id)")
        lock.unlock()
    }

    func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var snapshot: (live: Int, maxLive: Int, events: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (live, maxLive, events)
    }
}

private final class DeinitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var context: (isMainThread: Bool, inCooperativeTask: Bool)?

    func recordDeinit(isMainThread: Bool, inCooperativeTask: Bool) {
        lock.lock()
        context = (isMainThread: isMainThread, inCooperativeTask: inCooperativeTask)
        lock.unlock()
    }

    var deinitContext: (isMainThread: Bool, inCooperativeTask: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        return context
    }
}

private final class TrackedToken: @unchecked Sendable {
    let probe: DeinitProbe

    init(probe: DeinitProbe) {
        self.probe = probe
    }

    deinit {
        probe.recordDeinit(
            isMainThread: Thread.isMainThread,
            inCooperativeTask: withUnsafeCurrentTask { $0 != nil }
        )
    }
}

private final class GatedWorker: WarmWorkerManaging, @unchecked Sendable {
    let id: String
    let tracker: ConcurrencyTracker
    let teardownEntered = Gate()
    let teardownRelease = Gate()
    private let lock = NSLock()
    private var alive = true
    private var tornDown = false
    private var teardownExecution: (isMainThread: Bool, inCooperativeTask: Bool)?

    init(id: String, tracker: ConcurrencyTracker) {
        self.id = id
        self.tracker = tracker
        tracker.workerStarted(id)
    }

    var isAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return alive
    }

    var teardownContext: (isMainThread: Bool, inCooperativeTask: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        return teardownExecution
    }

    func shutdown() {
        tearDown(kind: "shutdown")
    }

    func terminateImmediately() {
        tearDown(kind: "terminate")
    }

    private func tearDown(kind: String) {
        let onMainThread = Thread.isMainThread
        let inCooperativeTask = withUnsafeCurrentTask { $0 != nil }

        lock.lock()
        if tornDown {
            lock.unlock()
            return
        }
        tornDown = true
        teardownExecution = (isMainThread: onMainThread, inCooperativeTask: inCooperativeTask)
        lock.unlock()

        tracker.record("\(kind)-enter:\(id)")
        teardownEntered.open()
        if !onMainThread && !inCooperativeTask {
            teardownRelease.waitBlocking()
        }

        lock.lock()
        alive = false
        lock.unlock()
        tracker.workerExited(id)
    }
}

@Suite struct WarmWorkerCoordinatorTests {
    @Test @MainActor func startupCancellationIsAwaitedBeforeNextWorkerSpawns() async {
        let tracker = ConcurrencyTracker()
        let coordinator = WarmWorkerCoordinator<GatedWorker, Int>()
        let folderA = URL(fileURLWithPath: "/tmp/meeting-a")
        let folderB = URL(fileURLWithPath: "/tmp/meeting-b")

        let start1Entered = Gate()
        let start1CleanupRelease = Gate()
        let start2Entered = Gate()
        let start2Done = Gate()
        let w1TokenProbe = DeinitProbe()
        var worker1: GatedWorker?

        coordinator.ensureFollowing(folder: folderA, canContinue: { true }) { _ in
            let w1 = GatedWorker(id: "w1", tracker: tracker)
            worker1 = w1
            start1Entered.open()
            // Simulate a blocked follow handshake cancelled by preemption.
            await start1CleanupRelease.waitAsync()
            await w1.terminateImmediatelyAsync(releasing: TrackedToken(probe: w1TokenProbe))
            return nil
        }

        await start1Entered.waitAsync()

        // Preempt while w1 is mid-startup; `preempt()` clears `following`,
        // but retains the startup task on the shared teardown barrier.
        coordinator.preempt()
        #expect(coordinator.following == nil)
        #expect(coordinator.hasPendingTeardown)

        // Request a new follower immediately. It MUST wait for w1's cancelled
        // startup + teardown to complete before spawning w2.
        coordinator.ensureFollowing(folder: folderB, canContinue: { true }) { _ in
            start2Entered.open()
            let w2 = GatedWorker(id: "w2", tracker: tracker)
            defer { start2Done.open() }
            return .init(worker: w2, engine: "whistle", token: 2, followingFolder: folderB)
        }

        // Release w1's startup wait, then verify w2 still waits until w1 finishes tearing down.
        start1CleanupRelease.open()
        let w1 = try! #require(worker1)
        await w1.teardownEntered.waitAsync()
        #expect(tracker.snapshot.events.contains("start:w2") == false)

        // Allow w1 teardown to finish -> w2 can now spawn.
        w1.teardownRelease.open()
        await start2Done.waitAsync()

        let snap = tracker.snapshot
        #expect(snap.maxLive == 1)
        #expect(snap.live == 1)
        let exitW1 = snap.events.firstIndex(of: "exit:w1")
        let startW2 = snap.events.firstIndex(of: "start:w2")
        #expect(exitW1 != nil && startW2 != nil && exitW1! < startW2!)

        // Clean up w2.
        let w2 = try! #require(coordinator.activeLease?.worker)
        w2.teardownRelease.open()
        await coordinator.terminateAndWait()
        #expect(tracker.snapshot.live == 0)

        let w1Ctx = try! #require(w1.teardownContext)
        #expect(w1Ctx.isMainThread == false)
        #expect(w1Ctx.inCooperativeTask == false)
        let w1Deinit = try! #require(w1TokenProbe.deinitContext)
        #expect(w1Deinit.isMainThread == false)
        #expect(w1Deinit.inCooperativeTask == false)
        let w2Ctx = try! #require(w2.teardownContext)
        #expect(w2Ctx.isMainThread == false)
        #expect(w2Ctx.inCooperativeTask == false)
    }

    @Test @MainActor func modelSwitchPreemptionBlocksNextWorkerUntilPreviousTeardownFinishes() async {
        let tracker = ConcurrencyTracker()
        let coordinator = WarmWorkerCoordinator<GatedWorker, Int>()
        let folder = URL(fileURLWithPath: "/tmp/meeting-model-switch")
        let w1Ready = Gate()

        coordinator.ensureFollowing(folder: folder, canContinue: { true }) { _ in
            let w1 = GatedWorker(id: "parakeet-w1", tracker: tracker)
            defer { w1Ready.open() }
            return .init(worker: w1, engine: "parakeet", token: 1, followingFolder: folder)
        }
        await w1Ready.waitAsync()
        let w1 = try! #require(coordinator.activeLease?.worker)

        // Model switch calls `preempt()`, then a subsequent cold job (or replacement
        // follower) calls `terminateAndWait()` before spawning the next worker.
        coordinator.preempt()
        await w1.teardownEntered.waitAsync()

        let barrierCompleted = Gate()
        let coldSpawnTask = Task { @MainActor in
            await coordinator.terminateAndWait()
            barrierCompleted.open()
            let w2 = GatedWorker(id: "whistle-cold-w2", tracker: tracker)
            w2.teardownRelease.open()
            await w2.terminateImmediatelyAsync()
        }

        // Yield to MainActor to ensure `terminateAndWait()` has entered its await.
        await Task.yield()
        #expect(tracker.snapshot.events.contains("start:whistle-cold-w2") == false)

        w1.teardownRelease.open()
        await barrierCompleted.waitAsync()
        await coldSpawnTask.value

        let snap = tracker.snapshot
        #expect(snap.maxLive == 1)
        #expect(snap.live == 0)
        let exitW1 = snap.events.firstIndex(of: "exit:parakeet-w1")
        let startW2 = snap.events.firstIndex(of: "start:whistle-cold-w2")
        #expect(exitW1 != nil && startW2 != nil && exitW1! < startW2!)
    }

    @Test @MainActor func handoffCompletionTeardownBlocksNextSpawnAndBarriers() async {
        let tracker = ConcurrencyTracker()
        let coordinator = WarmWorkerCoordinator<GatedWorker, Int>()
        let folderA = URL(fileURLWithPath: "/tmp/meeting-handoff-a")
        let folderB = URL(fileURLWithPath: "/tmp/meeting-handoff-b")
        let w1Ready = Gate()

        coordinator.ensureFollowing(folder: folderA, canContinue: { true }) { _ in
            let w1 = GatedWorker(id: "handoff-w1", tracker: tracker)
            defer { w1Ready.open() }
            return .init(worker: w1, engine: "whistle", token: 1, followingFolder: folderA)
        }
        await w1Ready.waitAsync()

        let lease = try! #require(coordinator.claimForHandoff(folder: folderA, desiredEngine: "whistle"))
        #expect(coordinator.activeLease == nil)
        #expect(coordinator.following == nil)

        // Transcription finishes and releases the handed-off worker for graceful shutdown.
        coordinator.releaseHandedOff(lease, graceful: true)
        await lease.worker.teardownEntered.waitAsync()

        // Immediately try to follow folder B while handed-off worker shutdown is still running.
        let w2Ready = Gate()
        coordinator.ensureFollowing(folder: folderB, canContinue: { true }) { _ in
            let w2 = GatedWorker(id: "follow-w2", tracker: tracker)
            defer { w2Ready.open() }
            return .init(worker: w2, engine: "whistle", token: 2, followingFolder: folderB)
        }
        await Task.yield()
        #expect(tracker.snapshot.events.contains("start:follow-w2") == false)

        // Release handed-off worker's shutdown -> w2 can now start.
        lease.worker.teardownRelease.open()
        await w2Ready.waitAsync()

        let snap = tracker.snapshot
        #expect(snap.maxLive == 1)
        let exitW1 = snap.events.firstIndex(of: "exit:handoff-w1")
        let startW2 = snap.events.firstIndex(of: "start:follow-w2")
        #expect(exitW1 != nil && startW2 != nil && exitW1! < startW2!)

        let w2 = try! #require(coordinator.activeLease?.worker)
        w2.teardownRelease.open()
        await coordinator.terminateAndWait()
        #expect(tracker.snapshot.live == 0)
    }

    @Test @MainActor func moveBarrierWaitsForPreemptedAndHandedOffTeardown() async {
        let tracker = ConcurrencyTracker()
        let coordinator = WarmWorkerCoordinator<GatedWorker, Int>()
        let folder = URL(fileURLWithPath: "/tmp/meeting-move")
        let w1Ready = Gate()

        coordinator.ensureFollowing(folder: folder, canContinue: { true }) { _ in
            let w1 = GatedWorker(id: "move-w1", tracker: tracker)
            defer { w1Ready.open() }
            return .init(worker: w1, engine: "whistle", token: 1, followingFolder: folder)
        }
        await w1Ready.waitAsync()
        let lease = try! #require(coordinator.claimForHandoff(folder: folder, desiredEngine: "whistle"))

        // Release handed-off worker, then immediately invoke the move barrier (`terminateAndWait`).
        coordinator.releaseHandedOff(lease, graceful: true)
        await lease.worker.teardownEntered.waitAsync()

        var moveReturned = false
        let moveTask = Task { @MainActor in
            await coordinator.terminateAndWait()
            moveReturned = true
            tracker.record("move-barrier-done")
        }
        await Task.yield()
        #expect(moveReturned == false)

        lease.worker.teardownRelease.open()
        await moveTask.value
        #expect(moveReturned == true)

        let snap = tracker.snapshot
        let exitW1 = snap.events.firstIndex(of: "exit:move-w1")
        let moveDone = snap.events.firstIndex(of: "move-barrier-done")
        #expect(exitW1 != nil && moveDone != nil && exitW1! < moveDone!)
    }

    @Test @MainActor func shutdownBarrierWaitsForPreemptedAndHandedOffTeardown() async {
        let tracker = ConcurrencyTracker()
        let coordinator = WarmWorkerCoordinator<GatedWorker, Int>()
        let folder = URL(fileURLWithPath: "/tmp/meeting-shutdown")
        let w1Ready = Gate()

        coordinator.ensureFollowing(folder: folder, canContinue: { true }) { _ in
            let w1 = GatedWorker(id: "shutdown-w1", tracker: tracker)
            defer { w1Ready.open() }
            return .init(worker: w1, engine: "whistle", token: 1, followingFolder: folder)
        }
        await w1Ready.waitAsync()
        let w1 = try! #require(coordinator.activeLease?.worker)

        // Simulate `beginShutdown()` calling `preempt()`, followed by `waitForShutdown()`
        // calling `terminateAndWait()`.
        coordinator.preempt()
        await w1.teardownEntered.waitAsync()

        var shutdownReturned = false
        let shutdownTask = Task { @MainActor in
            await coordinator.terminateAndWait()
            shutdownReturned = true
            tracker.record("shutdown-barrier-done")
        }
        await Task.yield()
        #expect(shutdownReturned == false)

        w1.teardownRelease.open()
        await shutdownTask.value
        #expect(shutdownReturned == true)

        let snap = tracker.snapshot
        let exitW1 = snap.events.firstIndex(of: "exit:shutdown-w1")
        let shutdownDone = snap.events.firstIndex(of: "shutdown-barrier-done")
        #expect(exitW1 != nil && shutdownDone != nil && exitW1! < shutdownDone!)
    }

    @Test @MainActor func concurrentBlockedTeardownsDoNotStarveCooperativePool() async {
        let count = max(16, ProcessInfo.processInfo.activeProcessorCount * 2)
        let tracker = ConcurrencyTracker()
        var coordinators: [WarmWorkerCoordinator<GatedWorker, TrackedToken>] = []
        var workers: [GatedWorker] = []
        var tokenProbes: [DeinitProbe] = []

        for index in 0..<count {
            let coordinator = WarmWorkerCoordinator<GatedWorker, TrackedToken>()
            let folder = URL(fileURLWithPath: "/tmp/meeting-pool-\(index)")
            let ready = Gate()
            let probe = DeinitProbe()
            tokenProbes.append(probe)
            coordinator.ensureFollowing(folder: folder, canContinue: { true }) { _ in
                let worker = GatedWorker(id: "pool-w\(index)", tracker: tracker)
                defer { ready.open() }
                return .init(worker: worker, engine: "whistle", token: TrackedToken(probe: probe), followingFolder: folder)
            }
            await ready.waitAsync()
            let worker = try! #require(coordinator.activeLease?.worker)
            coordinators.append(coordinator)
            workers.append(worker)
        }

        for coordinator in coordinators {
            coordinator.preempt()
        }
        for worker in workers {
            await worker.teardownEntered.waitAsync()
        }

        // All `count` workers (> activeProcessorCount) are simultaneously blocked in
        // `Gate.waitBlocking()`. Verify the Swift Concurrency cooperative thread pool
        // still makes forward progress.
        let probe = await Task.detached(priority: .userInitiated) { 42 }.value
        #expect(probe == 42)

        for worker in workers {
            worker.teardownRelease.open()
        }
        for coordinator in coordinators {
            await coordinator.waitForTeardown()
        }
        #expect(tracker.snapshot.live == 0)

        for (worker, tokenProbe) in zip(workers, tokenProbes) {
            let teardownCtx = try! #require(worker.teardownContext)
            #expect(teardownCtx.isMainThread == false)
            #expect(teardownCtx.inCooperativeTask == false)
            let deinitCtx = try! #require(tokenProbe.deinitContext)
            #expect(deinitCtx.isMainThread == false)
            #expect(deinitCtx.inCooperativeTask == false)
        }
    }
}
