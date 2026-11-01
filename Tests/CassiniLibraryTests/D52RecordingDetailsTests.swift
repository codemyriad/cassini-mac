// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
@testable import CassiniLibrary

/// D52.3a minimal Recording details (GNOME source_report.py / capture_details.py rules).
struct D52RecordingDetailsTests {
    private let gb = Locale(identifier:"en_GB")
    private func json(_ text: String) -> JSON { try! JSONParser.parse(Data(text.utf8)) }
    private func source(id: String = "s", kind: String = "remote", label: String = "Guest", outcome: String = "captured",
                        audioMs: String = "61000", tracks: [String] = ["t"], expected: String? = nil) -> String {
        "{\"sourceTrackId\":\"\(id)\",\"kind\":\"\(kind)\",\"label\":\"\(label)\",\"captureOutcome\":\"\(outcome)\",\"audioMs\":\(audioMs),\"trackIds\":[\(tracks.map { "\"\($0)\"" }.joined(separator:","))]"
            + (expected.map { ",\"captureExpected\":\($0)" } ?? "") + "}"
    }
    private func session(_ sources: [String], tracks: String = "[{\"id\":\"t\",\"kind\":\"remote\",\"sampleRate\":48000}]", events: String = "[]") -> JSON {
        json("{\"tracks\":\(tracks),\"events\":\(events),\"captureOutcome\":{\"sources\":[\(sources.joined(separator:","))]}}")
    }
    private func report(_ session: JSON?, _ lifecycle: RecordingDetailsReport.Lifecycle = .saved, record: JSON? = nil, end: JSON? = nil,
                        separated: Bool = false, done: Bool = false) -> RecordingDetailsReport {
        .init(.init(lifecycle:lifecycle,title:"Weekly",session:session,captureRecord:record,storedEnd:end,sourceSpansSeparated:separated,transcriptDone:done))
    }
    private func text(_ line: RecordingDetailsReport.Line, _ language: CassiniLanguage = .en) -> String { line.render(language:language,locale:gb) }

    @Test func outcomesFinalAndLive() {
        let rows = report(session([source(outcome:"captured"),source(id:"n",outcome:"neverAudio",audioMs:"0"),source(id:"l",outcome:"lowAudio",audioMs:"500"),source(id:"f",outcome:"failed",audioMs:"0")])).sources
        let english = text(rows[0].line)
        #expect(english.contains("Guest") && english.contains(LibraryFormat.meetingDuration(61000,locale:gb,language:.en)))
        #expect(rows.map(\.problem) == [false,true,true,true])
        #expect(rows[0].line.id == "details.sources.captured" && rows[1].line.id == "details.sources.neverAudio")
        #expect(rows[2].line.id == "details.sources.lowAudio" && rows[3].line.id == "details.sources.failed")
        let live = report(session([source(id:"n",outcome:"neverAudio",audioMs:"0"),source(id:"l",outcome:"lowAudio",audioMs:"500"),source(id:"f",outcome:"failed")]),.recording).sources
        #expect(live[0].line.id == nil && text(live[0].line) == "Guest","Live neverAudio is just the name")
        #expect(live[1].line.id == "details.sources.captured","Live lowAudio shows as captured")
        #expect(live.map(\.problem) == [false,false,true])
    }
    @Test func unselectedSourcesAreNeutral() {
        let row = report(session([source(outcome:"neverAudio",audioMs:"0",expected:"false")],tracks:"[{\"id\":\"t\",\"sampleRate\":48000,\"gapFrames\":96000}]")).sources[0]
        #expect(row.line.id == "details.sources.notSelected"); #expect(!row.problem); #expect(row.gapLines.isEmpty)
    }
    @Test func naming() {
        let rows = report(session([source(kind:"microphone",label:""),source(id:"y",kind:"system",label:"x"),source(id:"z",label:"  Ana \\n  Lima "),
                                   source(id:"e",label:"   "),source(id:"long",label:String(repeating:"a",count:200))])).sources
        #expect(rows[0].line.values["source"] == .catalog("common.yourMicrophone"))
        #expect(rows[1].line.values["source"] == .catalog("recordFirst.sound.title"))
        #expect(rows[2].line.values["source"] == .text("Ana Lima"))
        #expect(rows[3].line.values["source"] == .catalog("details.source.unknown"))
        #expect(rows[4].line.values["source"] == .text(String(repeating:"a",count:180)))
    }
    @Test func gapAndDroppedLines() {
        func lines(_ tracks: String, ids: [String] = ["t"]) -> [RecordingDetailsReport.Line] {
            report(session([source(tracks:ids)],tracks:tracks)).sources[0].gapLines
        }
        #expect(lines("[{\"id\":\"t\",\"sampleRate\":48000,\"gapFrames\":120000}]").map(\.id) == ["details.sources.gap"])
        #expect(lines("[{\"id\":\"t\",\"sampleRate\":48000,\"gapFrames\":96000,\"droppedFrames\":96000}]").count == 1,"Equal drop and padding: one line")
        let both = lines("[{\"id\":\"t\",\"sampleRate\":48000,\"gapFrames\":96000,\"droppedFrames\":48000}]")
        #expect(both.count == 2); #expect(text(both[1]) == "Dropped audio: 1 min".replacingOccurrences(of:"1 min",with:LibraryFormat.meetingDuration(1000,locale:gb,language:.en)))
        #expect(lines("[{\"id\":\"t\",\"sampleRate\":48000}]").isEmpty,"Missing counters are zero")
        #expect(lines("[{\"id\":\"x\",\"sampleRate\":48000,\"gapFrames\":96000}]").isEmpty,"Missing track: unknown")
        #expect(lines("[{\"id\":\"t\",\"sampleRate\":48000,\"gapFrames\":96000},{\"id\":\"t\",\"sampleRate\":48000}]").isEmpty,"Duplicate track: unknown")
        #expect(lines("[{\"id\":\"t\",\"sampleRate\":4000,\"gapFrames\":96000}]").isEmpty,"Rate out of range: unknown")
        #expect(lines("[{\"id\":\"t\",\"sampleRate\":48000,\"gapFrames\":1.5}]").isEmpty,"Non-integer counter: unknown")
        #expect(lines("[{\"id\":\"t\",\"sampleRate\":48000,\"gapFrames\":96000}]",ids:["t","t"]).isEmpty,"Duplicate trackIds: unknown")
        #expect(report(session([source()],tracks:"\"junk\"")).sources.count == 1,"Malformed tracks never hide rows")
    }
    @Test func validatorRejectsTheWholeRecord() {
        for bad in [source(kind:"phone"),source(outcome:"partial"),source(audioMs:"-1"),source(audioMs:"true"),source(expected:"null"),source(expected:"0"),
                    source(id:String(repeating:"é",count:101)),source(label:String(repeating:"a",count:201)),
                    "{\"sourceTrackId\":\"s\",\"kind\":\"remote\",\"captureOutcome\":\"captured\",\"audioMs\":1,\"trackIds\":[]}"] {
            #expect(report(session([source(id:"ok"),bad])).sources.isEmpty,"\(bad)")
        }
        for version in ["true","2","\"1\""] {
            #expect(report(nil,record:json("{\"version\":\(version),\"sources\":[\(source())]}")).sources.isEmpty)
        }
        #expect(report(nil,record:json("{\"version\":1,\"sources\":[\(source())]}")).sources.count == 1)
    }
    @Test func liveRecordWinsEvenWhenInvalidAndStoredIsTheFallback() {
        let stored = json("{\"version\":1,\"sources\":[\(source(id:"stored"))],\"tracks\":[],\"events\":[]}")
        #expect(report(session([source(kind:"phone")]),record:stored).sources.isEmpty,"A well-formed but invalid live record: empty, no fallback")
        #expect(report(json("{\"tracks\":[]}"),record:stored).sources.count == 1,"No live record: the stored one")
        #expect(report(json("{\"captureOutcome\":{\"sources\":\"x\"}}"),record:stored).sources.count == 1,"A malformed live record falls back")
        #expect(report(json("{\"tracks\":[]}")).sources.isEmpty)
    }
    @Test func endLinePrecedence() {
        #expect(report(nil,.recording).ended.id == "details.end.recording")
        #expect(report(nil,.saving).ended.id == "details.end.saving")
        let events = "[{\"atMs\":0,\"type\":\"selection\",\"reason\":\"start\",\"me\":true,\"others\":true},{\"atMs\":65000,\"type\":\"end\",\"reason\":\"callEnded\"}]"
        let fromEvents = report(session([],events:events),end:json("{\"reason\":\"user\",\"atMs\":1}")).ended
        #expect(fromEvents.id == "details.end.at"); #expect(fromEvents.values["reason"] == .catalog("details.end.callEnded")); #expect(fromEvents.values["time"] == .position(65000))
        let stored = report(json("{\"tracks\":[]}"),end:json("{\"reason\":\"disk\",\"atMs\":120000}")).ended
        #expect(stored.values["reason"] == .catalog("details.end.disk"))
        let noTime = report(nil,end:json("{\"reason\":\"appQuit\",\"atMs\":1.5}"))
        #expect(noTime.ended.label == .catalog("details.end.appQuit") && noTime.endKnown)
        let recordEvents = report(nil,record:json("{\"version\":1,\"sources\":[],\"events\":\(events)}")).ended
        #expect(recordEvents.values["reason"] == .catalog("details.end.callEnded"),"Without a session the record's events are used")
        let unknown = report(nil); #expect(unknown.ended.id == "details.unknown" && !unknown.endKnown)
    }
    @Test func headerOverlapAndNativeEmptyState() {
        let live = report(json("{\"tracks\":[]}"),.recording)
        #expect(live.subtitle?.id == "details.liveSubtitle" && live.updates)
        let saving = report(json("{\"tracks\":[]}"),.saving); #expect(saving.subtitle == nil && !saving.updates)
        #expect(report(nil,separated:true,done:true).notes.map(\.id) == ["details.sources.overlap"])
        #expect(report(nil,separated:true,done:false).notes.isEmpty); #expect(report(nil,separated:false,done:true).notes.isEmpty)
        let native = report(json("{\"tracks\":[{\"id\":\"m\",\"kind\":\"microphone\",\"sampleRate\":48000}],\"events\":[{\"atMs\":9000,\"type\":\"end\",\"reason\":\"user\"}]}"))
        #expect(native.sources.isEmpty); #expect(native.ended.id == "details.end.at")
    }
    @Test func liveSourceProblemRule() {
        #expect(RecordingDetailsReport.liveSourceProblem(session:session([source(outcome:"failed")])))
        #expect(!RecordingDetailsReport.liveSourceProblem(session:session([source(outcome:"failed",expected:"false")])))
        #expect(!RecordingDetailsReport.liveSourceProblem(session:session([source(outcome:"neverAudio",audioMs:"0"),source(id:"l",outcome:"lowAudio",audioMs:"1")])))
        #expect(RecordingDetailsReport.liveSourceProblem(session:json("{\"tracks\":[{\"id\":\"m\",\"kind\":\"microphone\",\"ended\":true,\"problemKind\":\"io\"}]}")))
        #expect(!RecordingDetailsReport.liveSourceProblem(session:json("{\"tracks\":[{\"id\":\"r\",\"kind\":\"remote\",\"ended\":true,\"problemKind\":\"io\"}]}")))
        #expect(!RecordingDetailsReport.liveSourceProblem(session:nil))
    }
    @Test func everyEmittedIdIsAPublishedMacStringAndRendersInSixLanguages() throws {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CassiniLibrary/Localization/strings.json")
        let entries = try #require(try JSONParser.parse(Data(contentsOf:url))["entries"]?.array)
        for id in RecordingDetailsReport.catalogIDs {
            let entry = try #require(entries.first { $0["id"]?.string == id },"\(id)")
            #expect(entry["status"]?.string != "pending","\(id)")
            #expect(entry["platforms"]?.array?.contains { $0.string == "mac" } == true,"\(id)")
        }
        let r = report(session([source(),source(id:"n",outcome:"neverAudio",audioMs:"0"),source(id:"x",kind:"system",outcome:"failed",audioMs:"0"),source(id:"u",outcome:"captured",expected:"false")],
                               tracks:"[{\"id\":\"t\",\"sampleRate\":48000,\"gapFrames\":96000,\"droppedFrames\":48000}]",
                               events:"[{\"atMs\":65000,\"type\":\"end\",\"reason\":\"tabClosed\"}]"),done:true)
        for language in CassiniLanguage.allCases {
            let lines = r.sources.flatMap { [$0.line] + $0.gapLines } + [r.ended,r.title]
            for line in lines {
                let value = text(line,language)
                #expect(!value.isEmpty && !value.contains("{"),"\(language) \(line)")
            }
            #expect(text(r.sources[0].line,language).contains("Guest"))
        }
        #expect(LibraryFormat.meetingDuration(45000,locale:gb,language:.en) == "under 1 min")
        #expect(LibraryFormat.meetingDuration(60000,locale:gb,language:.en) == "1 min")
        #expect(LibraryFormat.meetingDuration(3780000,locale:gb,language:.en) == "1 h 03 min")
    }
}
