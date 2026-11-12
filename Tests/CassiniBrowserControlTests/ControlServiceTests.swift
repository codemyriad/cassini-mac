// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import Darwin
import CassiniKit
@testable import CassiniBrowserControl

private final class NotificationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
private final class Admission: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = false
    func set(_ value: Bool) { lock.withLock { allowed = value } }
    func read() -> Bool { lock.withLock { allowed } }
}
final class ControlServiceTests: XCTestCase {
    @MainActor func testRunningSignalGateAllowsInputStartsDuringGraceAndReturningCallAfterRollback() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let frames = SignalFrameWaiter(), actions = SignalEvents(), inspections = NotificationCount(), access = Admission()
        access.set(true)
        let service = BrowserControlService(changed:{ _ in },completed:{ _,_ in },
            canStart:{ inspections.increment(); return access.read() },received:{ frames.received($0) },
            signalAction:{ actions.append($0) },canSignalStart:{ inspections.increment(); return access.read() })
        try service.start(root:root); defer { service.stop() }
        service.setAutoRecord(true,microphone:false)
        let client = try signalClient(root:root)
        let active = expectation(description:"Mixed call reserved")
        frames.expect("callSignals",active); try send(signalSnapshot(0),client)
        await fulfillment(of:[active],timeout:3)
        let id = try XCTUnwrap(actions.startID), gate = try XCTUnwrap(service.signalInputGate(id))
        service.signalStarted(id)
        XCTAssertTrue(service.signalMayOpen(id)) // Fences the queued started notification.
        let lost = expectation(description:"Evidence loss starts running grace")
        frames.expect("callSignals",lost); try send(signalSnapshot(1,state:"unknown"),client)
        await fulfillment(of:[lost],timeout:3)
        XCTAssertNil(service.signalEndReason(id))
        var opened = 0
        for operation in ["re-enable Me","Retry","selection rollback"] {
            do { try gate.admit { opened += 1 } }
            catch {
                XCTFail("Running grace must allow \(operation): \(error)")
                // This is the real rollback-failure notification that previously
                // suppressed the generation when its input restart was refused.
                if operation == "selection rollback" { service.stopSignal(id,userInitiated:false,reason:.error) }
            }
        }
        XCTAssertEqual(opened,3)
        // Existing inputs use the owned recording and its disk watcher. A failed
        // new-root inspection or disabling auto-record cannot revoke that owner.
        access.set(false); service.setAutoRecord(false,microphone:false)
        XCTAssertTrue(service.signalMayOpen(id))
        let before = inspections.value
        XCTAssertTrue(service.signalMayOpen(id))
        let returned = expectation(description:"Same generation returns within grace")
        frames.expect("callSignals",returned); try send(signalSnapshot(2),client)
        await fulfillment(of:[returned],timeout:3)
        XCTAssertTrue(service.signalMayOpen(id)); XCTAssertNil(actions.stopReason)
        XCTAssertEqual(actions.startCount,1,"Returning evidence must retain the same recording")
        XCTAssertEqual(inspections.value,before,"Owned input restart must not inspect a new recording root")
        service.stopRecordings()
        XCTAssertFalse(service.signalMayOpen(id))
        XCTAssertThrowsError(try gate.admit { XCTFail("Stop must close the running input gate") })
        XCTAssertEqual(actions.stopReason,.user)
    }
    @MainActor func testSignalFilesystemChecksRequireANewEligibleReservationOrPendingInputOpen() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let frames = SignalFrameWaiter(), actions = SignalEvents(), diskChecks = NotificationCount(), access = Admission()
        access.set(true)
        let service = BrowserControlService(changed:{ _ in },completed:{ _,_ in },received:{ frames.received($0) },
            signalAction:{ actions.append($0) },canSignalStart:{ diskChecks.increment(); return access.read() })
        try service.start(root:root); defer { service.stop() }
        service.setAutoRecord(true,microphone:false)
        let client = try signalClient(root:root)
        func pongs(_ prefix: String) async throws {
            let replies = (0..<4).map { expectation(description:"\(prefix) frame \($0)") }
            for (index,reply) in replies.enumerated() {
                frames.expect("pong",reply); try send(["type":"pong","seq":index],client)
            }
            await fulfillment(of:replies,timeout:3)
        }
        try await pongs("No mixed call")
        XCTAssertEqual(diskChecks.value,0,"Ordinary frames without signal eligibility must not inspect the filesystem")
        let active = expectation(description:"One eligible call reserves")
        frames.expect("callSignals",active); try send(signalSnapshot(0),client)
        await fulfillment(of:[active],timeout:3)
        let id = try XCTUnwrap(actions.startID), gate = try XCTUnwrap(service.signalInputGate(id))
        XCTAssertEqual(diskChecks.value,1,"New admission must inspect once, after finding a real candidate")
        try await pongs("Pending permission")
        XCTAssertEqual(diskChecks.value,1,"Frames and reconciliation must not repeat pending admission inspection")
        XCTAssertTrue(service.signalMayOpen(id)); XCTAssertEqual(diskChecks.value,2)
        access.set(false)
        XCTAssertFalse(service.signalMayOpen(id),"Pending input opening must still revalidate filesystem access")
        XCTAssertEqual(diskChecks.value,3)
        let withdrawn = expectation(description:"Pending call loses evidence")
        frames.expect("callSignals",withdrawn); try send(signalSnapshot(1,state:"unknown"),client)
        await fulfillment(of:[withdrawn],timeout:3)
        XCTAssertFalse(service.signalMayOpen(id)); XCTAssertEqual(diskChecks.value,3)
        XCTAssertThrowsError(try gate.admit { XCTFail("Pending work gets no running grace") })
        XCTAssertEqual(actions.stopReason,.pageGone)
    }
    private func signalClient(root: URL) throws -> PipeEndpoint {
        let client = try PipeEndpoint(root:root,role:.control,browser:"Chrome")
        try send(["type":"hello","version":1,"capabilities":["call-signals-v1"]],client)
        XCTAssertEqual(try receive(client)["type"]?.string,"configure")
        try send(["type":"configured","capabilities":["call-signals-v1"]],client)
        return client
    }
    private func signalSnapshot(_ sequence: Int, state: String = "active") -> [String:Any] {
        ["type":"callSignals","browserInstance":"profile-A","sequence":sequence,"tabs":[[
            "tabId":2,"url":"https://call.example/","documentGeneration":"doc-A","remoteAudio":"mixed",
            "callEvidence":["state":state,"reason":state == "active" ? "activeCall" : "unverified",
                            "adapter":["name":"Synthetic call","version":"1"],"callGeneration":"call-A"]]]]
    }

    func testNegotiatedSignalsOwnNativeReservationWithoutBrowserStartAndStopFencesReconnect() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let started = expectation(description:"Native reservation"), ended = expectation(description:"Last positive end")
        let observed = expectation(description:"Signal snapshot committed"), events = SignalEvents()
        observed.assertForOverFulfill = false
        let service = BrowserControlService(changed:{ _ in },completed:{ _,_ in XCTFail("Signals must not fabricate browser command outcomes") },
            received:{ type in if type == "callSignals" { observed.fulfill() } },signalAction:{ action in
                events.append(action)
                switch action { case .start: started.fulfill(); case .stop: ended.fulfill() }
            })
        try service.start(root:root); defer { service.stop() }
        service.setAutoRecord(true,microphone:false)
        let client = try PipeEndpoint(root:root,role:.control,browser:"Chrome")
        try send(["type":"hello","version":1,"capabilities":["call-signals-v1","multi-stream-v1"]],client)
        let configure = try receive(client)
        XCTAssertEqual(configure["type"]?.string,"configure")
        XCTAssertEqual(configure["capabilities"]?.array,[.string("call-signals-v1")])
        try send(["type":"configured","capabilities":["call-signals-v1"]],client)
        func snapshot(_ seq: Int, _ state: String) -> [String:Any] {
            ["type":"callSignals","browserInstance":"stable-profile","sequence":seq,"tabs":[[
                "tabId":2,"url":"https://call.example/","documentGeneration":"document-A","remoteAudio":"mixed",
                "callEvidence":["state":state,"reason":state == "active" ? "activeCall" : "callEnded",
                                "adapter":["name":"Synthetic call","version":"1"],"callGeneration":"call-A"]]]]
        }
        try send(snapshot(0,"active"),client); wait(for:[started,observed],timeout:3)
        let id = try XCTUnwrap(events.startID)
        XCTAssertTrue(service.signalMayOpen(id)); service.signalStarted(id)
        try send(snapshot(1,"inactive"),client); wait(for:[ended],timeout:3)
        XCTAssertFalse(service.signalMayOpen(id)); XCTAssertEqual(events.stopReason,.callEnded)
        service.signalReleased(id)
        // A pipe round trip fences all queued app work. The only outbound frame is
        // configure above: no browser Start/Stop is involved in this recording.
        try send(["type":"hello","version":1],client) // duplicate hello closes this peer
        XCTAssertNil(try client.receive(deadline:DispatchTime.now().uptimeNanoseconds + 3_000_000_000))
    }
    func testStopAllSuppressesSnapshotBeforeCanStartAdmissionThroughRealPipe() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let snapshot = expectation(description:"Snapshot committed before admission")
        let barrier = expectation(description:"Next frame processed after Stop and admission change")
        let admission = Admission(), actions = SignalEvents()
        let service = BrowserControlService(changed:{ _ in },completed:{ _,_ in },canStart:{ admission.read() },received:{ type in
            if type == "callSignals" { snapshot.fulfill() }
            if type == "pong" { barrier.fulfill() }
        },signalAction:{ actions.append($0) })
        try service.start(root:root); defer { service.stop() }
        service.setAutoRecord(true,microphone:false)
        let client = try PipeEndpoint(root:root,role:.control,browser:"Chrome")
        try send(["type":"hello","version":1,"capabilities":["call-signals-v1"]],client)
        XCTAssertEqual(try receive(client)["type"]?.string,"configure")
        try send(["type":"configured","capabilities":["call-signals-v1"]],client)
        try send(["type":"callSignals","browserInstance":"profile-A","sequence":0,"tabs":[[
            "tabId":2,"url":"https://call.example/","documentGeneration":"doc-A","remoteAudio":"mixed",
            "callEvidence":["state":"active","reason":"activeCall","adapter":["name":"Synthetic call","version":"1"],"callGeneration":"call-A"]]]],client)
        wait(for:[snapshot],timeout:3); XCTAssertNil(actions.startID)
        service.stopRecordings(); admission.set(true); service.setAutoRecord(true,microphone:false)
        try send(["type":"pong","seq":0],client); wait(for:[barrier],timeout:3)
        XCTAssertNil(actions.startID,"Stop covers active snapshot facts even when no recording was reserved")
    }
    func testReloadRunsThroughTheRealControlPipeAndFreshHealthCompletesIt() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let reload = expectation(description:"Extension reports a reloadable tab")
        let ready = expectation(description:"Extension reports healthy after reload")
        let completed = expectation(description:"Correlated reload acknowledgement")
        reload.assertForOverFulfill = false; ready.assertForOverFulfill = false
        let keys = ReloadKey()
        let service = BrowserControlService(changed:{ peers in
            if let tab = peers.first?.browserHealth?.reloadTabs.first { keys.set(tab.key); reload.fulfill() }
            if peers.first?.browserHealth?.state == .ready { ready.fulfill() }
        },completed:{ outcome,automatic in
            XCTAssertEqual(outcome.action,.reloadTab); XCTAssertTrue(outcome.ok); XCTAssertFalse(automatic)
            completed.fulfill()
        })
        try service.start(root:root); defer { service.stop() }
        let client = try PipeEndpoint(root:root,role:.control,browser:"Chrome")
        try send(["type":"hello","version":1,"capabilities":["independent-sessions-v1","multi-stream-v1","tab-readiness-v1"],"filesOk":true,"extensionVersion":"0.2.20"],client)
        var needsReload = status(false)
        needsReload["browserHealth"] = ["state":"reloadRequired","worker":"ready","nativeControl":"connected","tabs":[["tabId":2,"state":"reloadRequired","action":"reloadMeetingTab"]]]
        try send(needsReload,client); wait(for:[reload],timeout:3)
        service.reloadMeetingTab(try XCTUnwrap(keys.get()))
        let request = try receive(client)
        XCTAssertEqual(request["action"]?.string,"reloadTab"); XCTAssertEqual(request["tabId"]?.int,2)
        XCTAssertNil(request["microphone"]); XCTAssertNil(request["captureLocal"])
        var healthy = status(false); healthy["browserHealth"] = ["state":"ready","tabs":[["tabId":2,"state":"ready"]]]
        try send(["type":"result","requestId":try XCTUnwrap(request["requestId"]?.string),"ok":true,"status":healthy],client)
        wait(for:[completed,ready],timeout:3)
    }
    func testFreshStopWithAStaleUIKeyUsesTheCurrentCaptureConnection() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let clock = IPCBarrierClock(), frames = SignalFrameWaiter()
        let oldReady = expectation(description:"Old capture status"), newReady = expectation(description:"Replacement capture status")
        oldReady.assertForOverFulfill = false; newReady.assertForOverFulfill = false
        let instance = try XCTUnwrap(BrowserInstance.process(getpid()))
        // Observe the first peer UUID from its actual published local metadata.
        let service = BrowserControlService(changed:{ peers in
            guard let peer = peers.first, peer.captures.first?.captureID == "capture" else { return }
            if peer.captures.first?.path == "/replacement-status" { newReady.fulfill() }
            else { oldReady.fulfill() }
        },completed:{ _,_ in },clock:clock.now,received:{ frames.received($0) })
        try service.start(root:root); defer { service.stop() }
        let first = try PipeEndpoint(root:root,role:.control,browser:"Chrome",browserInstance:instance)
        let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("clients"),includingPropertiesForKeys:nil).first { UUID(uuidString:$0.lastPathComponent) != nil })
        let oldKey = BrowserMeetingKey(peer:try XCTUnwrap(UUID(uuidString:folder.lastPathComponent)),tabID:2)
        try hello(first,heartbeat:true); try send(status(true),first)
        wait(for:[oldReady],timeout:3)
        let second = try PipeEndpoint(root:root,role:.control,browser:"Chrome",browserInstance:instance)
        try hello(second)
        var replacement = status(true)
        var sessions = replacement["sessions"] as! [[String:Any]]
        sessions[0]["path"] = "/replacement-status"; replacement["sessions"] = sessions
        try send(replacement,second)
        wait(for:[newReady],timeout:3)
        service.stopMeeting(oldKey,captureID:"capture")
        XCTAssertEqual(try receive(second)["action"]?.string,"stop")
        try assertNoCommandBeforeHeartbeat(service,first,clock:clock,frames:frames)
    }
    func testDisconnectedCaptureStopSurvivesARealPipeReconnectAndNewURLCanStart() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let clock = IPCBarrierClock(), frames = SignalFrameWaiter()
        let bound = expectation(description:"First status binds before audio registration")
        let gone = expectation(description:"Control connection gone")
        bound.assertForOverFulfill = false; gone.assertForOverFulfill = false
        let service = BrowserControlService(changed:{ peers in
            if peers.contains(where:{ $0.captures.first?.captureID == "capture" }) { bound.fulfill() }
            if peers.isEmpty { gone.fulfill() }
        },completed:{ _,_ in },clock:clock.now,received:{ frames.received($0) })
        try service.start(root:root); defer { service.stop() }
        let instance = try XCTUnwrap(BrowserInstance.process(getpid()))
        var first: PipeEndpoint? = try PipeEndpoint(root:root,role:.control,browser:"Chrome",browserInstance:instance)
        try hello(try XCTUnwrap(first)); try send(status(true),try XCTUnwrap(first))
        wait(for:[bound],timeout:3)
        first = nil
        wait(for:[gone],timeout:3)
        service.rememberUserStop(captureID:"capture",key:nil)
        service.setAutoRecord(true,microphone:false)
        let second = try PipeEndpoint(root:root,role:.control,browser:"Chrome",browserInstance:instance)
        try hello(second,heartbeat:true); try send(status(false),second)
        try assertNoCommandBeforeHeartbeat(service,second,clock:clock,frames:frames)
        try send(["type":"meetings","meetings":[["tabId":2,"title":"New call","url":"https://meet.example/new","sourceCount":2]]],second)
        XCTAssertEqual(try receive(second)["action"]?.string,"start")
    }
    func testRegisteredAudioThenDisconnectedStopAllBeforeAnyCaptureStatusCannotRestart() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let clock = IPCBarrierClock(), frames = SignalFrameWaiter()
        let closing = Admission(), gone = expectation(description:"Control really disconnected")
        gone.assertForOverFulfill = false
        let broker = BrowserAudioBroker(make:{ title,mic,captureLocal in
            try OwnedBrowserCapture(parent:root.appendingPathComponent("records"),title:title,microphone:mic,captureLocal:captureLocal)
        },created:{ _,_ in },stopNative:{ _,reply in reply(nil) })
        let service = BrowserControlService(changed:{ peers in
            if closing.read(), peers.isEmpty { gone.fulfill() }
        },completed:{ _,_ in },audio:broker,clock:clock.now,received:{ frames.received($0) })
        try service.start(root:root); defer { service.stop() }
        service.setAutoRecord(true,microphone:false)
        let instance = try XCTUnwrap(BrowserInstance.process(getpid()))
        var control: PipeEndpoint? = try PipeEndpoint(root:root,role:.control,browser:"Chrome",browserInstance:instance)
        try hello(try XCTUnwrap(control)); try send(status(false),try XCTUnwrap(control))
        XCTAssertEqual(try receive(try XCTUnwrap(control))["action"]?.string,"start")
        let audio = try PipeEndpoint(root:root,role:.audio,browser:"Chrome",browserInstance:instance)
        try send(["type":"start","version":1,"independent":true,"captureId":"capture-2",
                  "timelineOriginMs":Int(Date().timeIntervalSince1970*1000),"microphone":false,"title":"Call"],audio)
        XCTAssertEqual(try receive(audio)["type"]?.string,"started")
        XCTAssertEqual(broker.retainedCaptureIDs,["capture-2"])
        closing.set(true); control = nil; wait(for:[gone],timeout:3)
        service.stopRecordings()
        let next = try PipeEndpoint(root:root,role:.control,browser:"Chrome",browserInstance:instance)
        try hello(next,heartbeat:true); try send(status(false),next)
        try assertNoCommandBeforeHeartbeat(service,next,clock:clock,frames:frames)
        // This test opens only private files/FIFOs; no PCM or device is used.
        try send(["type":"stop"],audio); XCTAssertEqual(try receive(audio)["type"]?.string,"stopped")
    }
    func testBlockedDestinationIssuesNoManualOrAutomaticStartAndCanRecover() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let admission = Admission(), frames = SignalFrameWaiter()
        let ready = expectation(description:"Blocked inventory reconciled")
        frames.expect("status",ready)
        let service = BrowserControlService(changed:{ _ in },completed:{ _,_ in },canStart:{ admission.read() },received:{ frames.received($0) })
        try service.start(root:root); defer { service.stop() }
        service.setAutoRecord(true,microphone:true)
        let client = try PipeEndpoint(root:root,role:.control,browser:"Chrome")
        try hello(client); try send(status(false),client)
        wait(for:[ready],timeout:2)
        let issued = expectation(description:"Blocked manual start returns no requests")
        service.recordAll(microphone:true) { requests in XCTAssertTrue(requests.isEmpty); issued.fulfill() }
        wait(for:[issued],timeout:2)
        // Stop the automatic timer before reopening admission, so every recovery
        // Start uses the new microphone choice, even if a timer fires between calls.
        service.setAutoRecord(false,microphone:true); service.tickHeartbeats()
        admission.set(true)
        service.setAutoRecord(true,microphone:false)
        let recovery = try receive(client)
        XCTAssertEqual(recovery["type"]?.string,"command")
        XCTAssertEqual(recovery["action"]?.string,"start")
        XCTAssertEqual(recovery["tabId"]?.int,2)
        // One ordered writer carries every command. A wrongly issued blocked
        // Start (microphone=true) would arrive before this recovery barrier.
        XCTAssertEqual(recovery["microphone"]?.bool,false)
    }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniServiceTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        return url
    }
    func send(_ value: [String:Any], _ client: PipeEndpoint) throws { try client.send(JSONSerialization.data(withJSONObject:value)) }
    func hello(_ client: PipeEndpoint, heartbeat: Bool = false) throws {
        let capabilities = ["independent-sessions-v1"] + (heartbeat ? ["heartbeat-v1"] : [])
        try send(["type":"hello","version":1,"capabilities":capabilities],client)
        try send(["type":"meetings","meetings":[["tabId":2,"title":"Call","url":"https://meet.example/call","sourceCount":2]]],client)
    }
    func status(_ recording: Bool) -> [String:Any] {
        ["type":"status","recording":recording,"tabId":recording ? 2 : NSNull(),"path":NSNull(),"message":"Status",
         "sessions":recording ? [["tabId":2,"captureId":"capture","recording":true,"path":NSNull(),"message":"Recording"]] : []]
    }
    func receive(_ client: PipeEndpoint, seconds: Double = 3) throws -> JSON {
        guard let data = try client.receive(deadline:DispatchTime.now().uptimeNanoseconds + UInt64(seconds*1_000_000_000)) else { throw BrowserIPCError.closed }
        return try JSONParser.parse(data)
    }
    func testAutomaticStartIsNotAnnouncedUntilItsAcknowledgementAndStopDoesNotRestart() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let announced = expectation(description:"auto start acknowledged"), notifications = NotificationCount()
        let clock = IPCBarrierClock(), frames = SignalFrameWaiter()
        let service = BrowserControlService(changed:{ _ in },completed:{ result,automatic in
            if result.ok && result.action == .start && automatic { notifications.increment(); announced.fulfill() }
        },clock:{ clock.now() },received:{ frames.received($0) })
        try service.start(root:root); defer { service.stop() }
        service.setAutoRecord(true,microphone:false)
        let client = try PipeEndpoint(root:root,role:.control,browser:"Chrome")
        try hello(client,heartbeat:true); try send(status(false),client)
        let start = try receive(client)
        XCTAssertEqual(start["action"]?.string,"start"); XCTAssertEqual(start["captureLocal"]?.bool,false)
        XCTAssertEqual(start["microphone"]?.bool,false); XCTAssertEqual(notifications.value,0)
        try send(["type":"result","requestId":try XCTUnwrap(start["requestId"]?.string),"ok":true,"status":status(true)],client)
        wait(for:[announced],timeout:3)
        service.stopRecordings()
        let stop = try receive(client); XCTAssertEqual(stop["action"]?.string,"stop"); XCTAssertEqual(stop["tabId"]?.int,2)
        try send(["type":"result","requestId":try XCTUnwrap(stop["requestId"]?.string),"ok":true,"status":status(false)],client)
        let stopped = expectation(description:"Stopped status applied")
        frames.expect("status",stopped)
        try send(status(false),client)
        wait(for:[stopped],timeout:3)
        clock.advance(); service.tickHeartbeats()
        XCTAssertTrue(try framesThroughHeartbeat(client).isEmpty,"A stopped call must not restart")
        XCTAssertEqual(notifications.value,1)
    }
    func testProfilesWithSameTabStaySeparateAndWaitForTheirOwnFirstStatus() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let clock = IPCBarrierClock(), frames = SignalFrameWaiter()
        let service = BrowserControlService(changed:{ _ in },completed:{ _,_ in },clock:{ clock.now() },received:{ frames.received($0) })
        try service.start(root:root); defer { service.stop() }
        service.setAutoRecord(true,microphone:true)
        let existing = try PipeEndpoint(root:root,role:.control,browser:"Chrome")
        let bound = expectation(description:"Existing profile's first status applied")
        frames.expect("status",bound)
        try hello(existing,heartbeat:true); try send(status(true),existing)
        wait(for:[bound],timeout:3)
        let fresh = try PipeEndpoint(root:root,role:.control,browser:"Chrome")
        let inventory = expectation(description:"Fresh profile inventory applied without status")
        frames.expect("meetings",inventory)
        try hello(fresh,heartbeat:true)
        wait(for:[inventory],timeout:3)
        // Before its first status the fresh peer cannot heartbeat. Its first Start
        // is the output barrier: any premature Start carries the old mic choice.
        service.setAutoRecord(true,microphone:false)
        let reconciled = expectation(description:"Fresh profile's own first status applied")
        frames.expect("status",reconciled)
        try send(status(false),fresh)
        let start = try receive(fresh)
        XCTAssertEqual(start["action"]?.string,"start")
        XCTAssertEqual(start["tabId"]?.int,2)
        XCTAssertEqual(start["microphone"]?.bool,false,"Start must wait for this profile's own first status")
        wait(for:[reconciled],timeout:3)
        clock.advance(); service.tickHeartbeats()
        XCTAssertTrue(try framesThroughHeartbeat(fresh).isEmpty,"Only one fresh-profile Start")
        XCTAssertTrue(try framesThroughHeartbeat(existing).isEmpty,"The recording profile must stay separate")
    }
    /// Every frame before the ordered heartbeat is inspected. EOF and timeout throw;
    /// neither can prove that a command was absent.
    private func framesThroughHeartbeat(_ client: PipeEndpoint) throws -> [JSON] {
        var frames: [JSON] = []
        for _ in 0..<64 {
            let frame = try receive(client)
            if frame["type"]?.string == "ping" { return frames }
            frames.append(frame)
        }
        XCTFail("Missing heartbeat output barrier")
        throw BrowserIPCError.timeout
    }
    func testMalformedPeerDisconnectDoesNotDisableAHealthyProfile() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let service = BrowserControlService(changed:{ _ in },completed:{ _,_ in })
        try service.start(root:root); defer { service.stop() }
        let bad = try PipeEndpoint(root:root,role:.control,browser:"Chrome")
        let healthy = try PipeEndpoint(root:root,role:.control,browser:"Chrome")
        try hello(bad); try hello(healthy); try send(status(false),healthy)
        var malformed = status(false); malformed["sessions"] = false
        try send(malformed,bad)
        XCTAssertNil(try bad.receive(deadline:DispatchTime.now().uptimeNanoseconds + 3_000_000_000))
        service.recordAll(microphone:true)
        XCTAssertEqual(try receive(healthy)["action"]?.string,"start")
    }
}

