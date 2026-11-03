// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
import CassiniLibrary
import CassiniRecording
@testable import CassiniBrowserControl

/// D58 #10 with protocol #37: a refused resume ask is `startRejected/resumeRefused` at the ask's
/// own time in the recording it asked to join, once, from whichever answer comes first: its
/// own ok:false result (the code is the message) or the native refusal carrying its requestId.
/// A closed connection, a timeout, a native refusal without an id or with an unknown one, and
/// any late answer record nothing. Each step waits for the previous one's reply (E1), and every
/// check waits for the recording's queue to run what was enqueued before it.
final class D58ResumeRefusalTests: XCTestCase, @unchecked Sendable {
    private let origin = 1793500000000
    private let nativeMessage = "The recording cannot be resumed."
    private let key = BrowserMeetingKey(peer:UUID(),tabID:7)
    private func resume(_ id: String, generation: String, requestID: Any? = nil) -> [String:Any] {
        var packet: [String:Any] = ["type":"resume","version":1,"independent":true,"captureId":id,"timelineOriginMs":origin,"callGeneration":generation,
                                    "features":["source-outcomes-v1","resume-capture-v1"]]
        if let requestID { packet["requestId"] = requestID }
        return packet
    }
    private func standIn(_ fixture: AudioFixture) throws -> (OwnedBrowserCapture,String) {
        let capture = try OwnedBrowserCapture(parent:fixture.root.appendingPathComponent("Library"),title:"Stand-in",microphone:true,browser:false,changed:{ _ in })
        let system = capture.nativeWriter(side:.others)
        try system.addTrack(id:"output",label:"Others",kind:"system",sampleRate:8000,channels:1)
        try system.appendNative(id:"output",pcm:Data(repeating:0,count:1600),offsetMs:0)
        try fixture.broker.ownNative(capture,timelineOriginMs:origin)
        return (capture,try XCTUnwrap(fixture.broker.standInIdentity(capture)).captureID)
    }
    private func run(_ body: (AudioFixture) async throws -> Void) async throws {
        let fixture = try AudioFixture()
        do { try await body(fixture) } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
    private func reply(_ id: String, code: String?, error: String? = nil) -> BrowserControlOutcome {
        .init(requestID:id,key:key,action:.start,ok:false,error:error,code:code,resume:true)
    }
    private func lost(_ id: String, _ failure: String) -> BrowserControlOutcome {
        .init(requestID:id,key:key,action:.start,ok:false,error:nil,failure:failure,resume:true)
    }

    /// browser-protocol/conformance/control/resume-capture-vectors.json `askAttribution`.
    func testAskAttributionVectors() async throws {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-protocol/conformance/control/resume-capture-vectors.json")
        let vectors = try XCTUnwrap(JSONParser.parse(Data(contentsOf:url))["askAttribution"])
        let entry = try XCTUnwrap(vectors["entry"]), cases = try XCTUnwrap(vectors["cases"]?.array)
        XCTAssertEqual(cases.count,9)
        for vector in cases {
            let name = vector["name"]?.string ?? "?"
            try await run { fixture in
                let (capture,captureID) = try standIn(fixture)
                var ids: [String:String] = [:], askedAt: [String:Double] = [:], connection: [String:Int] = [:], replied: Set<String> = []
                var nativeMessages: [String:String] = [:]
                for (index,step) in (vector["steps"]?.array ?? []).enumerated() {
                    let ask = step["ask"]?.string ?? ""
                    switch step["op"]?.string {
                    case "ask":
                        let id = UUID().uuidString.lowercased(), at = Double(1000 * (index + 1))
                        ids[ask] = id; askedAt[ask] = at; connection[ask] = step["connection"]?.int
                        fixture.broker.expectResume(capture,callGeneration:"call-\(ask)",ask:(id,at))
                    case "reply":
                        replied.insert(ask)
                        fixture.broker.resumeAnswered(reply(try XCTUnwrap(ids[ask]),code:step["code"]?.string,error:step["error"]?.string))
                    case "close":
                        // The service's outcome for every unanswered ask still pending on that connection.
                        for (name,id) in ids where connection[name] == step["connection"]?.int && !replied.contains(name) {
                            fixture.broker.resumeAnswered(lost(id,"disconnected"))
                        }
                    case "native":
                        nativeMessages[ask] = step["message"]?.string
                        let answer = try fixture.client().request(resume(captureID,generation:"call-gone",requestID:try XCTUnwrap(ids[ask])))
                        XCTAssertEqual(answer["code"]?.string,"state",name)
                    case "nativeWithoutId":
                        XCTAssertEqual(try fixture.client().request(resume(captureID,generation:"call-gone"))["code"]?.string,"state",name)
                    case "nativeUnknownId":
                        XCTAssertEqual(try fixture.client().request(resume(captureID,generation:"call-gone",requestID:UUID().uuidString.lowercased()))["code"]?.string,"state",name)
                    default: XCTFail("Unknown op in \(name)")
                    }
                }
                await capture.settled()   // The refusal is written on the recording's queue.
                let refusals = capture.snapshot.manifest.refusals ?? []
                let expected = vector["expect"]?["entries"]?.array ?? []
                XCTAssertEqual(refusals.count,expected.count,name)
                for (written,wanted) in zip(refusals,expected) {
                    let ask = wanted["ask"]?.string ?? ""
                    XCTAssertEqual(written.atMs,askedAt[ask],"\(name): \(ask) at its own ask time")
                    XCTAssertEqual(written.side,entry["side"]?.string); XCTAssertEqual(written.code,entry["code"]?.string); XCTAssertEqual(written.detail,entry["detail"]?.string)
                    // The Mac host's own native message stands in for the vector's.
                    let message = wanted["message"]?.string
                    XCTAssertEqual(written.message,message == nativeMessages[ask] ? nativeMessage : message,"\(name): \(ask)")
                }
                let pending = fixture.broker.pendingResumeAsks(capture)
                XCTAssertEqual(pending,(vector["expect"]?["pending"]?.array ?? []).compactMap { $0.string.flatMap { ids[$0] } },"\(name): pending")
                XCTAssertEqual(capture.snapshot.manifest.state,"recording","\(name): a refusal never changes state")
            }
        }
    }

    /// #120 review: answering a refused resume never waits for its checkpoint. With the
    /// recording's queue stalled (a slow Library disk), resumeAnswered returns at once on the
    /// main actor, and the refusal is written, once, when the disk catches up.
    func testARefusedResumeNeverBlocksTheMainActorOnAStalledDisk() async throws {
        try await run { fixture in
            let (capture,_) = try standIn(fixture)
            let id = UUID().uuidString.lowercased()
            fixture.broker.expectResume(capture,callGeneration:"call-A",ask:(id,1500))
            let disk = DispatchSemaphore(value:0), stalled = expectation(description:"disk stalled")
            capture.enqueue { stalled.fulfill(); disk.wait() }
            await fulfillment(of:[stalled],timeout:5)
            let answered = expectation(description:"main actor answered"), broker = fixture.broker, outcome = reply(id,code:"resumeRefused")
            Task { @MainActor in broker.resumeAnswered(outcome); answered.fulfill() }
            await fulfillment(of:[answered],timeout:5)
            XCTAssertNil(capture.snapshot.manifest.refusals,"Nothing is written while the disk is stalled")
            disk.signal()
            await capture.settled()
            XCTAssertEqual(capture.snapshot.manifest.refusals?.map(\.detail),["resumeRefused"])
            XCTAssertEqual(capture.snapshot.manifest.refusals?.first?.atMs,1500)
        }
    }
    func testATimeoutOrLocalFailureRecordsNothingAndTheAskStaysAnswerable() async throws {
        try await run { fixture in
            let (capture,captureID) = try standIn(fixture)
            let id = UUID().uuidString.lowercased()
            fixture.broker.expectResume(capture,callGeneration:"call-A",ask:(id,2500))
            fixture.broker.resumeAnswered(lost(id,"timeout"))
            fixture.broker.resumeAnswered(lost(id,"notReady"))
            await capture.settled()   // The refusal is written on the recording's queue.
            XCTAssertNil(capture.snapshot.manifest.refusals)
            XCTAssertEqual(fixture.broker.pendingResumeAsks(capture),[id])
            // Its own native refusal still records it, once.
            XCTAssertEqual(try fixture.client().request(resume(captureID,generation:"call-gone",requestID:id))["code"]?.string,"state")
            fixture.broker.resumeAnswered(reply(id,code:"resumeRefused"))
            await capture.settled()   // The refusal is written on the recording's queue.
            XCTAssertEqual(capture.snapshot.manifest.refusals?.map(\.message),[nativeMessage])
            await capture.settled()   // The refusal is written on the recording's queue.
            XCTAssertEqual(capture.snapshot.manifest.refusals?.first?.atMs,2500)
        }
    }
    func testAReplyWithoutACodeWritesNoMessage() async throws {
        try await run { fixture in
            let (capture,_) = try standIn(fixture)
            let id = UUID().uuidString.lowercased()
            fixture.broker.expectResume(capture,callGeneration:"call-A",ask:(id,1200))
            fixture.broker.resumeAnswered(reply(id,code:nil,error:"That recording could not be resumed."))
            await capture.settled()   // The refusal is written on the recording's queue.
            let entry = try XCTUnwrap(capture.snapshot.manifest.refusals?.first)
            XCTAssertEqual(entry.detail,"resumeRefused"); XCTAssertNil(entry.message)
        }
    }
    func testAPresentRequestIdOutsideTheDomainRefusesTheResumeAndRecordsNothing() async throws {
        try await run { fixture in
            let (capture,captureID) = try standIn(fixture)
            let id = UUID().uuidString.lowercased()
            fixture.broker.expectResume(capture,callGeneration:"call-A",ask:(id,1000))
            for bad: Any in ["",String(repeating:"a",count:129),-1,9007199254740992,1.5,NSNull(),true,["x"]] {
                XCTAssertEqual(try fixture.client().request(resume(captureID,generation:"call-A",requestID:bad))["code"]?.string,"source","\(bad)")
            }
            await capture.settled()   // The refusal is written on the recording's queue.
            XCTAssertNil(capture.snapshot.manifest.refusals); XCTAssertEqual(fixture.broker.pendingResumeAsks(capture),[id])
            // In-domain ids are accepted: an integer (never a Mac ask) and the ask's own string.
            XCTAssertEqual(try fixture.client().request(resume(captureID,generation:"call-gone",requestID:42))["code"]?.string,"state")
            XCTAssertEqual(try fixture.client().request(resume(captureID,generation:"call-A",requestID:id))["resumed"]?.bool,true)
            await capture.settled()   // The refusal is written on the recording's queue.
            XCTAssertNil(capture.snapshot.manifest.refusals)
        }
    }
    func testAnAttachAnswersEveryAskAndAStopForgetsThem() async throws {
        try await run { fixture in
            let (capture,captureID) = try standIn(fixture)
            let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
            fixture.broker.expectResume(capture,callGeneration:"call-A",ask:(first,1000))
            fixture.broker.expectResume(capture,callGeneration:"call-A",ask:(second,2000))
            XCTAssertEqual(try fixture.client().request(resume(captureID,generation:"call-A",requestID:second))["resumed"]?.bool,true)
            XCTAssertEqual(fixture.broker.pendingResumeAsks(capture),[])
            fixture.broker.resumeAnswered(reply(first,code:"resumeRefused"))
            await capture.settled()   // The refusal is written on the recording's queue.
            XCTAssertNil(capture.snapshot.manifest.refusals,"An attached recording records no late refusal")
        }
        try await run { fixture in
            let (capture,_) = try standIn(fixture)
            let id = UUID().uuidString.lowercased()
            fixture.broker.expectResume(capture,callGeneration:"call-A",ask:(id,1000))
            fixture.broker.expectResume(capture,callGeneration:nil)   // Stop fences and forgets.
            XCTAssertEqual(fixture.broker.pendingResumeAsks(capture),[])
            fixture.broker.resumeAnswered(reply(id,code:"gone"))
            await capture.settled()   // The refusal is written on the recording's queue.
            XCTAssertNil(capture.snapshot.manifest.refusals)
        }
    }
    func testOnlyTheNewestEightAsksStayAnswerable() async throws {
        try await run { fixture in
            let (capture,_) = try standIn(fixture)
            let ids = (0..<9).map { _ in UUID().uuidString.lowercased() }
            for (index,id) in ids.enumerated() { fixture.broker.expectResume(capture,callGeneration:"call-A",ask:(id,Double(index))) }
            XCTAssertEqual(fixture.broker.pendingResumeAsks(capture),Array(ids.dropFirst()))
            fixture.broker.resumeAnswered(reply(ids[0],code:"gone"))
            await capture.settled()   // The refusal is written on the recording's queue.
            XCTAssertNil(capture.snapshot.manifest.refusals,"A forgotten ask records nothing")
        }
    }
}

/// The control side: every resume ask is a fresh request flagged as a resume, and each of its
/// outcomes (result, timeout, closed connection) carries the flag and is never a Start refusal.
final class D58ResumeOutcomeTests: XCTestCase {
    let peer = UUID()
    private func send(_ value: [String:Any], _ state: inout BrowserControlRegistry) throws {
        try state.receive(JSONSerialization.data(withJSONObject:value),from:peer)
    }
    private func ready(_ state: inout BrowserControlRegistry) throws {
        try state.connect(.init(id:peer,role:.control,browser:"Chrome"))
        try send(["type":"hello","version":1,"capabilities":["independent-sessions-v1","multi-stream-v1","resume-capture-v1"]],&state)
        try send(["type":"meetings","meetings":[["tabId":2,"title":"Call","url":"https://meet.example/a","sourceCount":1,
            "sourceCountKnown":false,"callGeneration":"call-A","documentGeneration":"doc-1"]]],&state)
        try send(["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready","sessions":[]],&state)
    }
    func testResumeOutcomesAreFlaggedAndNeverAStartRefusal() throws {
        var state = BrowserControlRegistry(); try ready(&state)
        let key = BrowserMeetingKey(peer:peer,tabID:2)
        let (first,generation) = try state.resume(key,captureID:"native-1",timelineOriginMs:1793500000000)
        XCTAssertTrue(first.resume); XCTAssertEqual(generation,"call-A")
        let command = try JSONParser.parse(first.data)
        XCTAssertEqual(command["requestId"]?.string,first.id); XCTAssertNotNil(command["resumeCapture"])
        try send(["type":"result","requestId":first.id,"ok":false,"code":"resumeRefused","error":"That recording could not be resumed."],&state)
        let refused = try XCTUnwrap(state.outcomes.last)
        XCTAssertTrue(refused.resume); XCTAssertEqual(refused.code,"resumeRefused"); XCTAssertNil(refused.failure)
        XCTAssertNil(refused.startRefusal(),"A refused resume is never a Start refusal")
        let (second,_) = try state.resume(key,captureID:"native-1",timelineOriginMs:1793500000000)
        XCTAssertNotEqual(second.id,first.id,"Every ask gets a fresh requestId")
        state.failed(second)
        XCTAssertEqual(state.outcomes.last.map { [$0.resume ? "resume" : "start",$0.failure ?? ""] },["resume","timeout"])
        XCTAssertNil(state.outcomes.last?.startRefusal())
        let (third,_) = try state.resume(key,captureID:"native-1",timelineOriginMs:1793500000000)
        state.disconnect(peer)
        XCTAssertEqual(state.outcomes.last?.requestID,third.id)
        XCTAssertEqual(state.outcomes.last.map { [$0.resume ? "resume" : "start",$0.failure ?? ""] },["resume","disconnected"])
        XCTAssertNil(state.outcomes.last?.startRefusal())
    }
    func testAnOrdinaryStartIsNotAResume() throws {
        var state = BrowserControlRegistry(); try ready(&state)
        let start = try state.start(.init(peer:peer,tabID:2),microphone:false)
        XCTAssertFalse(start.resume); XCTAssertNil(try JSONParser.parse(start.data)["resumeCapture"])
        try send(["type":"result","requestId":start.id,"ok":false,"code":"busy","error":"Busy"],&state)
        XCTAssertEqual(state.outcomes.last?.startRefusal()?.detail,"busy")
    }
}
