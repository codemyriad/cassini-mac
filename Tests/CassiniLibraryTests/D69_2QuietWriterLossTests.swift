// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
import CassiniRecording
@testable import CassiniLibrary

/// D69.2: the file stays as D69 says (writer ranges, droppedFrames, the stored sentence, io,
/// interrupted, end reason error). A recording whose only problem is writer loss is shown as a
/// normal recording: no Interrupted badge, no error end, no amber dropped-audio line; Recording
/// details adds one quiet line per source when its summed writer loss is at least 1 s.
struct D69_2QuietWriterLossTests {
    @Test(arguments:[UInt64(0),4000,8000])
    func browserOutcomesAlsoShowUnreferencedNativeWriterLoss(lost: UInt64) throws {
        let native: [[String:Any]] = [("m","microphone"),("s","system")].map { id,kind in
            ["id":id,"kind":kind,"sampleRate":8000,"frames":16000+lost,"receivedFrames":16000,"droppedFrames":lost,
             "gaps":[["kind":"writer","atMs":2000,"frames":lost]]] as [String:Any]
        }
        let remote: [String:Any] = ["id":"r","kind":"remote","sampleRate":8000,"frames":16000,"receivedFrames":16000]
        let source: [String:Any] = ["sourceTrackId":"guest","kind":"remote","label":"Guest","captureOutcome":"captured","audioMs":2000,"trackIds":["r"]]
        let file = try JSONParser.parse(JSONSerialization.data(withJSONObject:["source":"chromium","tracks":[remote]+native,"captureOutcome":["sources":[source]]]))
        let result = report(file)
        #expect(result.sources.map { $0.line.values["source"] } == [.text("Guest"),.catalog("common.yourMicrophone"),.catalog("recordFirst.sound.title")])
        #expect(result.sources.dropFirst().allSatisfy { !$0.problem && $0.gapLines.isEmpty })
        #expect(result.sources.compactMap(\.computerBusy).count == (lost >= 8000 ? 2 : 0))
        if lost >= 8000 {
            #expect(result.sources.dropFirst().allSatisfy { $0.computerBusy?.values["duration"] == .duration(1000) })
        }
        let record: JSON = .object([("version",.number("1")),("sources",.array([try #require(file["captureOutcome"]?["sources"]?.array?.first)])),("tracks",try #require(file["tracks"]))])
        let retained = RecordingDetailsReport(.init(lifecycle:.saved,title:"Call",session:nil,captureRecord:record))
        #expect(retained.sources == result.sources,"retained captureRecord has the same native rows")
    }
    @Test func browserWithoutOutcomesDoesNotInventAUserStop() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let native = try stored(try writerOnly(root,lost:48_000))
        #expect(native["captureOutcome"] == nil)
        #expect(report(native).ended.values["reason"] == .catalog("details.end.user"))
        let browser = try native.setting("source",to:.string("chromium"))
        #expect(report(browser).ended == .init("details.unknown"))
        #expect(!report(browser).endKnown)
    }
    private func malformedTracks(_ ranges: [String], dropped: String = "0") throws -> JSON {
        let gaps = ranges.map { "{\"kind\":\"writer\",\"frames\":\($0)}" }.joined(separator:",")
        return try JSONParser.parse(Data("[{\"id\":\"t\",\"kind\":\"microphone\",\"sampleRate\":48000,\"droppedFrames\":\(dropped),\"gaps\":[\(gaps)]}]".utf8))
    }
    @Test(arguments: [
        ["18446744073709551615","1"], ["18446744073709551616"],
        ["9007199254740992"], ["9007199254740991","1"],
        ["-1"], ["1.5"], ["1e3"], ["\"48000\""], ["null"], ["{}"]
    ])
    func invalidWriterCountsAreUnknownAndDetailsNeverTraps(counts: [String]) throws {
        let tracks = try malformedTracks(counts)
        #expect(RecordingDetailsReport.writerLoss(ids:["t"],tracks:tracks) == nil)
        let source = try JSONParser.parse(Data("{\"sourceTrackId\":\"mic\",\"kind\":\"microphone\",\"captureOutcome\":\"captured\",\"audioMs\":5000,\"trackIds\":[\"t\"]}".utf8))
        let file: JSON = .object([("tracks",tracks),("captureOutcome",.object([("sources",.array([source]))]))])
        #expect(report(file).sources.first?.computerBusy == nil,"invalid loss stays unknown in the complete Details reader")
    }
    @Test(arguments: ["18446744073709551615","18446744073709551616","9007199254740992","-1","1.5","1e3","\"48000\"","{}"])
    func invalidDroppedCountsAreUnknown(count: String) throws {
        #expect(RecordingDetailsReport.writerLoss(ids:["t"],tracks:try malformedTracks(["48000"],dropped:count)) == nil)
    }
    @Test func unsafeWriterSumsAcrossTracksAndRatesAreUnknown() throws {
        let sameRate = try JSONParser.parse(Data("""
        [{"id":"a","sampleRate":48000,"gaps":[{"kind":"writer","frames":9007199254740991}]},
         {"id":"b","sampleRate":48000,"gaps":[{"kind":"writer","frames":1}]}]
        """.utf8))
        #expect(RecordingDetailsReport.writerLoss(ids:["a","b"],tracks:sameRate) == nil)
        let tracks = (0..<10).map { index in
            "{\"id\":\"t\(index)\",\"sampleRate\":\(8000+index),\"gaps\":[{\"kind\":\"writer\",\"frames\":9007199254740991}]}"
        }.joined(separator:",")
        #expect(RecordingDetailsReport.writerLoss(ids:(0..<10).map { "t\($0)" },tracks:try JSONParser.parse(Data("[\(tracks)]".utf8))) == nil)
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("D69_2-"+UUID().uuidString) }
    private func session(_ root: URL, configure: (RecordingSession) throws -> Void) throws -> RecordingSession {
        let session = try RecordingSession(parent:root,title:"Busy",source:"macos")
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:48000,channels:1)
        try configure(session)
        return session
    }
    private func stored(_ session: RecordingSession) throws -> JSON {
        try JSONParser.parse(Data(contentsOf:session.directory.appendingPathComponent("session.json")))
    }
    private func badge(_ root: URL) throws -> Int64? { try #require(LibraryScanner(root:root).scan().meetings.first).state.interruptedAtMs }
    private func report(_ session: JSON) -> RecordingDetailsReport { .init(.init(lifecycle:.saved,title:"Busy",session:session)) }
    private let second = Data(repeating:1,count:96000)   // 1 s of 48 kHz mono 16-bit PCM

    /// 1 s received, then `lost` frames of writer padding, then 1 s more.
    private func writerOnly(_ root: URL, lost: UInt64) throws -> RecordingSession {
        try session(root) { session in
            try session.appendNative(id:"mic",pcm:second,offsetMs:0)
            try session.padNative(id:"mic",frames:lost,channels:1,rate:48000,offsetMs:1000)
            try session.appendNative(id:"mic",pcm:second,offsetMs:1000 + Double(lost) / 48)
            try session.finish()
        }
    }

    @Test(arguments:[(UInt64(47_975),false),(47_976,true),(48_000,true),(96_000,true)])
    func writerOnlyLossShowsNoBadgeAndAQuietLineFromOneSecond(lost: UInt64, shown: Bool) throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let session = try writerOnly(root,lost:lost)
        let file = try stored(session)
        // The file is D69's, unchanged.
        #expect(file["state"]?.string == "interrupted" && file["problemKind"]?.string == "io")
        #expect(file["events"]?.array?.last?["reason"]?.string == "error")
        #expect(file["problem"]?.string?.hasSuffix("ms of microphone audio was lost because the computer could not keep up; the gaps contain silence.") == true)
        #expect(WriterLoss.isWriterOnly(file))
        // What is shown is a normal recording.
        #expect(try badge(root) == nil,"no Interrupted badge")
        let details = report(file)
        let row = try #require(details.sources.first)
        #expect(!row.problem && row.gapLines.isEmpty,"no amber line, no dropped-audio line")
        #expect(details.ended.values["reason"] == .catalog("details.end.user"),"a native stop is the user's, never an error end")
        #expect(details.endKnown)
        let rendered = details.sources.flatMap(\.lines).map { $0.render(language:.en,locale:Locale(identifier:"en_GB")) }
        #expect(!rendered.contains { $0.contains("keep up") },"the stored sentence is never shown")
        if shown {
            let ms = Int64(WriterLoss.roundedMilliseconds([48000:lost]))
            #expect(row.computerBusy == .init("details.sources.computerBusy",["source":.catalog("common.yourMicrophone"),"duration":.duration(ms)]))
            #expect(row.lines.count == 2 && row.lines.last == row.computerBusy,"after the source's own line")
        } else {
            #expect(row.computerBusy == nil,"under 1 s it stays in the file and is not shown")
        }
    }
    @Test func theLineReadsAsTheCatalogSays() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let row = try #require(report(try stored(try writerOnly(root,lost:48_000))).sources.first)
        let text = try #require(row.computerBusy).render(language:.en,locale:Locale(identifier:"en_GB"))
        let source = LibraryLocalization.shared.text("common.yourMicrophone",language:.en)
        #expect(text == LibraryLocalization.shared.text("details.sources.computerBusy",["source":source,"duration":"1 s"],language:.en))
        #expect(text.hasSuffix(": about 1 s is missing because the computer was too busy. That part is silent."))
    }
    @Test func writerLossWithARealGapShowsTheGapAsToday() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let session = try session(root) { session in
            try session.appendNative(id:"mic",pcm:second,offsetMs:0)
            try session.padNative(id:"mic",frames:48_000,channels:1,rate:48000,offsetMs:1000)
            try session.appendNative(id:"mic",pcm:second,offsetMs:2000)
            try session.appendNative(id:"mic",pcm:second,offsetMs:4500,gapKind:"input")   // a 1.5 s input gap
            try session.finish()
        }
        let file = try stored(session)
        #expect(!WriterLoss.isWriterOnly(file))
        #expect(try badge(root) != nil,"the gap keeps the Interrupted badge")
        let details = report(file)
        let row = try #require(details.sources.first)
        #expect(row.gapLines.map(\.id) == ["details.sources.gap"] && row.gapLines.first?.values["duration"] == .duration(1500))
        #expect(row.computerBusy?.values["duration"] == .duration(1000))
        #expect(details.ended.values["reason"] == .catalog("details.end.error"),"the end is presented as today")
    }
    @Test func anyOtherProblemKeepsTheInterruptedPresentation() throws {
        let cases: [(String,(RecordingSession) throws -> Void)] = [
            ("another diagnostic",{ session in
                try session.appendNative(id:"mic",pcm:self.second,offsetMs:0)
                try session.padNative(id:"mic",frames:48_000,channels:1,rate:48000,offsetMs:1000)
                try session.finish(problem:"Disk said no.") }),
            ("a failed track",{ session in
                try session.appendNative(id:"mic",pcm:self.second,offsetMs:0)
                try session.padNative(id:"mic",frames:48_000,channels:1,rate:48000,offsetMs:1000)
                try session.failTrack(id:"mic",problemKind:"io"); try session.finish() }),
            ("no audio received",{ session in
                try session.padNative(id:"mic",frames:48_000,channels:1,rate:48000,offsetMs:0)
                try session.finish() }),
        ]
        for (name,configure) in cases {
            let root = temporary(); defer { try? FileManager.default.removeItem(at:root) }
            let file = try stored(try session(root,configure:configure))
            #expect(!WriterLoss.isWriterOnly(file),"\(name)")
            #expect(try badge(root) != nil,"\(name): badge kept")
        }
    }
    @Test func lossIsSummedAcrossTheSourcesTracksBeforeRounding() {
        // Two microphone spans, each under 1 s of writer loss, at two rates: exactly 1000 ms together.
        let file = try! JSONParser.parse(Data("""
        {"state":"interrupted","problemKind":"io","problem":"1000 ms of microphone audio was lost because the computer could not keep up; the gaps contain silence.",
         "events":[{"atMs":9000,"type":"end","reason":"error"}],"tracks":[
         {"id":"a","kind":"microphone","sampleRate":48000,"frames":120000,"receivedFrames":96000,"droppedFrames":24000,"gaps":[{"atMs":1000,"frames":24000,"kind":"writer"}]},
         {"id":"b","kind":"microphone","sampleRate":44100,"frames":66150,"receivedFrames":44100,"droppedFrames":22050,"gaps":[{"atMs":4000,"frames":22050,"kind":"writer"}]}]}
        """.utf8))
        #expect(WriterLoss.isWriterOnly(file))
        let row = report(file).sources.first
        #expect(row?.computerBusy?.values["duration"] == .duration(1000))
        #expect(row?.gapLines.isEmpty == true)
        // Two 499.6 ms spans: 999.2 ms rounded once is 999 (no line); rounding each span first
        // would wrongly give 500 + 500 = 1000 and show it.
        let under = try! JSONParser.parse(Data("""
        {"state":"interrupted","problemKind":"io","problem":"999 ms of microphone audio was lost because the computer could not keep up; the gaps contain silence.",
         "events":[{"atMs":9000,"type":"end","reason":"error"}],"tracks":[
         {"id":"a","kind":"microphone","sampleRate":48000,"frames":120000,"receivedFrames":96000,"droppedFrames":23981,"gaps":[{"atMs":1000,"frames":23981,"kind":"writer"}]},
         {"id":"b","kind":"microphone","sampleRate":48000,"frames":120000,"receivedFrames":96000,"droppedFrames":23981,"gaps":[{"atMs":4000,"frames":23981,"kind":"writer"}]}]}
        """.utf8))
        #expect(report(under).sources.first?.computerBusy == nil,"summed exactly, rounded once")
    }
    @Test func aBrowserSourceKeepsItsProducerDropsAndAnOwnedCapturesEndIsUnknown() {
        let file = try! JSONParser.parse(Data("""
        {"state":"interrupted","problemKind":"io","problem":"1000 ms of remote audio was lost because the computer could not keep up; the gaps contain silence.",
         "events":[{"atMs":9000,"type":"end","reason":"error"}],
         "captureOutcome":{"sources":[{"sourceTrackId":"r1","kind":"remote","label":"Guest","captureOutcome":"captured","audioMs":5000,"trackIds":["t"]}]},
         "tracks":[{"id":"t","kind":"remote","sampleRate":48000,"frames":384000,"receivedFrames":240000,"droppedFrames":96000,
                    "gaps":[{"atMs":1000,"frames":48000,"kind":"writer"}]}]}
        """.utf8))
        #expect(WriterLoss.isWriterOnly(file))
        let details = report(file)
        let row = details.sources.first
        #expect(row?.computerBusy?.values["duration"] == .duration(1000))
        #expect(row?.gapLines.map(\.label) == [.catalog("details.health.dropped")],"the producer's own 1 s drop still shows")
        #expect(row?.gapLines.first?.values["value"] == .duration(1000))
        #expect(details.ended == .init("details.unknown") && !details.endKnown,"D69 overwrote the browser stop's own reason")
    }
}
