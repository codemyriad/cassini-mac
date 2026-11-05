// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import CassiniLibrary
import Observation

/// #118 r3: the meeting page's turn preparation through the production MeetingNavigation and
/// MeetingDetailModel, on the bundled fixture, with a gated preparer and events only (E1):
/// a 10,000-turn transcript starts preparing off the main thread, the main actor makes progress
/// while it is held, a Library outage cancels it (nothing is delivered), and recovery restarts it
/// and delivers every turn. Writes nothing; no audio device is opened.
@MainActor enum MeetingPreparationSelfTest {
    /// What the gated worker reports, in order.
    private enum Event: Sendable { case started(onMain: Bool), cancelled, finished }
    private static func fail(_ why: String) -> Never {
        FileHandle.standardError.write(Data("Meeting preparation proof failed: \(why)\n".utf8)); exit(1)
    }
    /// The next change of something `read` observes on the model.
    private static func changed(_ read: @escaping @MainActor () -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void,Never>) in
            withObservationTracking { read() } onChange: { done.resume() }
        }
    }
    static func run() async {
        guard let fixture = try? LibraryScanner(root:LibraryStore.shared.context.root).scan().meetings.first(where:{ $0.state.lifecycle == .saved }) else {
            fail("no saved fixture meeting")
        }
        var meeting = fixture
        meeting.transcriptItems = (0..<10_000).map {
            .init(speaker:$0 % 2 == 0 ? "a" : "b",startMs:Int64($0) * 1500,endMs:Int64($0) * 1500 + 1000,text:"Word \($0).")
        }
        let (events,emit) = AsyncStream<Event>.makeStream()
        let release = DispatchSemaphore(value:0)
        MeetingDetailModel.preparerForSelfTest = { items, gaps in
            emit.yield(.started(onMain:Thread.isMainThread))
            release.wait()
            if Task.isCancelled { emit.yield(.cancelled); throw CancellationError() }
            let turns = try MeetingPresentation.turns(items,gaps:gaps,cancellable:true)
            emit.yield(.finished); return turns
        }
        var next = events.makeAsyncIterator()
        var report: [String:Any] = [:]
        let navigation = MeetingNavigation.shared
        navigation.openLibrary = nil
        navigation.open(meeting)
        guard let detail = navigation.detail else { fail("no meeting page") }

        // 1. Preparation started, off the main thread, and the page has no turns yet.
        guard case .started(let onMain)? = await next.next() else { fail("preparation did not start") }
        report["preparedOffMain"] = !onMain
        // 2. The main actor runs while the worker is held.
        var progressed = false
        await Task { @MainActor in progressed = true }.value
        report["mainActorProgressed"] = progressed && detail.turns.isEmpty

        // 3. A Library outage cancels the preparation; the held worker sees it and delivers nothing.
        navigation.update([],offline:true)
        release.signal()
        guard case .cancelled? = await next.next() else { fail("the outage did not cancel the preparation") }
        await Task { @MainActor in }.value
        report["outageCancelled"] = detail.turns.isEmpty && navigation.detail === detail

        // 4. Recovery with the same words restarts it, and every turn is delivered.
        let delivered = Task { @MainActor in await changed { _ = detail.turns } }
        navigation.update([meeting],offline:false)
        guard case .started? = await next.next() else { fail("recovery did not restart the preparation") }
        release.signal()
        guard case .finished? = await next.next() else { fail("the restarted preparation did not finish") }
        await delivered.value
        report["recoveryDelivered"] = detail.turns.count == 10_000
        report["audioDevicesOpened"] = false

        MeetingDetailModel.preparerForSelfTest = nil
        navigation.back()
        guard let output = try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) else { fail("report") }
        FileHandle.standardOutput.write(output + Data([10])); exit(0)
    }
}
#endif
