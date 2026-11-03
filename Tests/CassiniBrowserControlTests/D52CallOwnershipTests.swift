// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
import CassiniRecording
@testable import CassiniBrowserControl

/// D52.5 lost-call ownership (#113 review r3). `CallOwnership` is the only lost-call state: the
/// app feeds each recording's binding, the broker feeds transport loss and resume, the control
/// service reads it before admitting a Start. The regressions run through the real host and
/// control pipes and wait on events only; timeouts are failure bounds.
final class D52CallOwnershipTests: XCTestCase, @unchecked Sendable {
    private let instance = BrowserInstance(pid:4242,startSeconds:1_793_000_000)
    private let resumeCapabilities = ["independent-sessions-v1","multi-stream-v1","page-state-v1","resume-capture-v1"]

    // MARK: the pure type

    func testALostRecordingHoldsItsCallUntilItSavesOrResumes() {
        var state = CallOwnership()
        let id = UUID(), old = UUID(), new = UUID()
        state.bind(id,.init(key:.init(peer:old,tabID:2),callGeneration:"call-A",follows:true,recording:true))
        XCTAssertEqual(state.lostCalls,[],"a recording on a live transport holds no lost call")
        state.transportLost(id)
        XCTAssertEqual(state.lostCalls,[.init(tabID:2,callGeneration:"call-A")])
        let meetings = [BrowserMeeting(key:.init(peer:new,tabID:7),title:"Other",url:"https://meet.example/7",sourceCount:1,heard:true,callGeneration:"call-X"),
                        BrowserMeeting(key:.init(peer:new,tabID:2),title:"Call",url:"https://meet.example/2",sourceCount:1,heard:true,callGeneration:"call-A")]
        XCTAssertEqual(state.call(of:id,among:meetings),.init(peer:new,tabID:2),"it follows its call to a new control peer")
        state.transportResumed(id)
        XCTAssertEqual(state.lostCalls,[]); XCTAssertNil(state.call(of:id,among:meetings),"a resumed recording no longer follows by itself")
        state.transportLost(id)
        state.bind(id,.init(key:.init(peer:old,tabID:2),callGeneration:"call-A",follows:true,recording:false))
        XCTAssertEqual(state.lostCalls,[],"a saving recording releases its call")
        state.remove(id)
        XCTAssertNil(state.binding(id)); XCTAssertFalse(state.isLost(id))
    }
    /// A call recorded at Start is held by its generation before its tab is known; the tab is
    /// whichever row reports it. D51: a recording without a generation holds nothing.
    func testACallRecordedAtStartIsHeldByItsGeneration() {
        var state = CallOwnership(); let id = UUID(), p = UUID()
        state.started(id,callGeneration:"call-A")
        state.transportLost(id)
        let row = BrowserMeeting(key:.init(peer:p,tabID:4),title:"Call",url:"u",sourceCount:1,heard:true,callGeneration:"call-A")
        XCTAssertEqual(state.lostCalls(among:[row]),[.init(tabID:4,callGeneration:"call-A")])
        XCTAssertTrue(state.holds(meeting:row))
        XCTAssertEqual(state.call(of:id,among:[row]),row.key)
        // The app's later binding without a generation keeps the recorded one.
        state.bind(id,.init(key:nil,callGeneration:nil,follows:true,recording:true))
        XCTAssertEqual(state.binding(id)?.callGeneration,"call-A")
        var legacy = CallOwnership(); let other = UUID()
        legacy.bind(other,.init(key:.init(peer:p,tabID:4),callGeneration:nil,follows:true,recording:true))
        legacy.transportLost(other)
        XCTAssertEqual(legacy.lostCalls,[],"no generation, no hold (only 0.2.12+ is supported)")
    }
    func testOnlyAStandInWhoseTakeOverCommittedHoldsItsCall() {
        let adopted = [CaptureEvent(atMs:0,type:"othersSource",source:"system",reason:"missing"),
                       CaptureEvent(atMs:1000,type:"othersSource",source:"browser",reason:"callConnected")]
        XCTAssertTrue(BrowserCallPolicy.followsCall(source:"macos",keyed:true,events:adopted))
        XCTAssertFalse(BrowserCallPolicy.followsCall(source:"macos",keyed:true,events:Array(adopted.prefix(1))))
        XCTAssertTrue(BrowserCallPolicy.followsCall(source:"chromium",keyed:false,events:[]))
        var state = CallOwnership(); let id = UUID()
        state.bind(id,.init(key:.init(peer:UUID(),tabID:2),callGeneration:"call-A",follows:false,recording:true))
        state.transportLost(id)
        XCTAssertEqual(state.lostCalls,[],"a pending stand-in is a native recording")
    }
    func testALearnedGenerationIsNeverForgotten() {
        var state = CallOwnership(); let id = UUID(), key = BrowserMeetingKey(peer:UUID(),tabID:2)
        state.bind(id,.init(key:key,callGeneration:"call-A",follows:true,recording:true))
        state.bind(id,.init(key:key,callGeneration:nil,follows:true,recording:true))
        XCTAssertEqual(state.binding(id)?.callGeneration,"call-A")
        XCTAssertEqual(state.endsForCallChange(id,reported:nil,current:"call-B"),.callEnded)
        XCTAssertNil(state.endsForCallChange(id,reported:nil,current:"call-A"))
        XCTAssertNil(state.endsForCallChange(UUID(),reported:nil,current:"call-B"),"an unknown generation is no evidence of a change")
        XCTAssertEqual(state.endsForCallChange(UUID(),reported:"call-A",current:"call-B"),.callEnded,"the session's report still counts")
    }
    func testInterruptedHistoryIsNotAListedSession() {
        let peer = UUID()
        func snapshot(captures: [BrowserCaptureStatus], interrupted: [BrowserCaptureStatus]) -> BrowserControlPeerSnapshot {
            .init(id:peer,browser:"Chrome",browserInstance:nil,reconciled:true,independent:true,meetings:[],captures:captures,interrupted:interrupted)
        }
        let row = BrowserCaptureStatus(key:.init(peer:peer,tabID:2),captureID:"orig",path:nil,recording:false,stopping:false,tracks:0)
        XCTAssertFalse(CallOwnership.sessionListed(tabID:2,peer:snapshot(captures:[],interrupted:[row])))
        let active = BrowserCaptureStatus(key:.init(peer:peer,tabID:2),captureID:"next",path:nil,recording:true,stopping:false,tracks:1)
        XCTAssertTrue(CallOwnership.sessionListed(tabID:2,peer:snapshot(captures:[active],interrupted:[row])))
        let stopping = BrowserCaptureStatus(key:.init(peer:peer,tabID:2),captureID:"next",path:nil,recording:false,stopping:true,tracks:1)
        XCTAssertTrue(CallOwnership.sessionListed(tabID:2,peer:snapshot(captures:[stopping],interrupted:[])))
        XCTAssertFalse(CallOwnership.sessionListed(tabID:3,peer:snapshot(captures:[active],interrupted:[])))
        XCTAssertFalse(CallOwnership.sessionListed(tabID:2,peer:nil))
    }

