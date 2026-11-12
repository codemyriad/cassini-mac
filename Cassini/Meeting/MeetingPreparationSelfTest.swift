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
        guard let fixture = try? LibraryScanner(root:LibraryStore.shared.context.root).scan().meetings.first(where:{ $0.state.lifecycle == .saved && !$0.speakers.isEmpty }) else {
            fail("no saved fixture meeting")
        }
        var meeting = fixture
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
        for (key,value) in MeetingPositionSlider.nativeSelfTest() { report[key] = value }
        for (key,value) in MeetingTranscriptText.nativeSelfTest() { report[key] = value }
        for (key,value) in MeetingTitleAlignment.nativeSelfTest() { report[key] = value }
        for (key,value) in CassiniTokens.nativeSelfTest() { report[key] = value }
        var asideMeeting = fixture
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
        guard report.filter({ $0.key != "audioDevicesOpened" }).allSatisfy({ $0.value as? Bool == true }) else { fail("native scrubber or preparation regression: \(report)") }
        report["audioDevicesOpened"] = false

        MeetingDetailModel.preparerForSelfTest = nil
        navigation.back()
        guard let output = try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) else { fail("report") }
        FileHandle.standardOutput.write(output + Data([10])); exit(0)
    }
}
#endif
