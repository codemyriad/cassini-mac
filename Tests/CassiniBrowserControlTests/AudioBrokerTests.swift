// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import Darwin
import AVFoundation
import CassiniKit
import CassiniRecording
@testable import CassiniBrowserControl

private final class NativeFixtureInputs: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [UUID:RecordingSink] = [:]
    func started(_ capture: OwnedBrowserCapture, info: BrowserAudioStart) {
        guard info.microphone else { return }
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let sink = capture.nativeSink(side:.me,originHostTime:origin,failure:{ _ in })
        lock.withLock { sinks[capture.snapshot.manifest.id] = sink }
        let format = AVAudioFormat(standardFormatWithSampleRate:8000,channels:1)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:8000)!
        buffer.frameLength = 8000
        for index in 0..<8000 { buffer.floatChannelData![0][index] = 0.125 }
        sink.receive(buffer,hostTime:origin,id:"mic",label:"Generated microphone",kind:"microphone")
    }
    func stop(_ capture: OwnedBrowserCapture, reply: @escaping @Sendable (String?) -> Void) {
        let sink = lock.withLock { sinks.removeValue(forKey:capture.snapshot.manifest.id) }
        do { try sink?.finish(problem:nil); reply(nil) } catch { reply(error.localizedDescription) }
    }
}
private final class NativeAudioClient {
    let process = Process()
    let input = Pipe(), output = Pipe(), errors = Pipe()
    init(root: URL) throws {
        process.executableURL = Bundle(for:AudioBrokerTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("cassini-browser-host")
        process.environment = ["CASSINI_CONTROL_PIPE_ROOT":root.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        try FrameIO.prepare(input.fileHandleForWriting.fileDescriptor)
        try FrameIO.prepare(output.fileHandleForReading.fileDescriptor)
    }
    func request(_ message: [String:Any]) throws -> JSON {
        try FrameIO.writeFrame(input.fileHandleForWriting.fileDescriptor,data:JSONSerialization.data(withJSONObject:message),cancel:Cancellation())
        return try read()
    }
    func read() throws -> JSON {
        guard let data = try FrameIO.read(output.fileHandleForReading.fileDescriptor,cancel:Cancellation(),deadline:DispatchTime.now().uptimeNanoseconds + 5_000_000_000) else { throw BrowserIPCError.closed }
        return try JSONParser.parse(data)
    }
    func end() {
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval:0.01) }
        if process.isRunning { process.terminate(); process.waitUntilExit() }
    }
    deinit { end() }
}
private final class AudioFixture {
    let root: URL, ipc: URL, broker: BrowserAudioBroker, service: BrowserControlService
    var clients: [NativeAudioClient] = []
    init(stop: BrowserNativeStop? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniBrokerTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        ipc = root.appendingPathComponent("ipc")
        let library = root.appendingPathComponent("Library"), inputs = NativeFixtureInputs()
        broker = BrowserAudioBroker(make:{ title,mic in try OwnedBrowserCapture(parent:library,title:title,microphone:mic) },created:{ owner,info in inputs.started(owner,info:info) },stopNative:stop ?? { owner,reply in inputs.stop(owner,reply:reply) })
        service = BrowserControlService(changed:{ _ in },completed:{ _,_ in },audio:broker)
        try service.start(root:ipc)
    }
    func client() throws -> NativeAudioClient { let value = try NativeAudioClient(root:ipc); clients.append(value); return value }
    func finish() async {
        for client in clients { client.end() }
        await broker.finishAll(); service.stop()
        try? FileManager.default.removeItem(at:root)
    }
}
final class AudioBrokerTests: XCTestCase, @unchecked Sendable {
    func testConcurrentAppStopsAndQuitShareOneNativeDrain() async throws {
        let calls = StopCount()
        let fixture = try AudioFixture(stop:{ _,reply in
            calls.increment()
            DispatchQueue.global().asyncAfter(deadline:.now() + 0.05) { reply(nil); reply("Late duplicate reply") }
        })
        do {
            let client = try fixture.client(); _ = try client.request(start("stopping"))
            _ = try client.request(track()); _ = try client.request(audio())
            let owner = try XCTUnwrap(fixture.broker.activeCaptures.first)
            let broker = fixture.broker
            try await withThrowingTaskGroup(of:Void.self) { group in
                for _ in 0..<20 { group.addTask { try await broker.finish(owner) } }
                group.addTask { await broker.finishAll() }
                try await group.waitForAll()
            }
            try await fixture.broker.finish(owner)
            XCTAssertEqual(calls.value,1)
            XCTAssertEqual(owner.snapshot.phase,.saved)
            XCTAssertNil(owner.snapshot.manifest.problem)
            XCTAssertTrue(fixture.broker.activeCaptures.isEmpty)
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
    func start(_ id: String, mic: Bool = false) -> [String:Any] {
        ["type":"start","version":1,"independent":true,"captureId":id,"timelineOriginMs":Int(Date().timeIntervalSince1970*1000),"microphone":mic,"title":"Generated call"]
    }
    func track(_ id: String = "remote") -> [String:Any] { ["type":"track","id":id,"kind":"remote","label":"Remote","sampleRate":8000,"channels":1] }
    func audio(_ sequence: Int = 0, offset: Int = 0) -> [String:Any] { ["type":"audio","id":"remote","sequence":sequence,"offsetMs":offset,"pcm":Data(repeating:0x12,count:16000).base64EncodedString()] }
    func testRealNativeProcessesRecordIndependentFilesAndStopOnlyTheirOwnCapture() async throws {
        let fixture = try AudioFixture()
        do {
            let first = try fixture.client(), second = try fixture.client()
            let a = try first.request(start("one",mic:true)), b = try second.request(start("two"))
            XCTAssertEqual(a["type"]?.string,"started"); XCTAssertNotEqual(a["path"]?.string,b["path"]?.string)
            for client in [first,second] { XCTAssertEqual(try client.request(track())["type"]?.string,"ack"); XCTAssertEqual(try client.request(audio())["type"]?.string,"ack") }
            let deadline = Date().addingTimeInterval(3)
            while !fixture.broker.activeCaptures.contains(where:{ $0.snapshot.me && $0.snapshot.manifest.tracks.contains { $0.kind == "microphone" && $0.frames > 0 } }) && Date() < deadline { try await Task.sleep(nanoseconds:10_000_000) }
            XCTAssertEqual(try first.request(["type":"stop"])["type"]?.string,"stopped")
            XCTAssertEqual(try second.request(audio(1,offset:1000))["type"]?.string,"ack")
            XCTAssertEqual(try second.request(["type":"stop"])["type"]?.string,"stopped")
            let one = try RecordingLoader.load(directory:URL(fileURLWithPath:XCTUnwrap(a["path"]?.string)))
            let two = try RecordingLoader.load(directory:URL(fileURLWithPath:XCTUnwrap(b["path"]?.string)))
            XCTAssertEqual(one.tracks.count,2); XCTAssertEqual(one.tracks.filter { $0.kind == "microphone" }.count,1)
            XCTAssertEqual(two.tracks.count,1); XCTAssertEqual(two.tracks[0].frames,16000)
            XCTAssertEqual(one.state,"completed"); XCTAssertEqual(two.state,"completed")
            XCTAssertTrue(fixture.broker.activeCaptures.isEmpty)
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
    func testIndependentFramingFailuresReturnAnErrorFrameAndExitNonzero() async throws {
        let fixture = try AudioFixture()
        do {
            for (index,bad) in [Data([0,0,0,0]),Data("{\"type\":\"audio\",\"type\":\"stop\"}".utf8),Data([0xff])].enumerated() {
                let client = try fixture.client(); _ = try client.request(start("framing-" + String(index)))
                if index == 0 { try client.input.fileHandleForWriting.write(contentsOf:bad) }
                else { try FrameIO.writeFrame(client.input.fileHandleForWriting.fileDescriptor,data:bad,cancel:Cancellation()) }
                let response = try client.read()
                XCTAssertEqual(response["type"]?.string,"error"); XCTAssertEqual(response["code"]?.string,"framing")
                client.end(); XCTAssertNotEqual(client.process.terminationStatus,0)
            }
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
    func testInvalidIndependentStartMetadataNeverCreatesARecordingFolder() async throws {
        let fixture = try AudioFixture()
        do {
            for raw in ["{\"type\":\"start\",\"independent\":true,\"captureId\":\"bad\",\"timelineOriginMs\":1.0,\"microphone\":false}",
                        "{\"type\":\"start\",\"independent\":true,\"captureId\":\"\",\"timelineOriginMs\":1,\"microphone\":false}",
                        "{\"type\":\"start\",\"independent\":true,\"captureId\":\"bad\",\"timelineOriginMs\":1,\"microphone\":0}"] {
                let client = try fixture.client()
                try FrameIO.writeFrame(client.input.fileHandleForWriting.fileDescriptor,data:Data(raw.utf8),cancel:Cancellation())
                let response = try client.read()
                XCTAssertEqual(response["type"]?.string,"error"); XCTAssertEqual(response["code"]?.string,"source")
                client.end(); XCTAssertNotEqual(client.process.terminationStatus,0)
            }
            XCTAssertTrue(fixture.broker.activeCaptures.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent("Library").path))
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
    func testManagementDisconnectLeavesThePCMProcessRecording() async throws {
        let fixture = try AudioFixture()
        do {
            var control: PipeEndpoint? = try PipeEndpoint(root:fixture.ipc,role:.control,browser:"Chrome")
            try control?.send(Data("{\"type\":\"hello\",\"version\":1}".utf8))
            let client = try fixture.client(); let response = try client.request(start("capture"))
            XCTAssertEqual(try client.request(track())["type"]?.string,"ack")
            control = nil
            XCTAssertEqual(try client.request(audio())["type"]?.string,"ack")
            XCTAssertEqual(try client.request(["type":"stop"])["type"]?.string,"stopped")
            XCTAssertEqual(try RecordingLoader.load(directory:URL(fileURLWithPath:XCTUnwrap(response["path"]?.string))).tracks[0].frames,8000)
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
    func testMalformedSourceGetsAFramedErrorWithoutStoppingAnotherNativeProcess() async throws {
        let fixture = try AudioFixture()
        do {
            let bad = try fixture.client(), good = try fixture.client()
            _ = try bad.request(start("bad")); let response = try good.request(start("good"))
            _ = try bad.request(track()); _ = try good.request(track())
            let invalid = try bad.request(audio(2))
            XCTAssertEqual(invalid["type"]?.string,"error"); XCTAssertEqual(invalid["code"]?.string,"sequence")
            XCTAssertEqual(try good.request(audio())["type"]?.string,"ack")
            XCTAssertEqual(try good.request(["type":"stop"])["type"]?.string,"stopped")
            XCTAssertEqual(try RecordingLoader.load(directory:URL(fileURLWithPath:XCTUnwrap(response["path"]?.string))).state,"completed")
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
    func testLossKeepsTheOwnedFolderAndRejectsReuseOfItsOpaqueCaptureID() async throws {
        let fixture = try AudioFixture()
        do {
            let client = try fixture.client(); let response = try client.request(start("retained",mic:true))
            _ = try client.request(track()); _ = try client.request(audio())
            XCTAssertEqual(try client.request(["type":"stop","failureReason":"lost"])["type"]?.string,"stopped")
            client.end()
            let owner = try XCTUnwrap(fixture.broker.activeCaptures.first)
            XCTAssertEqual(owner.snapshot.directory.path,response["path"]?.string)
            XCTAssertEqual(owner.snapshot.phase,.recording)
            let duplicate = try fixture.client(); let error = try duplicate.request(start("retained"))
            XCTAssertEqual(error["type"]?.string,"error"); XCTAssertEqual(error["code"]?.string,"state")
            let system = owner.nativeWriter(side:.others)
            try system.addTrack(id:"output",label:"Generated system",kind:"system",sampleRate:8000,channels:1)
            let loss = try XCTUnwrap(owner.snapshot.manifest.events?.last?.atMs)
            try system.appendNative(id:"output",pcm:Data(repeating:0,count:16000),offsetMs:loss)
            try system.finish(problem:nil)
            XCTAssertEqual(owner.snapshot.manifest.events?.last?.source,"system")
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
}
private final class StopCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