    private func peer(_ id: UUID, instance: BrowserInstance?, multiStream: Bool = true, meetings: [(Int,String)],
                      captures: [BrowserCaptureStatus] = [], interrupted: [BrowserCaptureStatus] = []) -> BrowserControlPeerSnapshot {
        .init(id:id,browser:"Chrome",browserInstance:instance,reconciled:true,independent:true,
              meetings:meetings.map { BrowserMeeting(key:.init(peer:id,tabID:$0.0),title:"Call",url:"https://meet.example/\($0.0)",sourceCount:1,heard:true,callGeneration:$0.1) },
              captures:captures,interrupted:interrupted,supportsPageState:true,supportsMultiStream:multiStream,supportsResume:multiStream)
    }
    /// Review of the state machine: a control gap is not a legacy peer. The recording keeps the
    /// D52 policy (its 120 s grace starts at the gap), where a fresh D33 lifecycle would end a
    /// recording that has waited on its fallback for more than 120 s at once.
    func testAControlGapKeepsTheMultiStreamPolicy() {
        var state = CallOwnership(); let id = UUID(), old = UUID()
        state.bind(id,.init(key:.init(peer:old,tabID:2),callGeneration:"call-A",follows:true,recording:true))
        XCTAssertTrue(state.follow(id,captureID:"x",peers:[peer(old,instance:instance,meetings:[(2,"call-A")])]).multiStream)
        state.transportLost(id)
        let gap = state.follow(id,captureID:"x",peers:[])
        XCTAssertTrue(gap.multiStream,"kept across the gap"); XCTAssertNil(gap.end); XCTAssertEqual(gap.key,.init(peer:old,tabID:2))
        // The policy that applies: lost at 0, the call present until 200, then the gap at 201.
        var policy = BrowserCallPolicy(resumeCapture:true,callGeneration:"call-A",heard:true)
        let present = BrowserCallPolicy.Observation(page:.present,sourceCount:1,heard:true,transportAlive:false,callGeneration:"call-A",controlConnection:"c1",lostAt:0)
        for t in stride(from:1.0,through:200,by:1) {
            _ = BrowserCallPolicy.decide(pending:false,multiStream:true,policy:&policy,now:t,present,source:"system",reason:"lost",others:true,restoreReady:false,legacy:{ nil })
        }
        let missing = BrowserCallPolicy.Observation(page:nil,rowPresent:false,sourceCount:nil,heard:false,controlAlive:false,transportAlive:false,lostAt:0)
        var legacy = BrowserCallLifecycle()
        let action = BrowserCallPolicy.decide(pending:false,multiStream:gap.multiStream,policy:&policy,now:201,missing,source:"system",reason:"lost",
                                              others:true,restoreReady:false,legacy:{ legacy.step(now:201,page:nil,sourceCount:0,transportAlive:false,usingSystem:true,others:true,restoreReady:false,lostAt:0) })
        XCTAssertNil(action,"the D52 grace starts at the gap")
        var fresh = BrowserCallLifecycle()
        XCTAssertEqual(fresh.step(now:201,page:nil,sourceCount:0,transportAlive:false,usingSystem:true,others:true,restoreReady:false,lostAt:0),.stop(.pageGone),
                       "what treating the gap as a legacy peer did")
    }
    /// Review of the state machine: after a reconnect, the same browser's new peer reports the
    /// lost recording's tab on another call: the recording ends as callEnded. Another browser
    /// reporting the same tab id is no evidence.
    func testACallChangeIsSeenFromTheSameBrowsersNewPeer() {
        var state = CallOwnership(); let id = UUID(), old = UUID(), new = UUID(), other = UUID()
        state.bind(id,.init(key:.init(peer:old,tabID:2),callGeneration:"call-A",follows:true,recording:true))
        _ = state.follow(id,captureID:"x",peers:[peer(old,instance:instance,meetings:[(2,"call-A")])])
        state.transportLost(id)
        let elsewhere = BrowserInstance(pid:5151,startSeconds:1_793_000_000)
        XCTAssertNil(state.follow(id,captureID:"x",peers:[peer(other,instance:elsewhere,meetings:[(2,"call-B")])]).end,"another browser's tab 2")
        let moved = state.follow(id,captureID:"x",peers:[peer(new,instance:instance,meetings:[(2,"call-B")])])
        XCTAssertEqual(moved.end,.callEnded); XCTAssertTrue(moved.multiStream)
        let back = state.follow(id,captureID:"x",peers:[peer(new,instance:instance,meetings:[(2,"call-A")])])
        XCTAssertNil(back.end); XCTAssertEqual(back.key,.init(peer:new,tabID:2),"the same call: it follows instead")
    }
    /// Re-review: after a control-only reconnect the app learns a live recording's new key
    /// (replacePeers) and feeds it before `follow`; the store never re-keys a live recording,
    /// and its decisions come from the new peer at once (multi-stream, listed session).
    func testALiveRecordingKeepsTheKeyItsCollectionLearned() {
        var state = CallOwnership(); let id = UUID(), old = UUID(), new = UUID()
        state.bind(id,.init(key:.init(peer:old,tabID:2),callGeneration:"call-A",follows:true,recording:true))
        let listed = BrowserCaptureStatus(key:.init(peer:new,tabID:2),captureID:"x",path:nil,recording:true,stopping:false,tracks:1)
        let reconnected = peer(new,instance:instance,meetings:[(2,"call-A")],captures:[listed])
        let stale = state.follow(id,captureID:"x",peers:[reconnected])
        XCTAssertFalse(stale.rebound,"a live recording is never re-keyed by the store")
        state.bind(id,.init(key:.init(peer:new,tabID:2),callGeneration:nil,follows:true,recording:true))
        let fresh = state.follow(id,captureID:"x",peers:[reconnected])
        XCTAssertEqual(fresh.key,.init(peer:new,tabID:2)); XCTAssertFalse(fresh.rebound)
        XCTAssertTrue(fresh.multiStream); XCTAssertTrue(fresh.sessionListed); XCTAssertNil(fresh.end)
        // The same call on the new peer moves on to call B: callEnded, from the live peer.
        let moved = state.follow(id,captureID:"x",peers:[peer(new,instance:instance,meetings:[(2,"call-B")],captures:[listed])])
        XCTAssertEqual(moved.end,.callEnded)
    }
    func testAHeldCallIsNeverOfferedToAStandIn() {
        var state = CallOwnership(); let id = UUID(), p = UUID()
        state.bind(id,.init(key:.init(peer:p,tabID:2),callGeneration:"call-A",follows:true,recording:true))
        let call = BrowserMeeting(key:.init(peer:p,tabID:2),title:"Call",url:"u",sourceCount:1,heard:true,callGeneration:"call-A")
        XCTAssertFalse(state.holds(meeting:call))
        state.transportLost(id)
        XCTAssertTrue(state.holds(meeting:call))
        var next = call; next.callGeneration = "call-B"
        XCTAssertFalse(state.holds(meeting:next))
    }
    func testAResumeIsRefusedWhenTheTabMovedToAnotherCall() throws {
        var state = BrowserControlRegistry(), id = UUID()
        try state.connect(.init(id:id,role:.control,browser:"Chrome",browserInstance:instance))
        for value: [String:Any] in [["type":"hello","version":1,"capabilities":resumeCapabilities],
                                    ["type":"meetings","meetings":[["tabId":2,"title":"Call","url":"https://meet.example/2","sourceCount":1,"heard":true,"callGeneration":"call-B"]]],
                                    ["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready","sessions":[]]] {
            try state.receive(JSONSerialization.data(withJSONObject:value),from:id)
        }
        XCTAssertThrowsError(try state.resume(.init(peer:id,tabID:2),captureID:"orig",timelineOriginMs:1,expectedGeneration:"call-A"))
        XCTAssertEqual(try state.resume(.init(peer:id,tabID:2),captureID:"orig",timelineOriginMs:1,expectedGeneration:"call-B").1,"call-B")
    }