private final class ReloadKey: @unchecked Sendable {
    private let lock = NSLock(); private var key: BrowserMeetingKey?
    func set(_ key: BrowserMeetingKey) { lock.withLock { self.key = key } }
    func get() -> BrowserMeetingKey? { lock.withLock { key } }
}

private final class SignalEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [BrowserSignalAction] = []
    func append(_ action: BrowserSignalAction) { lock.withLock { actions.append(action) } }
    var startID: UUID? { lock.withLock { for action in actions { if case .start(let id,_,let microphone) = action { XCTAssertFalse(microphone); return id } }; return nil } }
    var startCount: Int { lock.withLock { actions.filter { if case .start = $0 { return true }; return false }.count } }
    var stopReason: CaptureEndReason? { lock.withLock { for action in actions { if case .stop(_,let reason) = action { return reason } }; return nil } }
}

final class SignalFrameWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [String:[XCTestExpectation]] = [:]
    func expect(_ type: String, _ event: XCTestExpectation) { lock.withLock { waiting[type,default:[]].append(event) } }
    func received(_ type: String?) {
        guard let type else { return }
        let event: XCTestExpectation? = lock.withLock {
            guard var queue = waiting[type], !queue.isEmpty else { return nil }
            let first = queue.removeFirst(); waiting[type] = queue; return first
        }
        event?.fulfill()
    }
}

final class IPCBarrierClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1_000_000
    func now() -> UInt64 { lock.withLock { value } }
    func advance() { lock.withLock { value += ControlHeartbeat.interval } }
}


// The peer's next ping is sent by the same ordered writer as control commands.
// Receipt of the pong fences input reconciliation before virtual time advances.
extension XCTestCase {
    func assertNoCommandBeforeHeartbeat(_ service: BrowserControlService, _ client: PipeEndpoint,
                                        clock: IPCBarrierClock, frames: SignalFrameWaiter,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let reconciled = expectation(description:"Control input reconciled before the output barrier")
        frames.expect("pong",reconciled)
        try client.send(JSONSerialization.data(withJSONObject:["type":"pong","seq":0]))
        wait(for:[reconciled],timeout:3)
        clock.advance(); service.tickHeartbeats()
        guard let data = try client.receive(deadline:DispatchTime.now().uptimeNanoseconds + 3_000_000_000) else {
            throw BrowserIPCError.closed
        }
        let barrier = try JSONParser.parse(data)
        XCTAssertEqual(barrier["type"]?.string,"ping","A command preceded the output barrier",file:file,line:line)
        XCTAssertEqual(barrier["seq"]?.int,0,file:file,line:line)
    }
}
