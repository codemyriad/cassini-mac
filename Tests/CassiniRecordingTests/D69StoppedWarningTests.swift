// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniRecording

/// The standalone browser host must apply the same gap/writer presentation as owned calls.
struct D69StoppedWarningTests {
    private func stopped(jumpMs: Int, native: [(String,Int)], problem: String? = nil) throws -> String? {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D69LegacyStop-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let host = BrowserRecordingHost(parent:root)
        func send(_ message: [String:Any]) throws -> [String:String] {
            try host.receive(JSONSerialization.data(withJSONObject:message))
        }
        _ = try send(["type":"start","version":1,"title":"Synthetic call"])
        _ = try send(["type":"track","id":"r","kind":"remote","label":"Guest","sampleRate":8000,"channels":1])
        for (sequence,offset) in [0,1000+jumpMs].enumerated() {
            _ = try send(["type":"audio","id":"r","sequence":sequence,"offsetMs":offset,"pcm":Data(repeating:1,count:16000).base64EncodedString()])
        }
        let session = try #require(host.session)
        for (kind,gapMs) in native {
            try session.addTrack(id:kind,label:kind,kind:kind,sampleRate:8000,channels:1)
            try session.appendNative(id:kind,pcm:Data(repeating:1,count:16000),offsetMs:0)
            try session.padNative(id:kind,frames:8000,channels:1,rate:8000,offsetMs:1000,kind:"writer")
            try session.appendNative(id:kind,pcm:Data(repeating:1,count:16000),offsetMs:Double(2000+gapMs),gapKind:"input")
        }
        var stop: [String:Any] = ["type":"stop"]
        if let problem { stop["problem"] = problem }
        return try send(stop)["problem"]
    }
    @Test func browserJumpsKeepTheGenericWarningWithAndWithoutWriterLoss() throws {
        let expected = "Some audio is missing: the recording has a gap of at least one second."
        #expect(try stopped(jumpMs:1250,native:[]) == expected)
        #expect(try stopped(jumpMs:1250,native:[("microphone",0)]) == expected)
    }
    @Test func nativeGapDurationsExcludeBrowserJumpsAndOtherNativeSides() throws {
        let mic = "Recording saved with 1250 ms of host-time gap; the timeline contains silence."
        let system = "Recording saved with 2000 ms of host-time gap; the timeline contains silence."
        #expect(try stopped(jumpMs:50,native:[("microphone",1250)]) == mic)
        #expect(try stopped(jumpMs:50,native:[("microphone",1250),("system",2000)]) == mic+" "+system)
    }
    @Test func existingGapDiagnosticsAreKeptOnceAndWriterOnlyLossStaysQuiet() throws {
        let warning = "Recording saved with 1250 ms of host-time gap; the timeline contains silence."
        #expect(try stopped(jumpMs:50,native:[("microphone",1250)],problem:warning) == warning)
        #expect(try stopped(jumpMs:0,native:[("microphone",0)]) == nil)
    }
}
