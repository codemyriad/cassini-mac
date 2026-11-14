// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import Foundation
import Testing
@testable import CassiniLibrary

/// Drag-hover probing must never block the main actor (bug class #2). The probes below park
/// a real thread on a semaphore, standing in for `open`/`read` on a stalled network mount,
/// and every wait is event-gated (bug class #17): no `Task.sleep`, no wall-clock timeouts.
@MainActor @Suite struct ImportDropProbeSessionTests {
    /// One-shot event; `wait()` is called at most once per signal.
    private struct Signal: Sendable {
        private let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        func fire() { pair.continuation.yield() }
        func wait() async { for await _ in pair.stream { return } }
    }

    /// Per-file stalled probe: records the call, announces it, then blocks its (non-main)
    /// thread until the test opens that file's gate.
    private final class StalledProbe: @unchecked Sendable {
        let entered: [String: Signal]
        let gates: [String: DispatchSemaphore]
        let accepted: Set<String>
        private let lock = NSLock()
        private var log: [String] = []

        init(names: [String], accepted: Set<String>) {
            entered = Dictionary(uniqueKeysWithValues: names.map { ($0, Signal()) })
            gates = Dictionary(uniqueKeysWithValues: names.map { ($0, DispatchSemaphore(value: 0)) })
            self.accepted = accepted
        }

        var calls: [String] {
            lock.lock(); defer { lock.unlock() }
            return log
        }

        func open(_ name: String) { gates[name]!.signal() }

        func openAll() { gates.values.forEach { $0.signal() } }

        var probe: ImportDropProbeSession.Probe {
            ImportDropProbeSession.blockingProbe { [self] url in
                let name = url.lastPathComponent
                lock.lock(); log.append(name); lock.unlock()
                entered[name]!.fire()
                gates[name]!.wait()
                return accepted.contains(name)
            }
        }
    }

    @MainActor private final class Events {
        var resolved = 0
        var discarded = 0
        let resolvedSignals = [Signal(), Signal()]
        let discardedSignals = [Signal(), Signal()]

        func attach(to session: ImportDropProbeSession) {
            session.onResolved = { [self] in
                resolvedSignals[resolved].fire()
                resolved += 1
            }
            session.onStaleResultDiscarded = { [self] in
                discardedSignals[discarded].fire()
                discarded += 1
            }
        }
    }

    private static func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/Volumes/Stalled Share/" + name)
    }

    @Test func hoverReturnsImmediatelyWhileProbeIsStalledAndUpdatesOnceGateOpens() async {
        let stalled = StalledProbe(names: ["good.wav", "disguised.wav"], accepted: ["good.wav"])
        defer { stalled.openAll() }
        let session = ImportDropProbeSession(probe: stalled.probe)
        let events = Events()
        events.attach(to: session)
        let files = [Self.url("good.wav"), Self.url("disguised.wav")]

        // draggingEntered: answers from memory while the probe has not even run yet.
        #expect(session.resolution(for: files) == .pending)
        await stalled.entered["good.wav"]!.wait()

        // The probe thread is now parked inside "I/O". Every draggingUpdated still returns on
        // the main actor; were it waiting on the probe, this loop would deadlock because only
        // this same main-actor test opens the gate below.
        for _ in 0..<1_000 {
            #expect(session.resolution(for: files) == .pending)
        }
        #expect(stalled.calls == ["good.wav"], "Repeated hover for the same files must reuse the session's probe")
        #expect(events.resolved == 0)

        stalled.open("good.wav")
        await stalled.entered["disguised.wav"]!.wait()
        #expect(session.resolution(for: files) == .pending)
        stalled.open("disguised.wav")

        await events.resolvedSignals[0].wait()
        #expect(events.resolved == 1)
        #expect(session.resolution(for: files) == .resolved(supported: [Self.url("good.wav")]))
        #expect(stalled.calls == ["good.wav", "disguised.wav"], "The resolved result is cached for the drag session")
        #expect(events.discarded == 0)
    }

    @Test func supersededAndResetSessionsNeverOverwriteTheCurrentSession() async {
        let stalled = StalledProbe(names: ["first.wav", "second.mp3", "third.m4a"], accepted: ["first.wav", "second.mp3", "third.m4a"])
        defer { stalled.openAll() }
        let session = ImportDropProbeSession(probe: stalled.probe)
        let events = Events()
        events.attach(to: session)
        let first = [Self.url("first.wav")], second = [Self.url("second.mp3")], third = [Self.url("third.m4a")]

        #expect(session.resolution(for: first) == .pending)
        await stalled.entered["first.wav"]!.wait()

        // A new drag (different files) supersedes the stalled session.
        #expect(session.resolution(for: second) == .pending)
        await stalled.entered["second.mp3"]!.wait()

        // The stale probe finishes first: it must be discarded, not applied to the new session.
        stalled.open("first.wav")
        await events.discardedSignals[0].wait()
        #expect(events.resolved == 0)
        #expect(session.resolution(for: second) == .pending)

        stalled.open("second.mp3")
        await events.resolvedSignals[0].wait()
        #expect(session.resolution(for: second) == .resolved(supported: second))

        // draggingExited / concludeDragOperation while a probe is stalled: its late result is dropped.
        #expect(session.resolution(for: third) == .pending)
        await stalled.entered["third.m4a"]!.wait()
        session.reset()
        stalled.open("third.m4a")
        await events.discardedSignals[1].wait()
        #expect(events.resolved == 1)
        #expect(events.discarded == 2)
        #expect(stalled.calls == ["first.wav", "second.mp3", "third.m4a"])
    }
}
