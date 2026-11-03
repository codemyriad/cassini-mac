// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import AVFoundation
import CassiniKit
import CassiniRecording
@testable import CassiniBrowserControl

/// A native side whose open attempts follow a script: open (one buffer at its start time), a
/// refusal (OS denial at authorize, any other code at start), or silence (no buffer at all).
@MainActor private final class ScriptedInput: CaptureInput {
    enum Plan { case open(atMs: Double), refuse(code: String, message: String?), silent }
    let kind: String, origin: UInt64, plan: Plan
    var sink: RecordingSink?
    var failure: (@Sendable (String) -> Void)?
    init(_ kind: String, origin: UInt64, plan: Plan) { self.kind = kind; self.origin = origin; self.plan = plan }
    func authorize() async throws {
        if case .refuse(let code,_) = plan, code == CaptureRefusal.permissionDenied { throw CaptureOpenRefusal.denied }
    }
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws {
        if case .refuse(let code,let message) = plan { throw CaptureOpenRefusal(code:code,message:message) }
        self.sink = sink; self.failure = failure
        if case .open(let atMs) = plan {
            let format = AVAudioFormat(standardFormatWithSampleRate:8000,channels:1)!
            let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:800)!
            buffer.frameLength = 800
            for index in 0..<800 { buffer.floatChannelData![0][index] = 0.25 }
            sink.receive(buffer,hostTime:origin + AVAudioTime.hostTime(forSeconds:atMs/1000 + 0.05),id:kind,label:kind,kind:kind)
        }
    }
    func stop() { sink = nil }
}

@MainActor private final class Script {
    var plans: [CaptureSide:[ScriptedInput.Plan]] = [.me:[],.others:[]]
    var drivers: [CaptureSide:ScriptedInput] = [:]
    var refused: [CaptureRefusal] = []
    let origin: UInt64
    init(origin: UInt64) { self.origin = origin }
    func make(_ side: CaptureSide) -> any CaptureInput {
        let plan = plans[side]!.isEmpty ? .open(atMs:0) : plans[side]!.removeFirst()
        let driver = ScriptedInput(side == .me ? "microphone" : "system",origin:origin,plan:plan)
        drivers[side] = driver; return driver
    }
}

/// Opens the bound only when the test says so: the 3 s first-buffer wait is an event here.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock(); private var open = false; private var waiting: [CheckedContinuation<Void,Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { open ? true : { waiting.append(continuation); return false }() }
            if now { continuation.resume() }
        }
    }
    func release() { let all = lock.withLock { open = true; defer { waiting = [] }; return waiting }; all.forEach { $0.resume() } }
}

/// D58 (R79): the shared writer and wire cases (conformance/refusals/writer.json) on Mac's
/// noFallback profile, through the real owner, input lifecycle and session writer for native
/// sides, and through Start outcomes for the browser side.
final class D58RefusalWriterTests: XCTestCase, @unchecked Sendable {
    /// Cases where Mac knowingly differs, pending a coordinator decision (REPLIES-MAC):
    /// - a refused system side at start: Mac's native Record announces othersSource system only
    ///   at the first system PCM (D33), so the others stay none/start;
    /// - a rejected browser Start never attempts Me on Mac (the microphone opens with the
    ///   browser's audio host), so no Me refusal follows it.
    static let divergences: [String:String] = [
        "others-unavailable-me-keeps-recording":"othersFrom none (D33)",
        "start-rejected-and-mic-refused-without-fallback":"Me is not attempted after a rejected Start",
    ]
    private func vectors() throws -> JSON {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-protocol/conformance/refusals/writer.json")
        return try JSONParser.parse(Data(contentsOf:url))
    }
    private func object(_ refusal: CaptureRefusal) -> [String:String] {
        var value = ["atMs":String(refusal.atMs),"side":refusal.side,"code":refusal.code]
        value["detail"] = refusal.detail; value["message"] = refusal.message.map { String($0.unicodeScalars.count) + ":" + $0 }
        return value
    }
    private func object(_ json: JSON) -> [String:String] {
        var value = ["atMs":String(json["atMs"]?.double ?? -1),"side":json["side"]?.string ?? "","code":json["code"]?.string ?? ""]
        value["detail"] = json["detail"]?.string; value["message"] = json["message"]?.string.map { String($0.unicodeScalars.count) + ":" + $0 }
        return value
    }
    /// Waits for `condition` on the lifecycle's own change events (E1): first-buffer admission,
    /// failure completion and refusal delivery. The timeout is only a failure bound.
    @MainActor private func waitUntil(_ inputs: CaptureInputLifecycle, _ condition: @escaping @MainActor () -> Bool) async {
        if condition() { return }
        let met = expectation(description:"lifecycle condition")
        var done = false
        inputs.observer = { if !done, condition() { done = true; met.fulfill() } }
        await fulfillment(of:[met],timeout:5)
        inputs.observer = nil
    }

