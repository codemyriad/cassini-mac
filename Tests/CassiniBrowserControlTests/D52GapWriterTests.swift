// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import AVFoundation
import CassiniKit
import CassiniRecording
@testable import CassiniBrowserControl

/// D52.2 (P7) shared writer vectors (conformance/gaps/writer.json) replayed through
/// the Mac's own writers: browser ops through OwnedBrowserCapture, native `input`
/// buffers through the production RecordingSink with their host stamps.
final class D52GapWriterTests: XCTestCase {
    private struct Native { let sink: RecordingSink; let id: String; let kind: String; let rate: Double }

    @MainActor func testSharedWriterVectors() async throws {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-protocol/conformance/gaps/writer.json")
        let cases = try XCTUnwrap(try JSONParser.parse(Data(contentsOf:url))["cases"]?.array)
        XCTAssertEqual(cases.count,16)
        for vector in cases { try await run(vector) }
    }

    @MainActor private func run(_ vector: JSON) async throws {
        let name = vector["name"]!.string!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D52Gaps-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let steps = vector["steps"]!.array!
        let browser = steps.contains { ["track","audio","series","trackEnd"].contains($0["op"]?.string ?? "") }
        let owner = try OwnedBrowserCapture(parent:root,title:name,microphone:true,browser:browser)
        if vector["features"]?.array?.contains(where:{ $0.string == "source-outcomes-v1" }) == true { owner.enableSourceOutcomes() }
        var me = vector["selection"]?["me"]?.bool ?? true, others = vector["selection"]?["others"]?.bool ?? true
        if !me || !others { try await owner.select(me:me,others:others,atMs:0) }
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        var sequences: [String:Int] = [:], rates: [String:Int] = [:], natives: [String:Native] = [:]
        func audio(_ id: String, _ offset: Double, _ frames: Int) throws {
            let sequence = sequences[id,default:0]; sequences[id] = sequence + 1
            try owner.browserAudio(id:id,sequence:sequence,offsetMs:offset,pcm:Data(repeating:0,count:frames*2))
        }
        for step in steps {
            switch step["op"]!.string! {
            case "track":
                let id = step["id"]!.string!, rate = step["rate"]?.int ?? 48000; rates[id] = rate
                try owner.browserTrack(id:id,label:id,kind:step["kind"]?.string ?? "remote",sampleRate:rate,channels:1,sourceTrackId:id)
            case "audio":
                try audio(step["id"]!.string!,step["offsetMs"]!.double!,step["frames"]!.int!)
            case "series":
                for index in 0..<step["count"]!.int! {
                    try audio(step["id"]!.string!,step["firstOffsetMs"]!.double! + Double(index)*step["everyMs"]!.double!,step["frames"]!.int!)
                }
            case "select":
                me = step["me"]?.bool ?? me; others = step["others"]?.bool ?? others
                try await owner.select(me:me,others:others,atMs:step["atMs"]!.double!)
            case "trackEnd":
                try owner.trackEnd(id:step["id"]!.string!,reason:"ended",droppedFrames:UInt64(step["droppedFrames"]!.int!))
            case "nativeTrack":
                let id = step["id"]!.string!, kind = step["kind"]!.string!
                let sink = owner.nativeSink(side:kind == "microphone" ? .me : .others,originHostTime:origin) { _ in }
                natives[id] = .init(sink:sink,id:id,kind:kind,rate:Double(step["rate"]?.int ?? 48000))
            case "input":
                let native = try XCTUnwrap(natives[step["id"]!.string!],name)
                let frames = AVAudioFrameCount(step["frames"]!.int!)
                let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:native.rate,channels:1))
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:frames)); buffer.frameLength = frames
                let host = origin + AVAudioTime.hostTime(forSeconds:step["hostMs"]!.double!/1000)
                native.sink.receive(buffer,hostTime:host,id:native.id,label:native.id,kind:native.kind)
            default: XCTFail("\(name): unknown op")
            }
        }
        for native in natives.values {
            // A native gap is reported by the sink's own diagnostic; the session keeps its facts.
            do { try native.sink.finish(problem:nil) } catch RecordingError.invalid {}
        }
        try await owner.finish()
        let manifest = try RecordingLoader.load(directory:owner.snapshot.directory)
        let expected = vector["expected"]!
        XCTAssertEqual(manifest.state,expected["state"]!.string!,name)
        XCTAssertEqual(manifest.problemKind,expected["problemKind"]?.string,name)
        // Inert zero-frame spans (declared while deselected) are left out of the comparison.
        let spans = manifest.tracks.filter { $0.frames > 0 }
        let wanted = expected["tracks"]!.array!
        XCTAssertEqual(spans.count,wanted.count,"\(name): spans")
        for (track,want) in zip(spans,wanted) {
            let label = "\(name) \(want["wire"]!.string!)"
            XCTAssertEqual(track.sourceTrackId ?? track.kind,want["wire"]!.string!,label)
            XCTAssertEqual(track.startOffsetMs ?? -1,want["startOffsetMs"]!.double!,accuracy:1e-6,label)
            XCTAssertEqual(track.frames,UInt64(want["frames"]!.int!),label)
            XCTAssertEqual(track.gapFrames ?? 0,UInt64(want["gapFrames"]!.int!),"\(label) gapFrames")
            XCTAssertEqual(track.droppedFrames ?? 0,UInt64(want["droppedFrames"]!.int!),"\(label) droppedFrames")
            let gaps = track.gaps ?? []
            func same(_ got: [GapRange], _ want: [JSON], _ what: String) {
                XCTAssertEqual(got.count,want.count,"\(label) \(what)")
                for (g,w) in zip(got,want) {
                    XCTAssertEqual(g.kind,w["kind"]!.string!,"\(label) \(what)")
                    XCTAssertEqual(g.atMs,w["atMs"]!.double!,accuracy:1e-6,"\(label) \(what) atMs")
                    if let d = w["durationMs"]?.double { XCTAssertEqual(g.durationMs ?? -1,d,accuracy:1e-6,"\(label) \(what) durationMs") } else { XCTAssertNil(g.durationMs,label) }
                    if let f = w["frames"]?.int { XCTAssertEqual(g.frames,UInt64(f),"\(label) \(what) frames") } else { XCTAssertNil(g.frames,label) }
                }
            }
            if let count = want["gapsCount"]?.int {
                XCTAssertEqual(gaps.count,count,label)
                let head = want["gapsHead"]!.array!, tail = want["gapsTail"]!.array!
                same(Array(gaps.prefix(head.count)),head,"head"); same(Array(gaps.suffix(tail.count)),tail,"tail")
            } else { same(gaps,want["gaps"]!.array!,"gaps") }
        }
    }
}
