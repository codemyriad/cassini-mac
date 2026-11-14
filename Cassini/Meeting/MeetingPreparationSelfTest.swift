// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import CassiniKit
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
        guard let fixture = try? LibraryScanner(root:LibraryStore.shared.context.root).scan().meetings.first(where:{ $0.state.lifecycle == .saved && !$0.speakers.isEmpty }) else {
            fail("no saved fixture meeting")
        }
        var meeting = fixture
        meeting.state.transcript = .done
        var a = fixture.speakers[0], b = fixture.speakers[0]
        a.id = "a"; a.name = "Ada Brooks"; a.colourIndex = 0
        b.id = "b"; b.name = "Marta Cole"; b.colourIndex = 2; b.provenance = .user
        meeting.speakers = [a,b]
        meeting.mergedInto = [:]
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
        var active = meeting
        active.state.transcript = .queued
        navigation.open(active)
        guard let activeDetail = navigation.detail else { fail("no queued meeting page") }
        report["queuedSkipsTranscriptPresentation"] = activeDetail.turns.isEmpty && activeDetail.shares.isEmpty && activeDetail.timelineReadout.speaker(at:0) == nil
        active.state.transcript = .running
        active.transcriptItems.append(.init(speaker:"a",startMs:15_000_000,endMs:15_001_000,text:"Partial."))
        navigation.update([active],offline:false)
        report["runningSkipsTranscriptPresentation"] = activeDetail.turns.isEmpty && activeDetail.shares.isEmpty && activeDetail.listeningTurns.isEmpty
        // Completion without changed words must still start preparation.
        meeting = active
        meeting.state.transcript = .done
        navigation.update([meeting],offline:false)
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
        report["recoveryDelivered"] = detail.turns.count == 10_001
        report["readoutDeliveredWithTurns"] = detail.timelineReadout.speaker(at:1500) == "b" && detail.timelineReadout.speaker(at:1200) == nil
        // Hold the next preparation so every cached snapshot still has a's old
        // identity while the metadata already contains only the merge target.
        detail.listen.preview("a") // no transport or audio device
        var merged = meeting
        merged.speakers = [b]; merged.mergedInto = ["a":"b"]
        merged.transcriptItems = SpeakerMerges.apply(meeting.transcriptItems,merged.mergedInto)
        detail.meeting = merged
        guard case .started? = await next.next() else { fail("merge preparation did not start") }
        func staleSnapshotsRenderTarget() -> Bool {
            detail.turns.first?.speaker == "a" && detail.listeningTurns.first?.speaker == "a" &&
            detail.timelineReadout.speaker(at:0) == "a" && detail.speakerName("a") == "Marta Cole" &&
            detail.meeting.speaker(for:"a")?.colourIndex == 2 && detail.meeting.speaker(for:"a")?.provenance == .user &&
            MeetingPositionSlider.readoutSpeaker(at:0,readout:detail.timelineReadout,names:detail.meeting.speakerDisplayNames) == "Marta Cole"
        }
        report["mergeWhilePreparedResolvesReadoutAndHeaders"] = staleSnapshotsRenderTarget()
        report["mergeWhilePreparedResolvesBar"] = detail.listen.turn?.speaker == "a" && detail.listeningPresentation?.speakerName == "Marta Cole"
        detail.toggleSpeakerListening("b")
        report["mergedSpeakerRowStopsCachedListening"] = !detail.listen.active
        detail.listen.preview("a")
        // Cancellation must not make rendering depend on a later delivery.
        detail.suspend()
        release.signal()
        guard case .cancelled? = await next.next() else { fail("outage did not cancel the merge preparation") }
        report["suspendedMergeResolvesReadoutAndHeaders"] = staleSnapshotsRenderTarget() && !detail.listen.active
        let unknown = TimelineReadout(items:[.init(speaker:"unlisted",startMs:0,endMs:1000,text:"Yes.")])
        report["unlistedSpeechIsNotSilence"] = MeetingPositionSlider.readoutSpeaker(at:0,readout:unknown,names:detail.meeting.speakerDisplayNames) == UXText.text("common.speaker.unnamed",["n":"1"]) &&
            detail.speakerName("unlisted") == UXText.text("common.speaker.unnamed",["n":"1"]) &&
            MeetingPositionSlider.readoutSpeaker(at:1000,readout:unknown,names:detail.meeting.speakerDisplayNames) == nil
        let mergedDelivered = Task { @MainActor in await changed { _ = detail.turns } }
        detail.resumePreparation()
        guard case .started? = await next.next() else { fail("merge preparation did not resume") }
        release.signal()
        guard case .finished? = await next.next() else { fail("merge preparation did not finish") }
        await mergedDelivered.value
        report["mergedPreparationRecovers"] = detail.turns.allSatisfy { $0.speaker == "b" } && detail.timelineReadout.speaker(at:0) == "b" && detail.speakerName("b") == "Marta Cole"
        await runSessionModelProof(into: &report)
        for (key,value) in MeetingPositionSlider.nativeSelfTest() { report[key] = value }
        for (key,value) in SpeakerEditorChrome.nativeSelfTest() { report[key] = value }
        for (key,value) in MeetingTranscriptText.nativeSelfTest() { report[key] = value }
        for (key,value) in MeetingTitleAlignment.nativeSelfTest() { report[key] = value }
        for (key,value) in SpeakerSidebarRow.nativeSelfTest(baseSpeaker:fixture.speakers[0]) { report[key] = value }
        for (key,value) in CassiniTokens.nativeSelfTest() { report[key] = value }
        for (key,value) in MeetingCardPaint.nativeSelfTest() { report[key] = value }
        for (key,value) in ScrollEdgeChrome.nativeSelfTest() { report[key] = value }
        var asideMeeting = fixture
        asideMeeting.state.transcript = .done
        asideMeeting.transcriptItems = [.init(speaker:"claire",startMs:0,endMs:800,text:"We agree."),
            .init(speaker:"guest",startMs:750,endMs:1100,text:"Yes."),.init(speaker:"claire",startMs:1000,endMs:1800,text:"Thanks.")]
        asideMeeting.speakers = [] // the projection/action proof needs no names or speaker editor
        let preview = MeetingDetailModel(meeting:asideMeeting,frozen:true)
        if let aside = preview.turns.first(where:{ $0.speaker == "guest" }) {
            preview.listenFromReadingTurn(aside.id)
            report["asideActionSelectsOwnRunAndHost"] = preview.listen.turn?.index == 1 && preview.listeningHost == aside.host && !preview.audio.isPlaying
            let revision = preview.followRevision
            preview.handScrolledTranscript(); preview.playListeningAgain()
            report["explicitReplayResumesTranscriptFollow"] = preview.followRevision > revision && preview.canFollowTranscript
        } else { report["asideActionSelectsOwnRunAndHost"] = false }
        preview.close()
        let skippedKeys = ScrollEdgeChrome.nativeCoverageKeys
        let reportValid = report.filter({ $0.key != "audioDevicesOpened" }).allSatisfy { key, value in
            if key == "scrollEdgeNativeMacOS26Available" {
                return (value as? Bool) == ScrollEdgeChrome.isNativeMacOS26Available
            }
            if skippedKeys.contains(key) && !ScrollEdgeChrome.isNativeMacOS26Available {
                return (value as? String) == "skipped"
            }
            return (value as? Bool) == true
        }
        guard reportValid else { fail("native scrubber or preparation regression: \(report)") }
        report["audioDevicesOpened"] = false

        MeetingDetailModel.preparerForSelfTest = nil
        SessionModel.preparerForSelfTest = nil
        navigation.back()
        guard let output = try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) else { fail("report") }
        FileHandle.standardOutput.write(output + Data([10])); exit(0)
    }

    private static func runSessionModelProof(into report: inout [String: Any]) async {
        let receivedURL = LibraryStore.shared.context.root
            .appendingPathComponent("Received-a0000000-0000-4000-8000-000000000006/original.opus")
        guard let bytes = try? Data(contentsOf: receivedURL),
              var file = try? CassiniReader.read(bytes),
              let firstPair = file.transcripts.first,
              case .available(var firstBody) = firstPair.load else {
            fail("missing received onboarding opus fixture for SessionModel proof")
        }
        var firstEntry = firstPair.entry
        firstEntry.id = "tx-primary"; firstEntry.isDefault = true
        var secondEntry = firstPair.entry
        secondEntry.id = "tx-alt"; secondEntry.isDefault = false
        firstBody.items = (0..<10_000).map { i in
            let speaker = i % 2 == 0 ? "guest" : "alex"
            let start = (9_999 - i) * 200
            return Word(speaker: speaker, startMs: start, endMs: start + 150, text: "Word \(i)")
        }
        var secondBody = firstBody
        // In tx-alt, i = 9_999 has start = 0 and speaker = "unlisted" (speaks first at 0 ms),
        // i = 9_998 has start = 200 and speaker = "alex" (speaks second at 200 ms).
        secondBody.items = (0..<10_000).map { i in
            let speaker = i % 2 == 0 ? "alex" : "unlisted"
            let start = (9_999 - i) * 200
            return Word(speaker: speaker, startMs: start, endMs: start + 150, text: "Alt \(i)")
        }
        file.manifest?.transcripts = [firstEntry, secondEntry]
        file.transcripts = [(firstEntry, .available(firstBody)), (secondEntry, .available(secondBody))]

        func observeNextChange(_ read: @MainActor () -> Void) -> AsyncStream<Void> {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            withObservationTracking { read() } onChange: {
                continuation.yield(())
                continuation.finish()
            }
            return stream
        }

        final class Gate: @unchecked Sendable {
            private let cond = NSCondition()
            private var opened = false
            func wait() {
                cond.lock()
                while !opened { cond.wait() }
                cond.unlock()
            }
            func open() {
                cond.lock()
                opened = true
                cond.broadcast()
                cond.unlock()
            }
            deinit { open() }
        }
        enum SessionEvent: Sendable {
            case started(call: Int, onMain: Bool, gate: Gate)
            case cancelled(call: Int)
            case finished(call: Int)
        }
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; calls += 1; return calls }
            var value: Int { lock.lock(); defer { lock.unlock() }; return calls }
        }
        let (events, emit) = AsyncStream<SessionEvent>.makeStream()
        let counter = Counter()
        SessionModel.preparerForSelfTest = { items, known, bounded in
            let call = counter.next()
            let gate = Gate()
            emit.yield(.started(call: call, onMain: Thread.isMainThread, gate: gate))
            gate.wait()
            if Task.isCancelled { emit.yield(.cancelled(call: call)); throw CancellationError() }
            let prepared = try Timeline.PreparedSessionTranscript.preparing(items, knownSpeakerIDs: known, endsBoundedByAudio: bounded)
            emit.yield(.finished(call: call))
            return prepared
        }
        var next = events.makeAsyncIterator()
        let session = SessionModel(document: CassiniDocument(file: file), url: nil)
        guard case .started(1, let onMain, let gate1)? = await next.next() else { fail("SessionModel preparation did not start") }
        report["sessionPreparedOffMain"] = !onMain

        var progressed = false
        await Task { @MainActor in progressed = true }.value
        report["sessionMainActorProgressed"] = progressed && session.preparingTranscript && session.timeline == nil

        // Switching transcripts cancels in-flight preparation of tx-primary (call 1) and starts tx-alt (call 2).
        session.selectedTranscriptId = "tx-alt"
        gate1.open()
        var sawCancel1 = false
        var gate2: Gate?
        for _ in 0..<2 {
            guard let ev = await next.next() else { fail("missing SessionModel switch event") }
            switch ev {
            case .cancelled(1): sawCancel1 = true
            case .started(2, _, let g): gate2 = g
            default: fail("unexpected SessionModel switch event: \(ev)")
            }
        }
        guard let gate2 else { fail("SessionModel tx-alt did not start") }
        report["sessionSwitchCancelled"] = sawCancel1

        var altChanges = observeNextChange { _ = session.timeline }.makeAsyncIterator()
        gate2.open()
        guard case .finished(2)? = await next.next() else { fail("SessionModel tx-alt did not finish") }
        _ = await altChanges.next()
        report["sessionSpeakerSlotsMatchFirstSpeech"] =
            session.speakerColourIndexForSelfTest(for: "unlisted") == 0 &&
            session.speakerColourIndexForSelfTest(for: "alex") == 1 &&
            session.speakers.contains(where: { $0.id == "unlisted" })

        // Let tx-primary prepare once (call 3), then switch back to cached tx-alt without invoking the preparer again.
        session.selectedTranscriptId = "tx-primary"
        guard case .started(3, _, let gate3)? = await next.next() else { fail("SessionModel tx-primary restart did not start") }
        var primaryChanges = observeNextChange { _ = session.timeline }.makeAsyncIterator()
        gate3.open()
        guard case .finished(3)? = await next.next() else { fail("SessionModel tx-primary restart did not finish") }
        _ = await primaryChanges.next()
        let callsBeforeCachedSwitch = counter.value
        session.selectedTranscriptId = "tx-alt"
        report["sessionCachedSwitchSkipsPreparation"] =
            counter.value == callsBeforeCachedSwitch &&
            !session.preparingTranscript &&
            session.timeline?.words.count == 10_000 &&
            session.speakerColourIndexForSelfTest(for: "unlisted") == 0 &&
            session.speakerColourIndexForSelfTest(for: "alex") == 1
        session.close()
        SessionModel.preparerForSelfTest = nil
    }
}
#endif