    func testWireCasesBecomeBrowserRefusals() throws {
        let wire = try XCTUnwrap(try vectors()["wire"]?.array)
        XCTAssertEqual(wire.count,9)
        for item in wire {
            let result = try XCTUnwrap(item["result"]), name = item["name"]?.string ?? ""
            // As the registry reads a result: a code is kept only as a whole-string token.
            let outcome = BrowserControlOutcome(requestID:"r",key:.init(peer:UUID(),tabID:2),action:.start,ok:false,error:result["error"]?.string,
                                                code:result["code"]?.string.flatMap { CaptureRefusal.isToken($0) ? $0 : nil })
            var expected = object(try XCTUnwrap(item["expected"])); expected["atMs"] = "0.0"
            XCTAssertEqual(outcome.startRefusal().map(object),expected,name)
        }
        // No answer and local refusals are startFailed with their detail (banner only).
        let lost = BrowserControlOutcome(requestID:"r",key:.init(peer:UUID(),tabID:2),action:.start,ok:false,error:nil,failure:"timeout")
        XCTAssertEqual(lost.startRefusal().map(object),["atMs":"0.0","side":"browser","code":"startFailed","detail":"timeout"])
        XCTAssertEqual(BrowserControlOutcome.localFailure(BrowserControlStateError.busy),"busy")
        XCTAssertEqual(BrowserControlOutcome.localFailure(BrowserControlStateError.notReconciled),"notReady")
    }

