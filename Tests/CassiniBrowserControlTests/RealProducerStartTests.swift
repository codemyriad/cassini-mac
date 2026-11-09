// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CassiniKit
@testable import CassiniBrowserControl

private final class ProducerBoundaryState: @unchecked Sendable {
    private let lock = NSLock()
    private var milliseconds: UInt64 = 1_000
    private var native = 0
    func now() -> UInt64 { lock.withLock { milliseconds } }
    func barrier() { lock.withLock { milliseconds += 10_000 } }
    func signal(_ action: BrowserSignalAction) {
        if case .start = action { lock.withLock { native += 1 } }
    }
    var nativeStarts: Int { lock.withLock { native } }
}

/// Recorded packets from the real 0.2.26 producer, never fabricated inventory.
/// Talk's exact reviewed tree matches the merged pin; negatives are collected
/// locally from that tree with fake devices and native recording forbidden.
final class RealProducerStartTests: XCTestCase {
    func testRealTalkSplitPCAndMediaNegativesAtActualStartBoundary() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource:"verified-producer-0.2.26",withExtension:"json",subdirectory:"Fixtures"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        XCTAssertEqual(fixture["extensionVersion"] as? String,"0.2.26")
        XCTAssertEqual(fixture["protocolCommit"] as? String,"b2b561bf1dbf51bbd990cb1c78a1d3e0a07c753f")
        let talk = try XCTUnwrap(fixture["talk"] as? [String:Any])
        let topology = try XCTUnwrap(talk["rtcTopology"] as? [String:Any])
        XCTAssertEqual(topology["samePeerConnection"] as? Bool,false)
        XCTAssertGreaterThan(try XCTUnwrap(topology["sendingPeers"] as? Int),0)
        XCTAssertGreaterThan(try XCTUnwrap(topology["receivingPeers"] as? Int),0)
        let cases = try XCTUnwrap(fixture["cases"] as? [[String:Any]])
        XCTAssertEqual(cases.count,9)
        XCTAssertEqual(Set(cases.compactMap { $0["name"] as? String }),[
            "real-talk-split-pc","passive-viewer","mic-preview","synthetic-sender","unanswered-ringing-no-capture",
            "cross-frame-capture","cross-frame-split","cross-document-split","forged-page-evidence"])
        for value in cases { try replay(value) }
    }

    private func replay(_ value: [String:Any]) throws {
        let name = try XCTUnwrap(value["name"] as? String)
        let expected = try XCTUnwrap(value["expectedStarts"] as? Int)
        let wire = try XCTUnwrap(value["wire"] as? [[String:Any]])
        XCTAssertFalse(wire.isEmpty,name)
        // Validate every packet first, with an index on parse failure. This is
        // also independent of transport timeouts and the Start-count oracle.
        let id = UUID(); var registry = BrowserControlRegistry()
        registry.requireMultiStream = true; registry.requireVerifiedAdmission = true
        try registry.connect(.init(id:id,role:.control,browser:"Chromium"))
        for (index,packet) in wire.enumerated() {
            do { try registry.receive(JSONSerialization.data(withJSONObject:packet),from:id) }
            catch { XCTFail("\(name) real producer packet \(index) rejected: \(error)"); throw error }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniRealProducer-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let state = ProducerBoundaryState(), applied = expectation(description:name+" packets applied")
        applied.expectedFulfillmentCount = wire.count
        let admission = BrowserAutomaticAdmissionStore(clock:{ Double(state.now())/1000 })
        let broker = BrowserAudioBroker(make:{ _,_ in XCTFail("No real recording/input may be created"); throw BrowserIPCError.unavailable },
            created:{ _,_ in XCTFail("No audio capture may attach") },stopNative:{ _,reply in reply(nil) },admission:admission)
        let service = BrowserControlService(changed:{ _ in },completed:{ _,_ in },audio:broker,canStart:{ true },clock:{ state.now() },
            received:{ _ in applied.fulfill() },requireMultiStream:true,requireVerifiedAdmission:true,admission:admission,signalAction:{ state.signal($0) })
        try service.start(root:root); defer { service.stop() }
        service.setAutoRecord(true,microphone:true)
        let client = try PipeEndpoint(root:root,role:.control,browser:"Chromium",browserInstance:BrowserInstance.process(getpid()))
        defer { client.stop() }
        for packet in wire { try client.send(JSONSerialization.data(withJSONObject:packet)) }
        wait(for:[applied],timeout:5)
        state.barrier(); service.tickHeartbeats()
        var starts: [JSON] = [], reachedBarrier = false
        for _ in 0..<64 {
            let packet = try JSONParser.parse(XCTUnwrap(client.receive(deadline:DispatchTime.now().uptimeNanoseconds+5_000_000_000)))
            if packet["type"]?.string == "ping" { reachedBarrier = true; break }
            if packet["action"]?.string == "start" { starts.append(packet) }
        }
        XCTAssertTrue(reachedBarrier,"Ordered output barrier: "+name)
        XCTAssertEqual(starts.count,expected,"Actual outbound automatic Start: "+name)
        XCTAssertEqual(state.nativeStarts,0,"No mixed/native Start for these separated/unknown traces: "+name)
        XCTAssertTrue(broker.activeCaptures.isEmpty,name)
        if expected == 1 {
            let signal = try XCTUnwrap(wire.last { $0["type"] as? String == "callSignals" })
            let row = try XCTUnwrap((signal["tabs"] as? [[String:Any]])?.first { ($0["callEvidence"] as? [String:Any])?["state"] as? String == "active" })
            let evidence = try XCTUnwrap(row["callEvidence"] as? [String:Any])
            XCTAssertEqual(starts.first?["tabId"]?.int,row["tabId"] as? Int)
            XCTAssertEqual(starts.first?["callGeneration"]?.string,evidence["callGeneration"] as? String)
            XCTAssertEqual(starts.first?["microphone"]?.bool,true)
            XCTAssertEqual(starts.first?["independent"]?.bool,true)
            XCTAssertEqual(starts.first?["keepOnNavigation"]?.bool,true)
            let facts = try XCTUnwrap(value["facts"] as? [String:Any])
            XCTAssertEqual(facts["acknowledged"] as? Bool,true)
            XCTAssertEqual(facts["splitPeerConnection"] as? Bool,true)
            let collector = try XCTUnwrap(facts["collector"] as? [String:Any])
            XCTAssertEqual(collector["samePeerCount"] as? Int,0)
            XCTAssertEqual(collector["cohortQualified"] as? Bool,true)
        } else {
            let facts = try XCTUnwrap(value["facts"] as? [String:Any])
            let legacy = try XCTUnwrap(facts["legacySourceObservation"] as? [String:Any])
            XCTAssertEqual(legacy["sourceCount"] as? Int,1,name)
            XCTAssertEqual(legacy["heard"] as? Bool,true,name)
        }
        print("D80 real producer \(name): automatic browser Starts=\(starts.count), native Starts=\(state.nativeStarts), captures=\(broker.activeCaptures.count)")
    }
}