    // MARK: event-driven regressions through the real host and control pipes

    /// Review r3, first major: A's transport closes, its session leaves the status, and the tab
    /// starts call B. The session's own report is gone, so only the generation the recording
    /// learned can end it as callEnded instead of letting B keep A's fallback recording.
    func testALostRecordingEndsWhenItsTabStartsAnotherCall() async throws {
        let ownership = CallOwnershipStore(), log = PeerLog()
        let fixture = try AudioFixture(ownership:ownership,changed:{ log.changed($0) })
        do {
            let control = try connect(fixture,meetings:[(2,"call-A")],sessions:[(2,"lost-a","call-A")])
            let bound = log.next("the session and its generation are reported") { $0.contains { $0.captures.contains { $0.captureID == "lost-a" && $0.callGeneration == "call-A" } } }
            await fulfillment(of:[bound],timeout:5)
            let peer = try XCTUnwrap(log.peers.first { $0.reconciled }).id
            let (audio,owner) = try startCapture(fixture,"lost-a")
            // As the app feeds it: the key at creation, the generation from the status.
            ownership.update { $0.bind(owner.snapshot.manifest.id,.init(key:.init(peer:peer,tabID:2),callGeneration:"call-A",follows:true,recording:true)) }
            let closed = fixture.closures.next("A's transport closed")
            audio.end()
            await fulfillment(of:[closed],timeout:5)
            // The extension drops the session and the tab starts call B.
            let moved = log.next("A's session gone and the tab on call B") { peers in
                peers.contains { $0.id == peer && $0.captures.isEmpty && $0.meetings.contains { $0.key.tabID == 2 && $0.callGeneration == "call-B" } }
            }
            try send(["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready","sessions":[]],control)
            try send(["type":"meetings","meetings":[meeting(2,"call-B")]],control)
            await fulfillment(of:[moved],timeout:5)
            let snapshot = try XCTUnwrap(log.peers.first { $0.id == peer })
            let reported = snapshot.captures.first { $0.captureID == "lost-a" }?.callGeneration
            let current = snapshot.meetings.first { $0.key.tabID == 2 }?.callGeneration
            XCTAssertNil(reported); XCTAssertEqual(current,"call-B")
            XCTAssertNil(BrowserCallPolicy.endForCallChange(started:reported,current:current),"the session's own report alone cannot see the change")
            // The app's next binding has no generation (no status lists the session): kept.
            ownership.update { $0.bind(owner.snapshot.manifest.id,.init(key:.init(peer:peer,tabID:2),callGeneration:nil,follows:true,recording:true)) }
            XCTAssertEqual(ownership.snapshot.endsForCallChange(owner.snapshot.manifest.id,reported:reported,current:current),.callEnded)
            // The app's per-poll decision, from the peers as published.
            XCTAssertEqual(ownership.follow(owner.snapshot.manifest.id,captureID:"lost-a",peers:log.peers).end,.callEnded)
            XCTAssertEqual(ownership.lostCalls,[.init(tabID:2,callGeneration:"call-A")],"A's loss never holds call B")
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    /// Review r3, second major: the worker restarts (audio EOF and control loss) and the new
    /// control connection's first snapshot reaches the service while the app's main actor is
    /// held behind a barrier, so nothing the app would publish has arrived. The broker already
    /// fed the loss, so the reconnect's auto-record Starts the other call and not the lost one.
    func testAReconnectNeverStartsALostCallWhileTheAppIsBehind() async throws {
        let ownership = CallOwnershipStore(), log = PeerLog()
        let app = DispatchQueue(label:"held main actor"), barrier = DispatchSemaphore(value:0)
        app.async { barrier.wait() }
        defer { barrier.signal() }
        let fixture = try AudioFixture(ownership:ownership,changed:{ peers in
            log.changed(peers)
            // Where the app would react (feed, publish): held until the end of the test.
            app.async {}
        })
        do {
            fixture.service.setAutoRecord(true,microphone:false)
            var old: PipeEndpoint? = try connect(fixture,meetings:[(2,"call-A")],sessions:[(2,"lost-b","call-A")])
            let bound = log.next("the session is reported") { $0.contains { $0.captures.contains { $0.captureID == "lost-b" } } }
            await fulfillment(of:[bound],timeout:5)
            let peer = try XCTUnwrap(log.peers.first { $0.reconciled }).id
            let (audio,owner) = try startCapture(fixture,"lost-b")
            // Fed when the recording was created, long before any loss.
            ownership.update { $0.bind(owner.snapshot.manifest.id,.init(key:.init(peer:peer,tabID:2),callGeneration:"call-A",follows:true,recording:true)) }
            let closed = fixture.closures.next("the transport closed"), gone = log.next("the old control peer is gone") { !$0.contains { $0.id == peer } }
            audio.end(); old = nil
            await fulfillment(of:[closed,gone],timeout:5)
            XCTAssertNil(old)
            XCTAssertEqual(ownership.lostCalls,[.init(tabID:2,callGeneration:"call-A")],"fed by the broker, not the app")
            // The reconnect: the lost call (tab 2, ordered first) and a new call in tab 3.
            let new = try connect(fixture,meetings:[(2,"call-A"),(3,"call-C")],sessions:[])
            let first = try receive(new)
            XCTAssertEqual(first["action"]?.string,"start")
            XCTAssertEqual(first["tabId"]?.int,3,"the lost call is never Started again: \(first)")
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    /// #113 gap: the audio side closes before any status listed the session. The broker
    /// recorded the call at Start, so the recording holds it with no feed from the app at all
    /// (held behind a barrier here), and the reconnect Starts only the other call.
    func testARecordingLostBeforeAnyStatusStillHoldsItsCall() async throws {
        let ownership = CallOwnershipStore(), log = PeerLog()
        let app = DispatchQueue(label:"held main actor"), barrier = DispatchSemaphore(value:0)
        app.async { barrier.wait() }
        defer { barrier.signal() }
        let fixture = try AudioFixture(ownership:ownership,changed:{ peers in log.changed(peers); app.async {} })
        do {
            fixture.service.setAutoRecord(true,microphone:false)
            var old: PipeEndpoint? = try connect(fixture,meetings:[(2,"call-A")],sessions:[])
            // Auto-record Starts the call; the extension opens the audio side with that call.
            let command = try receive(try XCTUnwrap(old))
            XCTAssertEqual(command["action"]?.string,"start"); XCTAssertEqual(command["tabId"]?.int,2)
            let generation = try XCTUnwrap(command["callGeneration"]?.string)
            let peer = try XCTUnwrap(log.peers.first { $0.reconciled }).id
            let audio = try fixture.client()
            let started = try audio.request(["type":"start","version":1,"independent":true,"captureId":"early","timelineOriginMs":Int(Date().timeIntervalSince1970*1000),
                                             "microphone":false,"title":"Call","features":["source-outcomes-v1"],"callGeneration":generation,"documentGeneration":"doc-1"])
            let owner = try XCTUnwrap(fixture.broker.activeCaptures.first { $0.snapshot.directory.path == started["path"]?.string },"\(started)")
            let id = owner.snapshot.manifest.id
            XCTAssertEqual(ownership.snapshot.binding(id)?.callGeneration,generation,"recorded at Start")
            XCTAssertNil(ownership.snapshot.binding(id)?.key,"no status has named its tab")
            // The worker restarts before any status listed the session.
            let closed = fixture.closures.next("the transport closed"), gone = log.next("the old control peer is gone") { !$0.contains { $0.id == peer } }
            audio.end(); old = nil
            await fulfillment(of:[closed,gone],timeout:5)
            XCTAssertNil(old)
            let new = try connect(fixture,meetings:[(2,generation),(3,"call-C")],sessions:[])
            let first = try receive(new)
            XCTAssertEqual(first["action"]?.string,"start")
            XCTAssertEqual(first["tabId"]?.int,3,"no second recording of the call: \(first)")
            // The recording follows its call to the new peer by its generation alone.
            let reported = log.next("the new peer reports the call") { $0.contains { $0.reconciled && $0.id != peer && $0.meetings.contains { $0.key.tabID == 2 } } }
            await fulfillment(of:[reported],timeout:5)
            let follow = ownership.follow(id,captureID:"early",peers:log.peers)
            XCTAssertTrue(follow.rebound); XCTAssertEqual(follow.key?.tabID,2); XCTAssertNotEqual(follow.key?.peer,peer)
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    /// Round 4, first major: whichever comes first, the app's creation feed or the broker's
    /// Start record, the recording ends up holding its call.
    func testTheStartRecordAndTheAppFeedAgreeInEitherOrder() {
        var appFirst = CallOwnership(), brokerFirst = CallOwnership(); let id = UUID()
        appFirst.bind(id,.init(key:nil,callGeneration:nil,follows:true,recording:true))
        appFirst.started(id,callGeneration:"call-A")
        XCTAssertEqual(appFirst.binding(id)?.callGeneration,"call-A","an existing binding gains the generation it lacks")
        brokerFirst.started(id,callGeneration:"call-A")
        brokerFirst.bind(id,.init(key:nil,callGeneration:nil,follows:true,recording:true))
        XCTAssertEqual(brokerFirst.binding(id)?.callGeneration,"call-A")
        appFirst.started(id,callGeneration:"call-Z")
        XCTAssertEqual(appFirst.binding(id)?.callGeneration,"call-A","never replaced")
    }
    /// Round 4, first major, through the real host: the creation callback (the app's first
    /// feed) runs only after the broker recorded the call, and carries the generation itself.
    func testTheCreationCallbackSeesTheCallAlreadyRecorded() async throws {
        let ownership = CallOwnershipStore(), seen = Seen()
        let called = expectation(description:"the creation callback ran")
        let fixture = try AudioFixture(ownership:ownership,created:{ owner,info in
            let id = owner.snapshot.manifest.id
            seen.store(recorded:ownership.snapshot.binding(id)?.callGeneration,info:info.callGeneration)
            // What the app feeds at creation.
            ownership.update { $0.bind(id,.init(key:nil,callGeneration:info.callGeneration,follows:true,recording:true)) }
            called.fulfill()
        })
        do {
            let (audio,owner) = try startCapture(fixture,"ordered")
            await fulfillment(of:[called],timeout:5)
            XCTAssertEqual(seen.recorded,"call-A","recorded before the callback was dispatched")
            XCTAssertEqual(seen.info,"call-A","and handed to it")
            XCTAssertEqual(ownership.snapshot.binding(owner.snapshot.manifest.id)?.callGeneration,"call-A")
            audio.end()
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
    /// Round 4, second major, and round 5: transport loss, a resume that never joins, then the
    /// meeting row disappears with no active session left. The extension keeps the session as
    /// interrupted history whose last pageState is "present". The call is no longer visible, so
    /// that history counts for nothing, the D52 grace runs and the recording stops as pageGone
    /// at 120 s. It used to be taken as present (control connected, or the historical page)
    /// with unknown inventory, and recorded on until stopped by hand.
    func testALostRecordingStopsWhenItsMeetingRowDisappears() async throws {
        let ownership = CallOwnershipStore(), log = PeerLog()
        let fixture = try AudioFixture(ownership:ownership,changed:{ log.changed($0) })
        do {
            let control = try connect(fixture,capabilities:resumeCapabilities,meetings:[(2,"call-A")],sessions:[(2,"gone","call-A")])
            let bound = log.next("the session is reported") { $0.contains { $0.captures.contains { $0.captureID == "gone" } } }
            await fulfillment(of:[bound],timeout:5)
            let peer = try XCTUnwrap(log.peers.first { $0.reconciled }).id
            let (audio,owner) = try startCapture(fixture,"gone")
            let id = owner.snapshot.manifest.id
            ownership.update { $0.bind(id,.init(key:.init(peer:peer,tabID:2),callGeneration:"call-A",follows:true,recording:true)) }
            let closed = fixture.closures.next("the transport closed")
            audio.end()
            await fulfillment(of:[closed],timeout:5)
            try await owner.requestSystemFallback()
            let stage = StagedNativeWriter()
            try stage.addTrack(id:"system",label:"System",kind:"system",sampleRate:8000,channels:1)
            try stage.appendNative(id:"system",pcm:Data(repeating:2,count:1600),offsetMs:1000)
            try await owner.activateNative(stage,side:.others,allowed:{ true })
            var policy = BrowserCallPolicy(resumeCapture:true,callGeneration:"call-A",heard:true)
            var asked = 0
            // As the app builds its observation (no page reports here).
            func poll(_ now: TimeInterval, legacyPresent: Bool = false) -> BrowserCallLifecycle.Action? {
                let follow = ownership.follow(id,captureID:"gone",peers:log.peers)
                let current = log.peers.first { $0.id == follow.key?.peer && $0.reconciled }
                let row = current?.meetings.first { $0.key == follow.key }
                // As the app does: the session's report (interrupted history included) and the row's.
                let status = ((current?.captures ?? []) + (current?.interrupted ?? [])).first { $0.captureID == "gone" }
                let reports = [status?.pageState.map { ($0,status?.pageStateAt) },row?.pageState.map { ($0,row?.pageStateAt) }].compactMap { $0 }
                let page: BrowserCallLifecycle.Page? = legacyPresent
                    ? (reports.max { ($0.1 ?? 0) < ($1.1 ?? 0) }?.0 ?? (current == nil ? nil : .present))
                    : (CallOwnership.page(reports,callVisible:follow.callVisible)?.0 ?? (follow.callVisible ? .present : nil))
                var o = BrowserCallPolicy.Observation(page:page,rowPresent:row != nil,sourceCount:row?.sourceCount,sourceCountKnown:row?.sourceCountKnown ?? false,
                                                      heard:row?.heard ?? false,controlAlive:current != nil,transportAlive:owner.snapshot.transportAlive,
                                                      callGeneration:row?.callGeneration,controlConnection:current?.id.uuidString ?? "")
                o.sessionListed = follow.sessionListed
                let committed = CaptureSourceState(events:owner.snapshot.manifest.events ?? [],atMs:.infinity)
                return BrowserCallPolicy.decide(pending:false,multiStream:follow.multiStream,policy:&policy,now:now,o,source:committed.source,reason:committed.reason,
                                                others:true,restoreReady:false,legacy:{ nil },onAskResume:{ asked += 1 })
            }
            // The extension keeps the session only as interrupted history, last seen present; the
            // one resume ask goes out and never joins.
            let dropped = log.next("the session is only interrupted history, last present") { peers in
                peers.contains { $0.id == peer && $0.captures.isEmpty && $0.interrupted.contains { $0.captureID == "gone" && $0.pageState == .present } }
            }
            try send(["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready","sessions":[],
                      "interrupted":[session((2,"gone","call-A"),recording:false,pageState:"present")]],control)
            await fulfillment(of:[dropped],timeout:5)
            XCTAssertNil(poll(100)); XCTAssertEqual(asked,1)
            // The last source leaves and the extension removes the meeting row.
            let vanished = log.next("the meeting row is gone") { $0.contains { $0.id == peer && $0.meetings.isEmpty } }
            try send(["type":"meetings","meetings":[]],control)
            await fulfillment(of:[vanished],timeout:5)
            XCTAssertFalse(ownership.follow(id,captureID:"gone",peers:log.peers).callVisible)
            var legacy = policy
            XCTAssertNil(poll(101))
            XCTAssertNil(poll(220),"within the grace")
            XCTAssertEqual(poll(221),.stop(.pageGone),"bounded: 120 s after the call left")
            // What the old observation did: the historical present (or control being connected)
            // kept the page present, forever.
            swap(&policy,&legacy)
            XCTAssertNil(poll(101,legacyPresent:true)); XCTAssertNil(poll(1000,legacyPresent:true))
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    /// Review r3, third major: after a worker restart the new extension keeps the old session
    /// as interrupted history. That is not a listed session, so the recovered call is asked
    /// once to resume, and the resume joins the original folder.
    func testAWorkerRestartWithInterruptedHistoryResumesOnceIntoTheOriginalFolder() async throws {
        let ownership = CallOwnershipStore(), log = PeerLog()
        let fixture = try AudioFixture(ownership:ownership,changed:{ log.changed($0) })
        do {
            var old: PipeEndpoint? = try connect(fixture,capabilities:resumeCapabilities,meetings:[(2,"call-A")],sessions:[(2,"orig","call-A")])
            let bound = log.next("the session is reported") { $0.contains { $0.captures.contains { $0.captureID == "orig" } } }
            await fulfillment(of:[bound],timeout:5)
            let oldPeer = try XCTUnwrap(log.peers.first { $0.reconciled }).id
            let (audio,owner) = try startCapture(fixture,"orig")
            let id = owner.snapshot.manifest.id, folder = owner.snapshot.directory
            ownership.update { $0.bind(id,.init(key:.init(peer:oldPeer,tabID:2),callGeneration:"call-A",follows:true,recording:true)) }
            // The worker restarts: both pipes close.
            let closed = fixture.closures.next("the transport closed"), gone = log.next("the old control peer is gone") { !$0.contains { $0.id == oldPeer } }
            audio.end(); old = nil
            await fulfillment(of:[closed,gone],timeout:5)
            XCTAssertNil(old)
            // The new worker reports the call and keeps the old session as interrupted history.
            let recovered = log.next("the new peer reports the call and the interrupted session") { peers in
                peers.contains { $0.reconciled && $0.interrupted.contains { $0.captureID == "orig" } && $0.meetings.contains { $0.key.tabID == 2 } }
            }
            let new = try connect(fixture,capabilities:resumeCapabilities,meetings:[(2,"call-A")],sessions:[],interrupted:[(2,"orig","call-A")])
            await fulfillment(of:[recovered],timeout:5)
            let peer = try XCTUnwrap(log.peers.first { $0.reconciled && $0.id != oldPeer })
            // The app's per-poll decision, from the peers as published.
            let follow = ownership.follow(id,captureID:"orig",peers:log.peers)
            let key = try XCTUnwrap(follow.key)
            XCTAssertEqual(key,.init(peer:peer.id,tabID:2),"the recording follows its call to the new peer")
            XCTAssertTrue(follow.multiStream); XCTAssertNil(follow.end)
            ownership.update { $0.bind(id,.init(key:key,callGeneration:"call-A",follows:true,recording:true)) }
            XCTAssertTrue((peer.captures + peer.interrupted).contains { $0.key.tabID == 2 },"the old rule counted the history as a session")
            XCTAssertFalse(follow.sessionListed)
            // The fallback commits system/lost with its first PCM.
            try await owner.requestSystemFallback()
            let stage = StagedNativeWriter()
            try stage.addTrack(id:"system",label:"System",kind:"system",sampleRate:8000,channels:1)
            try stage.appendNative(id:"system",pcm:Data(repeating:2,count:1600),offsetMs:1000)
            try await owner.activateNative(stage,side:.others,allowed:{ true })
            var policy = BrowserCallPolicy(resumeCapture:true,callGeneration:"call-A",heard:true)
            var asks = 0
            let armed = expectation(description:"the resume is armed with the call's generation")
            func poll(_ now: TimeInterval) {
                let snapshot = owner.snapshot
                let committed = CaptureSourceState(events:snapshot.manifest.events ?? [],atMs:.infinity)
                let current = ownership.follow(id,captureID:"orig",peers:log.peers)
                let row = log.peers.first { $0.id == current.key?.peer }?.meetings.first { $0.key == current.key }
                var o = BrowserCallPolicy.Observation(page:.present,rowPresent:row != nil,sourceCount:row?.sourceCount,heard:row?.heard ?? false,
                                                      transportAlive:snapshot.transportAlive,callGeneration:row?.callGeneration,controlConnection:current.key?.peer.uuidString ?? "")
                o.sessionListed = current.sessionListed
                _ = BrowserCallPolicy.decide(pending:false,multiStream:true,policy:&policy,now:now,o,source:committed.source,reason:committed.reason,
                                             others:snapshot.others,restoreReady:snapshot.restoreReady,legacy:{ nil },onAskResume:{
                    asks += 1
                    // As the app's askResume does.
                    guard let identity = fixture.broker.standInIdentity(owner) else { return XCTFail("not a resume target") }
                    let broker = fixture.broker
                    fixture.service.resumeMeeting(key,captureID:identity.captureID,timelineOriginMs:identity.timelineOriginMs,expectedGeneration:"call-A") { generation in
                        broker.expectResume(owner,callGeneration:generation); armed.fulfill()
                    }
                })
            }
            poll(10)
            XCTAssertEqual(asks,1,"one ask, despite the interrupted history")
            await fulfillment(of:[armed],timeout:5)
            // The extension receives the resume command and resumes the original capture.
            let command = try receive(new)
            XCTAssertEqual(command["resumeCapture"]?["captureId"]?.string,"orig","\(command)")
            let origin = try XCTUnwrap(command["resumeCapture"]?["timelineOriginMs"]?.int)
            let resumed = try fixture.client().request(["type":"resume","version":1,"independent":true,"captureId":"orig","timelineOriginMs":origin,
                                                        "callGeneration":"call-A","features":["source-outcomes-v1","resume-capture-v1"]])
            XCTAssertEqual(resumed["resumed"]?.bool,true,"\(resumed)")
            XCTAssertEqual(resumed["path"]?.string,folder.path,"into the original folder")
            poll(11); poll(12)
            XCTAssertEqual(asks,1,"never asked again")
            let library = fixture.root.appendingPathComponent("Library")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:library.path).filter { $0.hasPrefix("Recording-") }.count,1)
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    /// Review of the state machine: the per-meeting Retry reads ownership at admission too. The
    /// session leaves the status first, then the transport closes: no control frame (and so no
    /// reconcile) comes between the broker's loss and the Retry.
    func testARetryNeverStartsAHeldCall() async throws {
        let ownership = CallOwnershipStore(), log = PeerLog()
        let fixture = try AudioFixture(ownership:ownership,changed:{ log.changed($0) })
        do {
            let control = try connect(fixture,meetings:[(2,"call-A")],sessions:[(2,"held","call-A")])
            let bound = log.next("the session is reported") { $0.contains { $0.captures.contains { $0.captureID == "held" } } }
            await fulfillment(of:[bound],timeout:5)
            let peer = try XCTUnwrap(log.peers.first { $0.reconciled }).id
            let (audio,owner) = try startCapture(fixture,"held")
            ownership.update { $0.bind(owner.snapshot.manifest.id,.init(key:.init(peer:peer,tabID:2),callGeneration:"call-A",follows:true,recording:true)) }
            let gone = log.next("the session left the status") { $0.contains { $0.id == peer && $0.captures.isEmpty } }
            try send(["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready","sessions":[]],control)
            await fulfillment(of:[gone],timeout:5)
            let closed = fixture.closures.next("the transport closed")
            audio.end()
            await fulfillment(of:[closed],timeout:5)
            fixture.service.recordMeeting(.init(peer:peer,tabID:2),microphone:false)
            // The next frame on the pipe is the Start for a new call asked afterwards.
            let reported = log.next("the new call is reported") { $0.contains { $0.id == peer && $0.meetings.contains { $0.key.tabID == 3 } } }
            try send(["type":"meetings","meetings":[meeting(2,"call-A"),meeting(3,"call-C")]],control)
            await fulfillment(of:[reported],timeout:5)
            fixture.service.recordMeeting(.init(peer:peer,tabID:3),microphone:false)
            let first = try receive(control)
            XCTAssertEqual(first["tabId"]?.int,3,"the held call is never Started by a Retry: \(first)")
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
    /// Review of the state machine: a user's Stop releases the hold only through the control
    /// queue, after its Stop memory, so the released call is not auto-Started again.
    func testAUserStopReleasesTheHoldAfterItsStopMemory() async throws {
        let ownership = CallOwnershipStore(), log = PeerLog()
        let fixture = try AudioFixture(ownership:ownership,changed:{ log.changed($0) })
        do {
            fixture.service.setAutoRecord(true,microphone:false)
            let control = try connect(fixture,meetings:[(2,"call-A")],sessions:[(2,"stopped","call-A")])
            let bound = log.next("the session is reported") { $0.contains { $0.captures.contains { $0.captureID == "stopped" } } }
            await fulfillment(of:[bound],timeout:5)
            let peer = try XCTUnwrap(log.peers.first { $0.reconciled }).id
            let (audio,owner) = try startCapture(fixture,"stopped")
            let id = owner.snapshot.manifest.id, key = BrowserMeetingKey(peer:peer,tabID:2)
            ownership.update { $0.bind(id,.init(key:key,callGeneration:"call-A",follows:true,recording:true)) }
            let closed = fixture.closures.next("the transport closed"), gone = log.next("the session left the status") { $0.contains { $0.id == peer && $0.captures.isEmpty } }
            audio.end()
            try send(["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready","sessions":[]],control)
            await fulfillment(of:[closed,gone],timeout:5)
            // The app's Stop: the Stop memory first, then the ordered release.
            fixture.service.rememberUserStop(captureID:"stopped",key:key)
            fixture.service.updateOwnership { $0.bind(id,.init(key:key,callGeneration:"call-A",follows:true,recording:false)) }
            try send(["type":"meetings","meetings":[meeting(2,"call-A"),meeting(3,"call-C")]],control)
            let first = try receive(control)
            XCTAssertEqual(first["action"]?.string,"start")
            XCTAssertEqual(first["tabId"]?.int,3,"the call the user stopped is not started again: \(first)")
            XCTAssertEqual(ownership.lostCalls,[],"released")
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    // MARK: helpers

    private func meeting(_ tab: Int, _ generation: String) -> [String:Any] {
        ["tabId":tab,"title":"Call","url":"https://meet.example/\(tab)","sourceCount":1,"heard":true,"callGeneration":generation]
    }
    private func session(_ row: (Int,String,String), recording: Bool, pageState: String? = nil) -> [String:Any] {
        var value: [String:Any] = ["tabId":row.0,"captureId":row.1,"recording":recording,"path":NSNull(),"message":recording ? "Recording" : "Interrupted","callGeneration":row.2]
        if let pageState { value["pageState"] = pageState }
        return value
    }
    private func connect(_ fixture: AudioFixture, capabilities: [String] = ["independent-sessions-v1","multi-stream-v1"], meetings: [(Int,String)],
                         sessions: [(Int,String,String)], interrupted: [(Int,String,String)] = []) throws -> PipeEndpoint {
        let client = try PipeEndpoint(root:fixture.ipc,role:.control,browser:"Chrome",browserInstance:instance)
        try send(["type":"hello","version":1,"capabilities":capabilities],client)
        try send(["type":"meetings","meetings":meetings.map { meeting($0.0,$0.1) }],client)
        var status: [String:Any] = ["type":"status","recording":!sessions.isEmpty,"tabId":sessions.first.map { $0.0 as Any } ?? NSNull(),"path":NSNull(),
                                    "message":"Status","sessions":sessions.map { session($0,recording:true) }]
        if !interrupted.isEmpty { status["interrupted"] = interrupted.map { session($0,recording:false) } }
        try send(status,client)
        return client
    }
    private func startCapture(_ fixture: AudioFixture, _ id: String) throws -> (NativeAudioClient,OwnedBrowserCapture) {
        let audio = try fixture.client()
        let started = try audio.request(["type":"start","version":1,"independent":true,"captureId":id,"timelineOriginMs":Int(Date().timeIntervalSince1970*1000),
                                         "microphone":false,"title":"Call","features":["source-outcomes-v1"],"callGeneration":"call-A","documentGeneration":1])
        let owner = try XCTUnwrap(fixture.broker.activeCaptures.first { $0.snapshot.directory.path == started["path"]?.string },"\(started)")
        XCTAssertEqual(try audio.request(["type":"track","id":"a","kind":"remote","label":"Guest","sampleRate":8000,"channels":1,"sourceTrackId":"guest"])["type"]?.string,"ack")
        XCTAssertEqual(try audio.request(["type":"audio","id":"a","sequence":0,"offsetMs":0,"pcm":Data(repeating:1,count:1600).base64EncodedString()])["type"]?.string,"ack")
        return (audio,owner)
    }
    private func send(_ value: [String:Any], _ client: PipeEndpoint) throws { try client.send(JSONSerialization.data(withJSONObject:value)) }
    private func receive(_ client: PipeEndpoint, seconds: Double = 5) throws -> JSON {
        guard let data = try client.receive(deadline:DispatchTime.now().uptimeNanoseconds + UInt64(seconds*1_000_000_000)) else { throw BrowserIPCError.closed }
        return try JSONParser.parse(data)
    }
}

/// The service's published peers, with expectations fulfilled when a predicate first holds.
/// Register before causing the change; a predicate already true fulfills at once.
private final class PeerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [BrowserControlPeerSnapshot] = []
    private var waiting: [(([BrowserControlPeerSnapshot]) -> Bool,XCTestExpectation)] = []
    var peers: [BrowserControlPeerSnapshot] { lock.withLock { latest } }
    func changed(_ peers: [BrowserControlPeerSnapshot]) {
        let hit: [XCTestExpectation] = lock.withLock {
            latest = peers
            let ready = waiting.filter { $0.0(peers) }.map(\.1)
            waiting.removeAll { entry in ready.contains { $0 === entry.1 } }
            return ready
        }
        for expectation in hit { expectation.fulfill() }
    }
    func next(_ description: String, _ predicate: @escaping ([BrowserControlPeerSnapshot]) -> Bool) -> XCTestExpectation {
        let value = XCTestExpectation(description:description)
        let now = lock.withLock { () -> Bool in
            if predicate(latest) { return true }
            waiting.append((predicate,value)); return false
        }
        if now { value.fulfill() }
        return value
    }
}


private final class Seen: @unchecked Sendable {
    private let lock = NSLock(); private var values: (String?,String?) = (nil,nil)
    func store(recorded: String?, info: String?) { lock.withLock { values = (recorded,info) } }
    var recorded: String? { lock.withLock { values.0 } }
    var info: String? { lock.withLock { values.1 } }
}