    @MainActor func testSharedWriterCasesOnTheNoFallbackProfile() async throws {
        let cases = try XCTUnwrap(try vectors()["cases"]?.array)
        XCTAssertEqual(cases.count,17)
        var replayed = 0
        for vector in cases where vector["profile"]?.string == nil || vector["profile"]?.string == "noFallback" {
            let name = try XCTUnwrap(vector["name"]?.string)
            let got = vector["request"]?["others"]?.string == "browser" ? browserStart(vector) : try await native(vector)
            replayed += 1
            let expected = try XCTUnwrap(vector["expected"]?.object)
            for (key,want) in expected {
                let have = got[key] ?? .null
                if let divergence = Self.divergences[name], (key == "othersFrom" && divergence.hasPrefix("othersFrom")) || (key == "banner" && divergence.hasPrefix("Me")) {
                    continue // asserted below
                }
                XCTAssertEqual(try have.encoded(maximumBytes:1_000_000),try normalized(want,key:key).encoded(maximumBytes:1_000_000),"\(name): \(key)")
            }
            if name == "others-unavailable-me-keeps-recording" { XCTAssertEqual(got["othersFrom"]?.string,"none",name) }
            if name == "start-rejected-and-mic-refused-without-fallback" {
                XCTAssertEqual(got["banner"]?["refusals"]?.array?.count,1,name)
            }
        }
        XCTAssertEqual(replayed,13)
    }
    /// Selection times are compared to the second the app applied them at (it adds its own latency).
    private func normalized(_ value: JSON, key: String) -> JSON {
        guard key == "selection", let list = value.array else { return value }
        return .array(list.map { event in
            .object([("atMs",.number(String(Int((event["atMs"]?.double ?? 0)/1000)))),("me",event["me"] ?? .null),
                     ("others",event["others"] ?? .null),("reason",event["reason"] ?? .null)])
        })
    }
    private func refusalList(_ list: [CaptureRefusal]) -> JSON {
        .array(list.map { refusal in
            var fields: [(String,JSON)] = [("atMs",.number(String(Int(refusal.atMs)))),("side",.string(refusal.side)),("code",.string(refusal.code))]
            if let detail = refusal.detail { fields.append(("detail",.string(detail))) }
            if let message = refusal.message { fields.append(("message",.string(message))) }
            return .object(fields)
        })
    }
    private func noFolder(_ refusals: [CaptureRefusal]) -> [String:JSON] {
        ["folder":.bool(false),"opened":.array([]),"selection":.null,"othersFrom":.null,"state":.null,"problemKind":.null,"refusals":.null,
         "banner":.object([("id",.string("errors.recordFailed.line")),("refusals",refusalList(refusals))])]
    }
    /// Mac noFallback: a refused browser Start opens nothing; the banner lists its refusal.
    private func browserStart(_ vector: JSON) -> [String:JSON] {
        var banner: [CaptureRefusal] = []
        for step in vector["steps"]?.array ?? [] where step["op"]?.string == "refuse" && step["side"]?.string == "browser" {
            let rejected = step["code"]?.string == CaptureRefusal.startRejected
            let outcome = BrowserControlOutcome(requestID:"r",key:.init(peer:UUID(),tabID:2),action:.start,ok:false,
                                                error:rejected ? step["message"]?.string : nil,code:rejected ? step["detail"]?.string : nil,
                                                failure:rejected ? nil : step["detail"]?.string ?? "timeout")
            if let refusal = outcome.startRefusal() { banner = CaptureRefusal.appending(refusal,to:banner) }
        }
        return noFolder(banner)
    }
    /// A native Record (Me and the system tap) through the owner, lifecycle and session writer.
    @MainActor private func native(_ vector: JSON) async throws -> [String:JSON] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniD58-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Refusals",microphone:true,browser:false)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let steps = vector["steps"]?.array ?? []
        // Plans per side: the start attempt, then one per turn-on, from the steps.
        let script = Script(origin:origin)
        var selected: [CaptureSide:Bool] = [.me:true,.others:true]
        func refusal(after index: Int, side: CaptureSide, atMs: Double) -> ScriptedInput.Plan? {
            for step in steps[(index+1)...] where step["op"]?.string == "refuse" && step["atMs"]?.double == atMs {
                if step["side"]?.string == (side == .me ? "me" : "others") {
                    return .refuse(code:step["code"]!.string!,message:step["message"]?.string)
                }
            }
            return nil
        }
        for side in [CaptureSide.me,.others] { script.plans[side]!.append(refusal(after:-1,side:side,atMs:0) ?? .open(atMs:0)) }
        for (index,step) in steps.enumerated() where step["op"]?.string == "select" {
            let at = step["atMs"]!.double!
            for side in [CaptureSide.me,.others] {
                guard let on = step[side == .me ? "me" : "others"]?.bool else { continue }
                if on && !selected[side]! {
                    let plan = refusal(after:index,side:side,atMs:at)
                    script.plans[side]!.append(plan ?? .open(atMs:at))
                    if plan == nil { selected[side] = true }
                } else if !on { selected[side] = false }
            }
        }
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ script.make(.me) },system:{ script.make(.others) },failure:{ _ in })
        try await inputs.start()
        // Every requested side refused: nothing records, no folder, and the banner lists them.
        if Set(inputs.refusedSides.keys) == [.me,.others] {
            let refusals = owner.snapshot.manifest.refusals ?? []
            try await inputs.stop(); try await owner.finish()
            return noFolder(refusals)
        }
        for side in script.drivers.keys where inputs.refusedSides[side] == nil { await waitUntil(inputs) { inputs.openedSides.contains(side) } }
        var stopAt = 0.0
        for step in steps {
            switch step["op"]?.string {
            case "select"?:
                let snapshot = owner.snapshot
                try await inputs.select(me:step["me"]?.bool ?? snapshot.me,others:step["others"]?.bool ?? snapshot.others,atMs:step["atMs"]!.double!)
            case "fail"?:
                let side: CaptureSide = step["side"]?.string == "me" ? .me : .others
                script.drivers[side]?.failure?("input failed")
                await waitUntil(inputs) { inputs.failedSides.contains(side) }
            case "stop"?: stopAt = step["atMs"]!.double!
            default: break
            }
        }
        try await inputs.stop()
        try await owner.finish(reason:.user,atMs:stopAt)
        let manifest = owner.snapshot.manifest
        let opened = [("me","microphone"),("others","system")].filter { side in manifest.tracks.contains { $0.kind == side.1 && $0.frames > 0 } }.map(\.0)
        let selections = (manifest.events ?? []).filter { $0.type == "selection" }
        let othersSelected = selections.last?.others ?? true
        let othersFrom = othersSelected ? (manifest.events ?? []).last(where:{ $0.type == "othersSource" })?.source : nil
        return ["folder":.bool(true),"opened":.array(opened.map { .string($0) }),
                "selection":.array(selections.map { event in
                    .object([("atMs",.number(String(Int((event.atMs ?? 0)/1000)))),("me",event.me.map { .bool($0) } ?? .null),
                             ("others",event.others.map { .bool($0) } ?? .null),("reason",event.reason.map { .string($0) } ?? .null)])
                }),
                "othersFrom":othersFrom.map { .string($0) } ?? .null,"state":.string(manifest.state),
                "problemKind":manifest.problemKind.map { .string($0) } ?? .null,
                "refusals":manifest.refusals.map(refusalList) ?? .null,"banner":.null]
    }

    /// #120 review: a start side whose driver starts, then fails before any PCM (an immediate
    /// audio configuration change) never opened: it is refused at 0 without a message and closed
    /// without a problem; the recording is not failed and the other side keeps recording.
    @MainActor func testAStartSideFailingBeforeItsFirstBufferIsRefusedNotFailed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniD58-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Failing",microphone:true,browser:false)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let gate = Gate(), script = Script(origin:origin)
        script.plans[.others] = [.silent]
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ script.make(.me) },system:{ script.make(.others) },
            failure:{ message in XCTFail("a refusal is not a failure: \(message)") },
            refused:{ _,refusal in script.refused.append(refusal) },openBound:{ await gate.wait() })
        try await inputs.start()
        await waitUntil(inputs) { inputs.openedSides.contains(.me) }
        script.drivers[.others]?.failure?("The audio configuration changed.")
        await waitUntil(inputs) { !script.refused.isEmpty }
        XCTAssertEqual(script.refused.map(\.side),["others"]); XCTAssertEqual(script.refused.first?.code,"deviceUnavailable")
        XCTAssertEqual(script.refused.first?.atMs,0); XCTAssertNil(script.refused.first?.message,"driver text can be localized copy")
        XCTAssertTrue(inputs.failedSides.contains(.others)); XCTAssertTrue(inputs.hasRunningInputs)
        gate.release()   // The bound passing later records nothing more.
        try await inputs.stop(); try await owner.finish(reason:.user,atMs:5000)
        let manifest = owner.snapshot.manifest
        XCTAssertEqual(manifest.state,"completed"); XCTAssertNil(manifest.problemKind)
        XCTAssertEqual(manifest.refusals?.map(\.code),["deviceUnavailable"])
        XCTAssertEqual(manifest.tracks.filter { $0.frames > 0 }.map(\.kind),["microphone"])
    }
    /// D58: a side that admits no buffer within the bound never opened: it is refused at 0 and
    /// closed without a problem, and the other side keeps recording.
    @MainActor func testASilentStartSideIsRefusedWhenTheBoundPasses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniD58-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Silent",microphone:true,browser:false)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let gate = Gate(), script = Script(origin:origin)
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,
            microphone:{ ScriptedInput("microphone",origin:origin,plan:.open(atMs:0)) },
            system:{ ScriptedInput("system",origin:origin,plan:.silent) },failure:{ _ in XCTFail("a refusal is not a failure") },
            refused:{ _,refusal in script.refused.append(refusal) },openBound:{ await gate.wait() })
        try await inputs.start()
        await waitUntil(inputs) { inputs.openedSides.contains(.me) }
        XCTAssertNil(inputs.refusedSides[.others])
        gate.release()
        await waitUntil(inputs) { !script.refused.isEmpty }
        XCTAssertEqual(script.refused.map(\.side),["others"]); XCTAssertEqual(script.refused.first?.code,"deviceUnavailable"); XCTAssertEqual(script.refused.first?.atMs,0)
        XCTAssertTrue(inputs.failedSides.contains(.others)); XCTAssertTrue(inputs.hasRunningInputs)
        try await inputs.stop(); try await owner.finish(reason:.user,atMs:5000)
        let manifest = owner.snapshot.manifest
        XCTAssertEqual(manifest.state,"completed"); XCTAssertNil(manifest.problemKind)
        XCTAssertEqual(manifest.tracks.map(\.kind),["microphone"])
        XCTAssertEqual(manifest.refusals?.map(\.code),["deviceUnavailable"])
        // The captureRecord copy is verbatim, also without captureOutcome.
        let record = try CaptureRecordWriter.record(manifest)
        XCTAssertEqual((record["refusals"] as? [[String:Any]])?.first?["side"] as? String,"others")
    }
}
