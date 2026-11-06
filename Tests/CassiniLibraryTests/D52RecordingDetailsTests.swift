// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
import CassiniRecording
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
        #expect(rows[2].line.id == "details.sources.lowAudio.underSecond" && rows[3].line.id == "details.sources.failed")
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
        #expect(both.count == 2); #expect(text(both[1]) == "Dropped audio: 1 s")
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
    /// codex #105: a finite, nonnegative end time past the format bound used to trap
    /// converting to Int64 when details opened. It now falls back to the stored end or unknown.
    @Test func oversizedEndTimesFallBackInsteadOfTrapping() {
        func ends(_ at: String) -> String { "[{\"atMs\":\(at),\"type\":\"end\",\"reason\":\"user\"}]" }
        for at in ["1e20","9223372036854775808","9007199254740991","86460001"] {
            let unknown = report(session([],events:ends(at)))
            #expect(unknown.ended.id == "details.unknown" && !unknown.endKnown,"Session end at \(at): unknown")
            let stored = report(session([],events:ends(at)),end:json("{\"reason\":\"disk\",\"atMs\":120000}")).ended
            #expect(stored.values["reason"] == .catalog("details.end.disk") && stored.values["time"] == .position(120000),"Session end at \(at): the stored end")
            let record = report(nil,record:json("{\"version\":1,\"sources\":[],\"events\":\(ends(at))}")).ended
            #expect(record.id == "details.unknown","Record end at \(at): unknown")
            let storedOnly = report(nil,end:json("{\"reason\":\"appQuit\",\"atMs\":\(at)}"))
            #expect(storedOnly.ended.label == .catalog("details.end.appQuit") && storedOnly.ended.values["time"] == nil && storedOnly.endKnown,
                    "Stored end at \(at): the reason without a time")
        }
        let bound = report(session([],events:ends("86460000"))).ended
        #expect(bound.id == "details.end.at" && bound.values["time"] == .position(86_460_000),"The format bound itself is a valid end")
    }
    @Test func oversizedCounterSumsAreUnknown() {
        let ids = (0..<10).map { "t\($0)" }
        let tracks = "[" + ids.map { "{\"id\":\"\($0)\",\"sampleRate\":8000,\"gapFrames\":9007199254740991}" }.joined(separator:",") + "]"
        let row = report(session([source(tracks:ids)],tracks:tracks)).sources[0]
        #expect(row.gapLines.isEmpty,"A padding sum past the safe bound is unknown, not a trap")
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
    /// D58.2 R3 (Mac QA, 0.1.0): a native recording lists the sources it captured, from its tracks,
    /// instead of "No audio sources were reported".
    @Test func nativeRecordingsListTheirCapturedSources() {
        let tracks = "[{\"id\":\"m1\",\"kind\":\"microphone\",\"sampleRate\":48000,\"frames\":480000},"
            + "{\"id\":\"s1\",\"kind\":\"system\",\"sampleRate\":48000,\"frames\":960000,\"gapFrames\":96000},"
            + "{\"id\":\"s2\",\"kind\":\"system\",\"sampleRate\":44100,\"frames\":44100}]"
        func check(_ result: RecordingDetailsReport, _ name: String) {
            #expect(result.sources.map(\.line.id) == ["details.sources.captured","details.sources.captured"],"\(name)")
            #expect(result.sources.map { $0.line.values["source"] } == [.catalog("common.yourMicrophone"),.catalog("recordFirst.sound.title")],"\(name)")
            // Received audio: 10 s of microphone; 20 s - 2 s of padding + 1 s for this computer's sound.
            #expect(result.sources.map { $0.line.values["duration"] } == [.duration(10000),.duration(19000)],"\(name)")
            #expect(result.sources.map(\.problem) == [false,false],"\(name)")
            #expect(result.sources[1].gapLines.map(\.id) == ["details.sources.gap"],"\(name): its padding is still a gap line")
            #expect(!result.sourcesEmpty,"\(name)")
        }
        check(report(json("{\"source\":\"macos\",\"tracks\":\(tracks)}")),"saved session")
        check(report(json("{\"source\":\"macos\",\"tracks\":\(tracks)}"),.recording),"live session")
        // Saved, the session gone: the meeting.json captureRecord a native recording carries (no sources).
        check(report(nil,record:json("{\"version\":1,\"sources\":[],\"tracks\":\(tracks),\"events\":[]}")),"captureRecord")
        // Only what received audio is listed; nothing is listed for an invalid record.
        let micOnly = report(json("{\"tracks\":[{\"id\":\"m\",\"kind\":\"microphone\",\"sampleRate\":48000,\"frames\":48000},{\"id\":\"s\",\"kind\":\"system\",\"sampleRate\":48000,\"frames\":0}]}"))
        #expect(micOnly.sources.map { $0.line.values["source"] } == [.catalog("common.yourMicrophone")])
        #expect(report(nil,record:json("{\"version\":2,\"sources\":[],\"tracks\":\(tracks)}")).sources.isEmpty,"an invalid record lists nothing")
        // A browser recording's reported sources are unchanged: no native rows are added.
        let browser = report(session([source(kind:"microphone",label:"",tracks:["m1"])],tracks:tracks))
        #expect(browser.sources.count == 1)
    }
    /// #144 review: a native duration is the audio received, never padding. Real writer output:
    /// a microphone prefix, the writer's own lost audio and an input gap.
    @Test func nativeDurationsCountOnlyReceivedAudioFromTheRealWriter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("R3Native-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let writer = try RecordingSession(parent:root,title:"Native",source:"macos")
        let second = Data(count:32000)  // 1 s of 16 kHz mono PCM
        try writer.transition(starting:[.init(id:"mic",label:"",kind:"microphone",sampleRate:16000,channels:1,boundaryMs:0),
                                        .init(id:"sys",label:"",kind:"system",sampleRate:16000,channels:1)])
        // Microphone: its first buffer 2 s after the selection boundary (a 2 s prefix), then 1 s.
        try writer.appendNative(id:"mic",pcm:second,offsetMs:2000)
        // This computer's sound: 1 s, 2 s of the writer's own lost audio, 0.5 s, a 1.5 s input gap, 1 s.
        try writer.appendNative(id:"sys",pcm:second,offsetMs:0)
        try writer.padNative(id:"sys",frames:32000,channels:1,rate:16000,offsetMs:1000)
        try writer.appendNative(id:"sys",pcm:second.prefix(16000),offsetMs:3000)
        try writer.appendNative(id:"sys",pcm:second,offsetMs:5000,gapKind:"input")
        try writer.finish()
        let file = try Data(contentsOf:writer.directory.appendingPathComponent("session.json"))
        let written = try JSONParser.parse(file)
        // The writer stored every padding range, and counted only jump/input ones as gapFrames.
        let kinds = (written["tracks"]?.array ?? []).map { ($0["gaps"]?.array ?? []).compactMap { $0["kind"]?.string } }
        try #require(kinds == [["prefix"],["writer","input"]])
        try #require((written["tracks"]?.array ?? []).map { $0["frames"]?.int } == [48000,96000])
        // SPEC.md "Gap ranges and presence" (D69): writer padding counts as
        // droppedFrames, not gapFrames; it interrupts as io and ends in error.
        #expect((written["tracks"]?.array ?? []).map { $0["droppedFrames"]?.int } == [nil,32000])
        #expect((written["tracks"]?.array ?? []).map { $0["gapFrames"]?.int } == [nil,24000])
        #expect(written["state"]?.string == "interrupted" && written["problemKind"]?.string == "io")
        #expect(written["events"]?.array?.last?["reason"]?.string == "error")
        func check(_ result: RecordingDetailsReport, _ name: String) {
            #expect(result.sources.map(\.line.id) == ["details.sources.captured","details.sources.captured"],"\(name)")
            // 1 s received of the microphone's 3 s; 2.5 s of this computer's sound's 6 s.
            #expect(result.sources.map { $0.line.values["duration"] } == [.duration(1000),.duration(2500)],"\(name)")
            #expect(result.sources.map(\.problem) == [false,false],"\(name)")
            // D69.2: the 1.5 s input gap is presented as today; the writer's own 2 s is the quiet
            // computer-busy line, not a dropped-audio warning. Neither is received audio.
            #expect(result.sources.map { $0.gapLines.map(\.values) } == [[],[
                ["source":.catalog("recordFirst.sound.title"),"duration":.duration(1500)]]],"\(name)")
            #expect(result.sources[1].gapLines.first?.id == "details.sources.gap","\(name)")
            #expect(result.sources.map { $0.computerBusy } == [nil,.init("details.sources.computerBusy",
                ["source":.catalog("recordFirst.sound.title"),"duration":.duration(2000)])],"\(name)")
            // Not writer-only (a real gap), so the end stays as D69 stored it.
            #expect(result.ended.values["reason"] == .catalog("details.end.error"),"\(name)")
        }
        check(report(written),"receivedFrames")
        // An older file without receivedFrames: its stored ranges, the input gap subtracted once.
        var object = try #require(try JSONSerialization.jsonObject(with:file) as? [String:Any])
        object["tracks"] = (object["tracks"] as? [[String:Any]] ?? []).map { var track = $0; track["receivedFrames"] = nil; return track }
        check(report(try JSONParser.parse(JSONSerialization.data(withJSONObject:object))),"padding ranges")
        // Nothing is counted after an overflow marker (unknown to the track end); a track whose
        // received count or ranges are unreadable is left out.
        let overflow = report(json("{\"tracks\":[{\"id\":\"m\",\"kind\":\"microphone\",\"sampleRate\":16000,\"frames\":160000,\"startOffsetMs\":0,"
            + "\"gaps\":[{\"atMs\":0,\"durationMs\":1000,\"frames\":16000,\"kind\":\"writer\"},{\"atMs\":5000,\"kind\":\"overflow\"}]},"
            + "{\"id\":\"s\",\"kind\":\"system\",\"sampleRate\":16000,\"frames\":16000,\"receivedFrames\":32000},"
            + "{\"id\":\"s2\",\"kind\":\"system\",\"sampleRate\":16000,\"frames\":16000,\"gaps\":{}}]}"))
        #expect(overflow.sources.map { $0.line.values["duration"] } == [.duration(4000)])
        // A file from before D52 (no gaps, no receivedFrames): the sink padded its dropped audio
        // with silence and counted it apart from host-time gaps, so both are subtracted.
        let early = report(json("{\"tracks\":[{\"id\":\"m\",\"kind\":\"microphone\",\"sampleRate\":16000,\"frames\":96000,\"gapFrames\":16000,\"droppedFrames\":32000},"
            + "{\"id\":\"s\",\"kind\":\"system\",\"sampleRate\":16000,\"frames\":32000,\"droppedFrames\":24000}]}"))
        #expect(early.sources.map(\.line.id) == ["details.sources.captured","details.sources.lowAudio.underSecond"])
        #expect(early.sources.map { $0.line.values["duration"] } == [.duration(3000),nil])
    }
    /// #144 review: a native side's outcome follows its received duration (D52: under 1000 ms is
    /// low audio), worded by row(): saved, a problem; live, still captured.
    @Test func nativeLowAudioFollowsTheReceivedDuration() {
        func tracks(_ kind: String, received: Int) -> JSON {
            json("{\"tracks\":[{\"id\":\"t\",\"kind\":\"\(kind)\",\"sampleRate\":16000,\"frames\":48000,\"receivedFrames\":\(received)}]}")
        }
        for kind in ["microphone","system"] {
            let low = report(tracks(kind,received:8000))  // 500 ms
            #expect(low.sources.map(\.line.id) == ["details.sources.lowAudio.underSecond"],"\(kind)")
            #expect(low.sources.map { $0.line.values["duration"] } == [nil],"\(kind): under a second, no number (D58.4)")
            #expect(low.sources.map(\.problem) == [true],"\(kind)")
            let live = report(tracks(kind,received:8000),.recording)
            #expect(live.sources.map(\.line.id) == ["details.sources.captured"] && live.sources.map(\.problem) == [false],"\(kind) live")
            // The threshold: 999 ms is low audio, 1000 ms is captured.
            #expect(report(tracks(kind,received:15984)).sources.map(\.line.id) == ["details.sources.lowAudio.underSecond"],"\(kind) 999 ms")
            let enough = report(tracks(kind,received:16000))
            #expect(enough.sources.map(\.line.id) == ["details.sources.captured"] && enough.sources.map(\.problem) == [false],"\(kind) 1000 ms")
        }
        // The ledger's own arithmetic (frames * 1000 / rate): one second at 44056 Hz is captured.
        let odd = report(json("{\"tracks\":[{\"id\":\"t\",\"kind\":\"microphone\",\"sampleRate\":44056,\"frames\":44056,\"receivedFrames\":44056}]}"))
        #expect(odd.sources.map(\.line.id) == ["details.sources.captured"] && odd.sources.map { $0.line.values["duration"] } == [.duration(1000)])
        // Under a millisecond received is still low audio, not a missing row.
        let tiny = report(json("{\"tracks\":[{\"id\":\"t\",\"kind\":\"microphone\",\"sampleRate\":8000,\"frames\":4000,\"receivedFrames\":4}]}"))
        #expect(tiny.sources.map(\.line.id) == ["details.sources.lowAudio.underSecond"] && tiny.sources.map(\.problem) == [true])
    }
    /// R13 (D67.1) on native rows: a done write-down that left out every track of a captured side
    /// adds its silent line; a low-audio side keeps its own line only (R13.2).
    @Test func nativeRowsShowTheSilentLine() {
        let tracks = json("{\"tracks\":[{\"id\":\"m\",\"kind\":\"microphone\",\"sampleRate\":16000,\"frames\":32000,\"receivedFrames\":32000},"
            + "{\"id\":\"s\",\"kind\":\"system\",\"sampleRate\":16000,\"frames\":32000,\"receivedFrames\":8000}]}")
        func silentLines(done: Bool) -> [String?] {
            RecordingDetailsReport(.init(lifecycle:.saved,title:"Weekly",session:tracks,captureRecord:nil,storedEnd:nil,sourceSpansSeparated:false,
                                         transcriptDone:done,silentTracks:["m","s"])).sources.map { $0.silent?.id }
        }
        #expect(silentLines(done:true) == ["details.sources.silent",nil])
        #expect(silentLines(done:false) == [nil,nil],"only a done write-down's list counts")
    }
    /// D58.3: after Stop, a native "This computer" side whose whole track is digital silence (the
    /// done write-down's silentTracks) adds the conditional permission hint under its silent line.
    /// Mic-only, non-silent, low-audio, unfinished and browser sources get none.
    @Test func nativeSilentSystemSoundGetsThePermissionHint() {
        let hint = "details.sources.silent.othersPermissionHint"
        let both = "[{\"id\":\"m\",\"kind\":\"microphone\",\"sampleRate\":16000,\"frames\":32000,\"receivedFrames\":32000},"
            + "{\"id\":\"s\",\"kind\":\"system\",\"sampleRate\":16000,\"frames\":32000,\"receivedFrames\":32000}]"
        func details(_ session: JSON?, record: JSON? = nil, silent: Set<String>, done: Bool = true,
                     _ lifecycle: RecordingDetailsReport.Lifecycle = .saved) -> RecordingDetailsReport {
            .init(.init(lifecycle:lifecycle,title:"Weekly",session:session,captureRecord:record,storedEnd:nil,sourceSpansSeparated:false,
                        transcriptDone:done,silentTracks:silent))
        }
        let native = json("{\"source\":\"macos\",\"tracks\":\(both)}")
        // This computer's sound silent: its silent line, then the hint; the microphone has neither.
        let silentSystem = details(native,silent:["s"])
        #expect(silentSystem.sources.map { $0.silent?.id } == [nil,"details.sources.silent"])
        #expect(silentSystem.sources.map { $0.permissionHint?.id } == [nil,hint])
        #expect(silentSystem.sources[1].lines.map(\.id).suffix(2) == ["details.sources.silent",hint],"the hint follows the silent line")
        #expect(silentSystem.sources.map(\.problem) == [false,false],"conditional, never a warning")
        #expect(details(native,silent:["m","s"]).sources.map { $0.permissionHint?.id } == [nil,hint])
        // The same from the meeting.json captureRecord once the session is gone.
        let stored = details(nil,record:json("{\"version\":1,\"sources\":[],\"tracks\":\(both),\"events\":[]}"),silent:["s"])
        #expect(stored.sources.map { $0.permissionHint?.id } == [nil,hint])
        // This computer's sound not silent, or only the microphone silent: no hint.
        #expect(details(native,silent:["m"]).sources.allSatisfy { $0.permissionHint == nil })
        #expect(details(native,silent:[]).sources.allSatisfy { $0.permissionHint == nil })
        // A microphone-only native recording, silent: its silent line, no hint.
        let micOnly = details(json("{\"tracks\":[{\"id\":\"m\",\"kind\":\"microphone\",\"sampleRate\":16000,\"frames\":32000,\"receivedFrames\":32000}]}"),silent:["m"])
        #expect(micOnly.sources.map { $0.silent?.id } == ["details.sources.silent"] && micOnly.sources.map { $0.permissionHint } == [nil])
        // Before the write-down is done there is no silent line, so no hint.
        #expect(details(native,silent:["s"],done:false).sources.allSatisfy { $0.permissionHint == nil })
        // Low audio keeps its own line only (R13.2): no silent line, no hint.
        let low = details(json("{\"tracks\":[{\"id\":\"s\",\"kind\":\"system\",\"sampleRate\":16000,\"frames\":32000,\"receivedFrames\":8000}]}"),silent:["s"])
        #expect(low.sources.map(\.line.id) == ["details.sources.lowAudio.underSecond"] && low.sources.map { $0.permissionHint } == [nil])
        // A browser recording's reported "This computer" source, silent: the silent line only.
        let browser = details(session([source(id:"sys",kind:"system",label:"",tracks:["s"])],tracks:both),silent:["s"])
        #expect(browser.sources.map { $0.silent?.id } == ["details.sources.silent"] && browser.sources.map { $0.permissionHint } == [nil])
        // The hint renders in every catalog language.
        for language in CassiniLanguage.allCases {
            let shown = silentSystem.sources[1].permissionHint!.render(language:language,locale:gb)
            #expect(!shown.isEmpty && !shown.contains("{"),"\(language)")
        }
    }
    /// L2 (Mac QA 0.1.1): the meeting page shows the D58.3 hint under "No speech was found" when
    /// Recording details would. Read from a real folder through the loader both use.
    @Test func thePermissionHintIsReadFromTheStoredMeeting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("L2Hint-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let writer = try RecordingSession(parent:root,title:"Quiet",source:"macos")
        try writer.transition(starting:[.init(id:"mic",label:"",kind:"microphone",sampleRate:16000,channels:1),
                                        .init(id:"sys",label:"",kind:"system",sampleRate:16000,channels:1)])
        try writer.appendNative(id:"mic",pcm:Data(count:64000),offsetMs:0)
        try writer.appendNative(id:"sys",pcm:Data(count:64000),offsetMs:0)
        try writer.finish()
        let file = writer.directory.appendingPathComponent("meeting.json")
        func store(silent: [String]) throws {
            // A native session has no meeting.json until the Library writes one; only its recordingDetails matter here.
            var meeting = ((try? Data(contentsOf:file)).flatMap { try? JSONSerialization.jsonObject(with:$0) } as? [String:Any]) ?? [:]
            meeting["recordingDetails"] = ["writingDown":["silentTracks":silent]]
            try JSONSerialization.data(withJSONObject:meeting).write(to:file)
        }
        func shows(done: Bool = true) -> Bool {
            RecordingDetailsReport(.load(folder:writer.directory,lifecycle:.saved,title:"Quiet",transcriptDone:done)).showsPermissionHint
        }
        try store(silent:["mic","sys"])
        #expect(shows(),"a fully silent native This computer side")
        #expect(!shows(done:false),"only after a done write-down")
        try store(silent:["mic"])
        #expect(!shows(),"only the microphone was silent")
    }
    /// L1 (Mac QA 0.1.1), D58.4: Recording details never rounds a duration down to whole minutes.
    @Test func durationsAreShownInSecondsUnderAMinute() {
        func line(_ ms: Int, outcome: String = "captured", final: Bool = true) -> RecordingDetailsReport.Line {
            report(session([source(kind:"microphone",label:"",outcome:outcome,audioMs:String(ms))]),final ? .saved : .recording).sources[0].line
        }
        #expect(text(line(43_000)) == "Your microphone: 43 s recorded.")
        #expect(text(line(87_000)) == "Your microphone: 1 min 27 s recorded.")
        #expect(text(line(3_600_000)).hasPrefix("Your microphone: 1 h"))
        #expect(LibraryFormat.detailsDuration(1_999,locale:gb,language:.en) == "1 s","whole seconds")
        // Under a second the low-audio line says so in words, with no number (underSecond).
        let low = line(500, outcome:"lowAudio")
        #expect(low.id == "details.sources.lowAudio.underSecond" && low.values["duration"] == nil)
        #expect(text(low) == "Your microphone: less than a second of audio was received.")
        #expect(line(1_500, outcome:"lowAudio").id == "details.sources.lowAudio","a stored lowAudio of a second or more keeps its number")
        #expect(line(500, outcome:"lowAudio", final:false).id == "details.sources.captured","live, low audio still reads as captured")
        // A positive gap or drop under a second shows as 1 s, never as 0 s.
        let gap = report(session([source(tracks:["t"])],tracks:"[{\"id\":\"t\",\"sampleRate\":48000,\"gapFrames\":14400}]")).sources[0].gapLines
        #expect(gap.map { text($0) }.first?.contains("1 s") == true,"a 300 ms gap: \(gap.map { text($0) })")
        let tiny = report(session([source(tracks:["t"])],tracks:"[{\"id\":\"t\",\"sampleRate\":48000,\"gapFrames\":1}]")).sources[0].gapLines
        #expect(tiny.map { text($0) }.first?.contains("1 s") == true,"\(tiny.map { text($0) })")
        #expect(LibraryFormat.detailsDuration(0,locale:gb,language:.en) == "0 s")
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
