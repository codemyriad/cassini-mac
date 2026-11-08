// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CassiniKit
@testable import CassiniBrowserControl

private final class VerifiedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func set(_ value: TimeInterval) { lock.withLock { self.value = value } }
    func now() -> TimeInterval { lock.withLock { value } }
}

private final class VerifiedActions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID] = []
    let first: XCTestExpectation, second: XCTestExpectation
    init(_ first: XCTestExpectation, _ second: XCTestExpectation) { self.first = first; self.second = second }
    var ids: [UUID] { lock.withLock { values } }
    func record(_ action: BrowserSignalAction) {
        if case let .start(id,_,_) = action {
            let count = lock.withLock { values.append(id); return values.count }
            if count == 1 { first.fulfill() } else if count == 2 { second.fulfill() }
        }
    }
}
private final class DispatchExpiry: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let clock: VerifiedClock, reached: XCTestExpectation
    init(_ clock: VerifiedClock, _ reached: XCTestExpectation) { self.clock = clock; self.reached = reached }
    func check() -> Bool {
        let index = lock.withLock { count += 1; return count }
        if index == 2 { clock.set(5); reached.fulfill() }
        return true
    }
}

final class VerifiedAdmissionTests: XCTestCase {
    private let pair = ["call-signals-v1","verified-auto-admission-v1"]
    private func vectors() throws -> [String:Any] {
        let file = ProcessInfo.processInfo.environment["CASSINI_CALL_SIGNAL_VECTORS"].map { URL(fileURLWithPath:$0) }
            ?? URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("browser-protocol/conformance/control/call-signals-vectors.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
    }
    private func send(_ packet: [String:Any], _ state: inout BrowserControlRegistry, _ id: UUID) throws {
        try state.receive(JSONSerialization.data(withJSONObject:packet),from:id)
    }
    private func initial(_ clock: VerifiedClock, id: UUID, ack: [String]? = nil) throws -> BrowserControlRegistry {
        var state = BrowserControlRegistry(clock:{ clock.now() })
        state.requireMultiStream = true; state.requireVerifiedAdmission = true
        try state.connect(.init(id:id,role:.control,browser:"Chromium"))
        try send(["type":"hello","version":1,"capabilities":pair+["independent-sessions-v1","multi-stream-v1","call-evidence-v1","page-state-v1"]],&state,id)
        try send(["type":"configured","capabilities":ack ?? pair],&state,id)
        try send(["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"sessions":[],"message":"Generated ready status"],&state,id)
        return state
    }
    private func row(_ remote: String = "separated") -> [String:Any] {
        ["tabId":2,"url":"https://generated.example/call","documentGeneration":"chrome-A","sourceDocumentGeneration":"hook-A",
         "remoteAudio":remote,"callEvidence":["state":"active","reason":"activeCall","adapter":["name":"webrtc-interactive","version":"1"],"callGeneration":"call-A"]]
    }
    private func signal(_ sequence: Int, remote: String = "separated") -> [String:Any] {
        ["type":"callSignals","browserInstance":"profile-A","sequence":sequence,"tabs":[row(remote)]]
    }
    private func meeting() -> [String:Any] {
        ["tabId":2,"title":"Generated interactive session","url":"https://generated.example/call","sourceCount":1,"sourceCountKnown":true,
         "heard":true,"pageState":"present","browserDocumentId":"chrome-A","documentGeneration":"hook-A","callGeneration":"call-A"]
    }
    private func peer(_ state: BrowserControlRegistry, _ id: UUID, sequence: Int? = nil) throws -> SignalCallPolicy.Peer {
        let snapshot = try XCTUnwrap(state.snapshots.first { $0.id == id }?.callSignals)
        return .init(id:id,order:1,snapshot:.init(instance:snapshot.instance,sequence:sequence ?? snapshot.sequence,tabs:snapshot.tabs),
                     active:state.signalActiveKeys(id),expiredAt:state.signalDeadlines(id))
    }
    private func pending(_ value: [String:Any]) throws -> BrowserVerifiedCall {
        .init(profile:try XCTUnwrap(value["browserInstance"] as? String),tab:try XCTUnwrap(value["tabId"] as? Int),
              browserDocument:try XCTUnwrap(value["browserDocumentId"] as? String),sourceDocument:try XCTUnwrap(value["sourceDocumentGeneration"] as? String),
              generation:try XCTUnwrap(value["callGeneration"] as? String))
    }
    func testSharedRoutingAtBrowserStartAndMixedReservationBoundaries() throws {
        for vector in try XCTUnwrap(try vectors()["routing"] as? [[String:Any]]) {
            let name = try XCTUnwrap(vector["name"] as? String), expected = try XCTUnwrap(vector["expect"] as? [String:Any])
            let signal = try XCTUnwrap(vector["signal"] as? [String:Any]), clock = VerifiedClock(), id = UUID()
            var state = try initial(clock,id:id,ack:vector["configuredCapabilities"] as? [String] ?? [])
            var metadata: [String:Any] = ["tabId":2,"title":"Generated shared vector","url":"https://conference.invalid/session","sourceCount":0,"heard":false,"pageState":"present"]
            if let rtp = vector["rtp"] as? [String:Any] { metadata.merge(rtp) { _,new in new } }
            let rows = vector["legacyMeetings"] as? [[String:Any]] ?? [metadata]
            try send(["type":"meetings","meetings":rows],&state,id)
            do {
                // A known authenticated profile cannot change within a connection.
                if let profile = vector["connectionBrowserInstance"] as? String, profile != signal["browserInstance"] as? String {
                    try send(["type":"callSignals","browserInstance":profile,"sequence":0,"tabs":[]],&state,id)
                }
                try send(signal,&state,id)
            } catch {
                XCTAssertEqual(expected["browserStart"] as? Bool,false,name)
                XCTAssertEqual(expected["appSystemStart"] as? Bool,false,name)
                continue
            }
            clock.set(Double(vector["consumerEvidenceAgeMs"] as? Int ?? 0)/1000)
            let enabled = vector["autoRecordOptIn"] as? Bool ?? false
            XCTAssertEqual(enabled ? state.automaticStarts(microphone:true).count : 0,expected["browserStart"] as? Bool == true ? 1 : 0,name)
            var policy = SignalCallPolicy()
            var token: UUID?
            if let value = vector["pendingBinding"] as? [String:Any] {
                let binding = try pending(value)
                let prior = BrowserCallSignal(tabID:binding.tab,url:"https://generated.example/call",document:binding.browserDocument,remoteAudio:"mixed",
                    state:"active",reason:"activeCall",site:"webrtc-interactive",generation:binding.generation,sourceDocument:binding.sourceDocument)
                policy.update([.init(id:id,order:1,snapshot:.init(instance:binding.profile,sequence:0,tabs:[prior]),active:[binding.signalKey])],now:0)
                policy.advance(now:0,enabled:true); token = policy.reserve()
            }
            if state.snapshots.first?.callSignals != nil { policy.update([try peer(state,id,sequence:1)],now:clock.now()) }
            else { policy.update([],now:clock.now()) }
            policy.advance(now:clock.now(),enabled:enabled)
            let native = token.map { policy.mayOpen($0) } ?? (policy.reserve() != nil)
            XCTAssertEqual(native,expected["appSystemStart"] as? Bool ?? false,name)
        }
    }
    func testSharedReceiptTimeFreshnessForBothRoutes() throws {
        let shared = try XCTUnwrap(try vectors()["freshness"] as? [String:Any])
        XCTAssertEqual(shared["consumerActiveExpiryMs"] as? Int,Int(BrowserActiveProof.lifetime*1000))
        for remote in ["separated","mixed"] {
            for vector in try XCTUnwrap(shared["cases"] as? [[String:Any]]) {
                let clock = VerifiedClock(), id = UUID(); var state = try initial(clock,id:id)
                if remote == "separated" { try send(["type":"meetings","meetings":[meeting()]],&state,id) }
                for step in try XCTUnwrap(vector["steps"] as? [[String:Any]]) {
                    clock.set(Double(try XCTUnwrap(step["atMs"] as? Int))/1000)
                    switch step["event"] as? String {
                    case "active", "replayed-active": try send(signal(try XCTUnwrap(step["sequence"] as? Int),remote:remote),&state,id)
                    case "configured": try send(["type":"configured","capabilities":step["capabilities"] ?? []],&state,id)
                    case "pong": try send(["type":"pong","seq":0],&state,id)
                    case "status": try send(["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"sessions":[],"message":"Generated heartbeat status"],&state,id)
                    case "meetings-heard": if remote == "separated" { try send(["type":"meetings","meetings":[meeting()]],&state,id) }
                    default:
                        // PCM/ticks/another call cannot renew this row. The producer
                        // must not publish the attempted cached active refresh;
                        // its counters are not fields a consumer can re-verify.
                        break
                    }
                    let expected = try XCTUnwrap(step["expect"] as? [String:Any])
                    let fresh = remote == "separated" ? state.automaticBinding(.init(peer:id,tabID:2)) != nil : !(state.signalActiveKeys(id)?.isEmpty ?? true)
                    XCTAssertEqual(fresh,expected["newAdmissionEligible"] as? Bool,"\(remote) \(vector["name"] ?? "") \(step)")
                }
            }
        }
    }
    func testUnknownAndMissingRowsWithdrawWithoutSourceUpdatesRenewing() throws {
        let clock = VerifiedClock(), id = UUID(); var state = try initial(clock,id:id)
        try send(["type":"meetings","meetings":[meeting()]],&state,id); try send(signal(0),&state,id)
        let request = try XCTUnwrap(state.automaticStarts(microphone:true).first)
        XCTAssertTrue(state.automaticRequestIsFresh(request))
        clock.set(5); XCTAssertFalse(state.automaticRequestIsFresh(request))
        try send(signal(1),&state,id); XCTAssertTrue(state.automaticRequestIsFresh(request))
        try send(["type":"callSignals","browserInstance":"profile-A","sequence":2,"tabs":[]],&state,id)
        XCTAssertFalse(state.automaticRequestIsFresh(request))
        try send(["type":"meetings","meetings":[meeting()]],&state,id)
        XCTAssertFalse(state.automaticRequestIsFresh(request))
    }
    func testMixedExpiryKeepsAcceptedOwnerAndFixedGrace() throws {
        let clock = VerifiedClock(), id = UUID(); var state = try initial(clock,id:id)
        try send(signal(0,remote:"mixed"),&state,id)
        var policy = SignalCallPolicy(); policy.update([try peer(state,id)],now:0); policy.advance(now:0,enabled:true)
        let token = try XCTUnwrap(policy.reserve()); policy.didStart(token)
        clock.set(5); policy.update([try peer(state,id)],now:5); policy.advance(now:5,enabled:true)
        XCTAssertTrue(policy.mayOpen(token)); XCTAssertNil(policy.retiring)
        XCTAssertEqual(policy.calls.values.first?.lostAt,5)
        clock.set(124.999); try send(["type":"pong","seq":0],&state,id)
        policy.update([try peer(state,id)],now:clock.now()); policy.advance(now:clock.now(),enabled:true)
        XCTAssertNil(policy.retiring); XCTAssertEqual(policy.calls.values.first?.lostAt,5)
        clock.set(125); policy.advance(now:clock.now(),enabled:true)
        XCTAssertEqual(policy.retiring,.pageGone); XCTAssertFalse(policy.mayOpen(token))
    }
    @MainActor func testFinalInputGateExpiresAtExactBoundary() throws {
        let clock = VerifiedClock(), gate = BrowserSignalInputGate(clock:{ clock.now() })
        gate.update(true,expiresAt:5); clock.set(5)
        var opened = false
        XCTAssertThrowsError(try gate.admit { opened = true })
        XCTAssertFalse(opened); XCTAssertFalse(gate.hasOpened)
        let running = BrowserSignalInputGate(clock:{ clock.now() }); clock.set(0); running.update(true,expiresAt:5)
        try running.admit { opened = true }; clock.set(5)
        XCTAssertTrue(running.permits,"Accepted owner keeps inputs through its separate grace")
        running.cancel(); XCTAssertFalse(running.permits)
    }
    func testBrowserReservationLeaseAndAcceptedOwnerGrace() throws {
        let clock = VerifiedClock(), id = UUID(); var state = try initial(clock,id:id)
        try send(["type":"meetings","meetings":[meeting()]],&state,id); try send(signal(0),&state,id)
        let request = try XCTUnwrap(state.automaticStarts(microphone:true).first)
        let store = BrowserAutomaticAdmissionStore(clock:{ clock.now() })
        try store.issue(request,browser:nil,generation:"call-A",document:"hook-A",microphone:true,deadline:5)
        let info = BrowserAudioStart(captureID:"generated-auto",timelineOriginMs:0,microphone:true,callGeneration:"call-A",documentGeneration:"hook-A")
        clock.set(5); XCTAssertThrowsError(try store.authorize(info,browser:nil))
        try send(signal(1),&state,id)
        store.update(pending:state.pendingAutomaticBindings,owned:state.currentAutomaticEvidence,ended:state.endedAutomaticEvidence)
        let accepted = try store.authorize(info,browser:nil)
        XCTAssertEqual(accepted.automaticCall,request.automaticCall)
        XCTAssertFalse(try XCTUnwrap(accepted.inputGate).hasOpened,"A directory is not an admitted input")
        try accepted.inputGate?.acceptOwner() // inert stand-in for the first admitted input
        XCTAssertTrue(try XCTUnwrap(accepted.inputGate).permits)
        clock.set(10); store.update(pending:state.pendingAutomaticBindings,owned:state.currentAutomaticEvidence,ended:[])
        XCTAssertNil(store.endReason(info.captureID)); XCTAssertTrue(accepted.inputGate?.permits == true)
        clock.set(129.999); XCTAssertNil(store.endReason(info.captureID))
        clock.set(130); XCTAssertEqual(store.endReason(info.captureID),.pageGone)
        XCTAssertFalse(accepted.inputGate?.permits ?? true)
    }
    func testStopDuringStartupCannotBeReopenedByFreshEvidence() throws {
        let clock = VerifiedClock(), id = UUID(); var state = try initial(clock,id:id)
        try send(["type":"meetings","meetings":[meeting()]],&state,id); try send(signal(0),&state,id)
        let request = try XCTUnwrap(state.automaticStarts(microphone:true).first)
        let store = BrowserAutomaticAdmissionStore(clock:{ clock.now() })
        try store.issue(request,browser:nil,generation:"call-A",document:"hook-A",microphone:true,deadline:5)
        let info = try store.authorize(.init(captureID:"stopped-pending",timelineOriginMs:0,microphone:true,callGeneration:"call-A",documentGeneration:"hook-A"),browser:nil)
        store.cancel(info.captureID,reason:.user)
        try send(signal(1),&state,id)
        store.update(pending:state.pendingAutomaticBindings,owned:state.currentAutomaticEvidence,ended:[])
        XCTAssertThrowsError(try info.inputGate?.acceptOwner())
        XCTAssertEqual(store.endReason(info.captureID),.user)
    }
    func testExplicitOldCompanionInputDoesNotNeedAutomaticLease() throws {
        let id = UUID(), clock = VerifiedClock(), store = BrowserAutomaticAdmissionStore(clock:{ clock.now() })
        var state = try initial(clock,id:id,ack:["call-signals-v1"])
        try send(["type":"meetings","meetings":[meeting()]],&state,id)
        XCTAssertTrue(state.automaticStarts(microphone:true).isEmpty)
        let request = try state.start(.init(peer:id,tabID:2),microphone:false)
        try store.issue(request,browser:nil,generation:"call-A",document:"hook-A",microphone:false,deadline:nil)
        store.cancelAllPending(automaticOnly:true)
        let accepted = try store.authorize(.init(captureID:"generated-manual",timelineOriginMs:0,microphone:false,callGeneration:"call-A",documentGeneration:"hook-A"),browser:nil)
        XCTAssertNil(accepted.inputGate); XCTAssertNil(accepted.automaticCall)
        XCTAssertThrowsError(try store.authorize(.init(captureID:"unsolicited",timelineOriginMs:0,microphone:true,callGeneration:"call-A",documentGeneration:"hook-A"),browser:nil))
    }
    func testDelayedNativeStartAtExactExpiryCannotReachRecordingFactory() throws {
        let clock = VerifiedClock(), store = BrowserAutomaticAdmissionStore(clock:{ clock.now() })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniVerifiedInput-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let applied = expectation(description:"verified active frame reconciled")
        let cancelled = expectation(description:"expired admission classified as cancellation")
        let broker = BrowserAudioBroker(make:{ _,_ in XCTFail("Expired input must not reserve a recording"); throw BrowserIPCError.unavailable },
            created:{ _,_ in XCTFail("No capture may attach") },stopNative:{ _,reply in reply(nil) },admission:store)
        let service = BrowserControlService(changed:{ _ in },completed:{ outcome,automatic in
            if outcome.admissionWithdrawn { XCTAssertTrue(automatic); cancelled.fulfill() }
        },audio:broker,clock:{ UInt64(clock.now()*1000) },
            received:{ if $0 == "callSignals" { applied.fulfill() } },requireMultiStream:true,requireVerifiedAdmission:true,admission:store)
        try service.start(root:root); defer { service.stop() }
        service.setAutoRecord(true,microphone:true)
        let control = try PipeEndpoint(root:root,role:.control,browser:"Chromium"); defer { control.stop() }
        let packets: [[String:Any]] = [
            ["type":"hello","version":1,"capabilities":pair+["independent-sessions-v1","multi-stream-v1","call-evidence-v1","page-state-v1","heartbeat-v1"]],
            ["type":"configured","capabilities":pair],
            ["type":"meetings","meetings":[meeting()]],
            ["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"sessions":[],"message":"Generated ready"],signal(0)]
        for packet in packets { try control.send(JSONSerialization.data(withJSONObject:packet)) }
        wait(for:[applied],timeout:5)
        var issued: JSON?
        for _ in 0..<4 {
            let value = try JSONParser.parse(XCTUnwrap(control.receive(deadline:DispatchTime.now().uptimeNanoseconds+5_000_000_000)))
            if value["action"]?.string == "start" { issued = value; break }
        }
        XCTAssertEqual(try XCTUnwrap(issued)["callGeneration"]?.string,"call-A")
        // No tick/reconcile: the final native reservation must check monotonic
        // expiry itself, even while the control thread has not processed a timer.
        clock.set(5)
        let audio = try PipeEndpoint(root:root,role:.audio,browser:"Chromium"); defer { audio.stop() }
        let late: [String:Any] = ["type":"start","version":1,"independent":true,"captureId":"generated-expired",
            "timelineOriginMs":0,"microphone":true,"callGeneration":"call-A","documentGeneration":"hook-A"]
        try audio.send(JSONSerialization.data(withJSONObject:late))
        let refusal = try JSONParser.parse(XCTUnwrap(audio.receive(deadline:DispatchTime.now().uptimeNanoseconds+5_000_000_000)))
        XCTAssertEqual(refusal["type"]?.string,"error")
        XCTAssertTrue(broker.activeCaptures.isEmpty)
        let requestID = try XCTUnwrap(issued?["requestId"]?.string)
        try control.send(JSONSerialization.data(withJSONObject:["type":"result","requestId":requestID,"ok":false,"error":"Generated expired admission",
            "status":["recording":false,"tabId":NSNull(),"path":NSNull(),"sessions":[],"message":"Generated cancelled startup"]]))
        wait(for:[cancelled],timeout:5)
        try control.send(JSONSerialization.data(withJSONObject:signal(1)))
        let retry = try JSONParser.parse(XCTUnwrap(control.receive(deadline:DispatchTime.now().uptimeNanoseconds+5_000_000_000)))
        XCTAssertEqual(retry["action"]?.string,"start"); XCTAssertNotEqual(retry["requestId"]?.string,requestID)
        XCTAssertTrue(broker.activeCaptures.isEmpty,"A cancellation must not suppress fresh same-call admission")
    }

    @MainActor func testMixedServiceChecksPendingBindingAndAcceptedGrace() throws {
        let clock = VerifiedClock(), root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniVerifiedMixed-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let first = expectation(description:"verified mixed native action"), second = expectation(description:"fresh bound replacement action")
        let actions = VerifiedActions(first,second)
        let service = BrowserControlService(changed:{ _ in },completed:{ _,_ in },clock:{ UInt64(clock.now()*1000) },
            requireMultiStream:true,requireVerifiedAdmission:true,signalAction:{ actions.record($0) })
        try service.start(root:root); defer { service.stop() }; service.setAutoRecord(true,microphone:true)
        let client = try PipeEndpoint(root:root,role:.control,browser:"Chromium"); defer { client.stop() }
        for packet: [String:Any] in [["type":"hello","version":1,"capabilities":pair+["independent-sessions-v1","multi-stream-v1"]],
            ["type":"configured","capabilities":pair],signal(0,remote:"mixed")] { try client.send(JSONSerialization.data(withJSONObject:packet)) }
        wait(for:[first],timeout:5)
        let old = try XCTUnwrap(actions.ids.first)
        XCTAssertTrue(service.signalMayOpen(old)); clock.set(5)
        XCTAssertFalse(try XCTUnwrap(service.signalInputGate(old)).permits)
        XCTAssertFalse(service.signalMayOpen(old),"Expired pending work cannot open input")
        service.signalReleased(old,failed:false)
        var replacement = row("mixed"); replacement["sourceDocumentGeneration"] = "hook-B"
        try client.send(JSONSerialization.data(withJSONObject:["type":"callSignals","browserInstance":"profile-A","sequence":1,"tabs":[replacement]]))
        wait(for:[second],timeout:5)
        let running = try XCTUnwrap(actions.ids.last), gate = try XCTUnwrap(service.signalInputGate(running))
        XCTAssertNotEqual(old,running)
        try gate.admit { /* inert input-open callback, no devices */ }
        service.signalStarted(running); clock.set(10)
        XCTAssertTrue(service.signalMayOpen(running),"Accepted owner enters its independent grace")
        clock.set(130); XCTAssertFalse(gate.permits)
        XCTAssertFalse(service.signalMayOpen(running))
    }
    func testFinalWriteGuardRejectsExpiryAfterScheduling() throws {
        let clock = VerifiedClock(), root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniVerifiedDispatch-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let applied = expectation(description:"active proof applied before opt-in"), dispatch = expectation(description:"final write guard reached")
        let trap = DispatchExpiry(clock,dispatch)
        let service = BrowserControlService(changed:{ _ in },completed:{ _,_ in },canStart:{ trap.check() },clock:{ UInt64(clock.now()*1000) },
            received:{ if $0 == "callSignals" { applied.fulfill() } },requireMultiStream:true,requireVerifiedAdmission:true)
        try service.start(root:root); defer { service.stop() }
        let client = try PipeEndpoint(root:root,role:.control,browser:"Chromium"); defer { client.stop() }
        let packets: [[String:Any]] = [
            ["type":"hello","version":1,"capabilities":pair+["independent-sessions-v1","multi-stream-v1","call-evidence-v1","page-state-v1","heartbeat-v1"]],
            ["type":"configured","capabilities":pair],["type":"meetings","meetings":[meeting()]],
            ["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"sessions":[],"message":"Generated ready"],signal(0)]
        for packet in packets { try client.send(JSONSerialization.data(withJSONObject:packet)) }
        wait(for:[applied],timeout:5)
        clock.set(4.999); service.setAutoRecord(true,microphone:true)
        wait(for:[dispatch],timeout:5); service.tickHeartbeats() // queue completion barrier at exactly 5 s
        clock.set(10); service.tickHeartbeats()
        for _ in 0..<8 {
            let value = try JSONParser.parse(XCTUnwrap(client.receive(deadline:DispatchTime.now().uptimeNanoseconds+5_000_000_000)))
            XCTAssertNotEqual(value["action"]?.string,"start","Expiry at final dispatch must prevent the actual packet")
            if value["type"]?.string == "ping" { return }
        }
        XCTFail("No ordered heartbeat barrier")
    }

    func testCreatedDirectoryDoesNotMakePendingInputAnAcceptedOwner() throws {
        let clock = VerifiedClock(), id = UUID(); var state = try initial(clock,id:id)
        try send(["type":"meetings","meetings":[meeting()]],&state,id); try send(signal(0),&state,id)
        let request = try XCTUnwrap(state.automaticStarts(microphone:true).first), store = BrowserAutomaticAdmissionStore(clock:{ clock.now() })
        try store.issue(request,browser:nil,generation:"call-A",document:"hook-A",microphone:true,deadline:5)
        let pending = try store.authorize(.init(captureID:"still-preparing",timelineOriginMs:0,microphone:true,callGeneration:"call-A",documentGeneration:"hook-A"),browser:nil)
        XCTAssertFalse(try XCTUnwrap(pending.inputGate).hasOpened)
        clock.set(5); store.update(pending:[:],owned:[:],ended:[])
        XCTAssertFalse(pending.inputGate?.permits ?? true)
        XCTAssertEqual(store.endReason("still-preparing"),.pageGone,"No evidence-loss grace before the first input is admitted")
    }

}
