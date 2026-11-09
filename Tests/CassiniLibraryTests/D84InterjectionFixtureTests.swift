// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniKit
@testable import CassiniLibrary

struct D84InterjectionFixtureTests {
    struct Fixture: Decodable { let items: [TranscriptRendering.Word] }
    struct Expected: Decodable {
        let rows: [Row]
        struct Row: Decodable, Equatable {
            let speaker: String; let continuation: Bool; let startMs: Int64; let endMs: Int64
            let over: [String]; let crosstalk: Bool; let members: [Member]
        }
        struct Member: Decodable, Equatable {
            let kind: String; let speaker: String?; let crosstalk: Bool?
            let wordIndices: [Int]; let text: String
        }
    }
    @Test(arguments:["acknowledgment","competing","monologue","overlapping-turns","brief-reply","seam-gap"])
    func viewerRows(name: String) throws {
        let root = try #require(Bundle.module.url(forResource:name,withExtension:"words.json",subdirectory:"Golden/interjections"))
        let fixture = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:root))
        #expect(fixture.items.allSatisfy { !$0.text.contains(where:\.isWhitespace) },"Words remain the atoms")
        let expectedURL = root.deletingLastPathComponent().appendingPathComponent(name+".expected.json")
        let expected = try JSONDecoder().decode(Expected.self,from:Data(contentsOf:expectedURL))
        let result = TranscriptRendering.render(fixture.items)
        let actual = result.rows.map { row in
            Expected.Row(speaker:row.speaker,continuation:row.continuation,startMs:row.startMs,endMs:row.endMs,over:row.over,crosstalk:row.crosstalk,
                         members:row.members.map { .init(kind:$0.kind,speaker:$0.speaker,crosstalk:$0.crosstalk,wordIndices:$0.wordIndices,text:$0.text) })
        }
        #expect(actual == expected.rows,"Viewer 1111155: \(name)")
        let rendered = result.rows.flatMap(\.members).flatMap(\.wordIndices)
        #expect(rendered.sorted() == Array(fixture.items.indices),"Every atom exactly once")
        #expect(result.words.map(\.text) == fixture.items.map(\.text))
        #expect(result.words.map(\.startMs) == fixture.items.map(\.startMs),"Repair cannot move seek anchors")
    }
    @Test func seededAudibleOrderMatchesViewer() throws {
        struct Corpus: Decodable {
            struct Case: Decodable { let name: String; let items: [TranscriptRendering.Word]; let rows: [Expected.Row] }
            let cases: [Case]
        }
        let url = try #require(Bundle.module.url(forResource:"audible-order",withExtension:"json",subdirectory:"Golden/interjections"))
        let corpus = try JSONDecoder().decode(Corpus.self,from:Data(contentsOf:url))
        #expect(corpus.cases.count == 128)
        for fixture in corpus.cases {
            let result = TranscriptRendering.render(fixture.items)
            let rows = result.rows.map { row in
                Expected.Row(speaker:row.speaker,continuation:row.continuation,startMs:row.startMs,endMs:row.endMs,over:row.over,crosstalk:row.crosstalk,
                             members:row.members.map { .init(kind:$0.kind,speaker:$0.speaker,crosstalk:$0.crosstalk,wordIndices:$0.wordIndices,text:$0.text) })
            }
            #expect(rows == fixture.rows,"Viewer audible order: \(fixture.name)")
            #expect(result.rows.flatMap(\.members).flatMap(\.wordIndices).sorted() == Array(fixture.items.indices))
            #expect(result.words == fixture.items)
        }
    }
    @Test(arguments:["acknowledgment","competing","monologue","overlapping-turns","brief-reply","seam-gap"])
    func meetingAndExportAdapters(name: String) throws {
        let url = try #require(Bundle.module.url(forResource:name,withExtension:"words.json",subdirectory:"Golden/interjections"))
        let input = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:url)).items
        let expected = try JSONDecoder().decode(Expected.self,from:Data(contentsOf:url.deletingLastPathComponent().appendingPathComponent(name+".expected.json")))
        let items = input.map { LibraryTranscriptItem(speaker:$0.speaker,startMs:$0.startMs,endMs:$0.endMs,text:$0.text) }
        let all = MeetingPresentation.turns(items), visible = MeetingPresentation.visibleTurns(all)
        func indices(_ words: [LibraryTranscriptItem]) -> [Int] {
            words.compactMap { w in input.firstIndex { $0.speaker == w.speaker && $0.startMs == w.startMs && $0.text == w.text } }
        }
        let actual = visible.map { turn -> Expected.Row in
            var members: [Expected.Member] = []
            for fragment in turn.fragments {
                let own = Array(turn.items[fragment])
                members.append(.init(kind:"words",speaker:nil,crosstalk:nil,wordIndices:indices(own),text:own.map(\.text).joined(separator:" ")))
                for chip in turn.asides where chip.after == fragment.upperBound-1 {
                    let child = all[chip.turn]
                    members.append(.init(kind:"interjection",speaker:child.speaker,crosstalk:!child.items.isEmpty && child.items.allSatisfy { $0.lowConfidenceSpeaker == true },wordIndices:indices(child.items),text:child.items.map(\.text).joined(separator:" ")))
                }
            }
            return .init(speaker:turn.speaker,continuation:turn.continuation,startMs:turn.startMs,endMs:turn.endMs,over:turn.over,crosstalk:turn.crosstalk,members:members)
        }
        #expect(actual == expected.rows,"Meeting/Search adapter: \(name)")
        let expectedText = expected.rows.map { row in row.members.map { $0.kind == "words" ? $0.text : "(\($0.speaker!): \($0.text))" }.joined(separator:" ") }
        #expect(visible.map { MeetingPresentation.prose($0,in:all).text } == expectedText)
        #expect(LibraryTranscriptTurn.coalescing(items).map(\.text) == expectedText,"Library preview uses the same rows")
        let legacy = Timeline(input.map { CassiniKit.Word(speaker:$0.speaker,startMs:Int($0.startMs),endMs:Int($0.endMs),text:$0.text,lowConfidenceSpeaker:$0.lowConfidenceSpeaker ?? false,attributionGapDb:nil) })
        #expect(legacy.turns.map { legacy.text($0) } == expectedText,"Legacy/QuickLook preserve chips inline")
        #expect(legacy.turns.map(\.over) == expected.rows.map(\.over))
        #expect(legacy.turns.map(\.continuation) == expected.rows.map(\.continuation))
        #expect(legacy.turns.map { Int64($0.startMs) } == expected.rows.map(\.startMs))
        #expect(legacy.turns.map { Int64($0.endMs) } == expected.rows.map(\.endMs))
        let markdown = MeetingMarkdown.render(title:name,start:nil,durationMs:nil,timeZone:TimeZone(secondsFromGMT:0)!,names:[:],items:items,notes:[],locale:Locale(identifier:"en_GB"),language:.en)
        for text in expectedText { #expect(markdown.contains(MeetingMarkdown.escape(text))) }
        #expect(markdown.components(separatedBy:"** · ").count-1 == expected.rows.count,"Export has one block per readable row")
    }
    private func w(_ speaker: String, _ start: Int64, _ end: Int64, _ text: String) -> TranscriptRendering.Word {
        .init(speaker:speaker,startMs:start,endMs:end,text:text)
    }
    @Test func timingRepairHonoursProducerAttestationAndDoesNotRewriteText() {
        let input = [w("a",0,5000,"\"Yes.\""),w("b",2000,2500,"Okay")]
        let repaired = TranscriptRendering.render(input)
        #expect(repaired.words[0].endMs == 1000)
        #expect(repaired.words[0].text == "\"Yes.\"")
        #expect(repaired.rows.allSatisfy { $0.over.isEmpty })
        let bounded = TranscriptRendering.render(input,endsBoundedByAudio:true)
        #expect(bounded.words == input)
        #expect(bounded.rows.map(\.over) == [["b"],["a"]])
    }
    @Test func overlapsAreOrderedByAudibleCollisionAndOnlyOnFirstParagraph() {
        let input = [w("a",0,3000,"Speech"),w("b",100,500,"Short"),w("c",200,2200,"Long"),w("d",300,1200,"Middle")]
        let rows = TranscriptRendering.render(input,endsBoundedByAudio:true).rows
        #expect(rows.first?.over == ["c","d","b"])
        #expect(TranscriptRendering.speakerList(["A","B","C"]) == "A, B and C")
    }
    @Test func punctuationAndZeroDurationWordsStayStored() {
        let input = [w("a",0,100,"\"Hello"),w("a",100,100,"world\""),w("b",200,200,"!")]
        let result = TranscriptRendering.render(input)
        #expect(result.rows.flatMap(\.members).map(\.text) == ["\"Hello world\"","!"])
        #expect(result.rows.flatMap(\.members).flatMap(\.wordIndices).sorted() == [0,1,2])
    }
    @Test func admissionThresholdsAndContinuityEvidence() {
        // Audible aside length, not word count or its envelope.
        for (duration,nested) in [(Int64(2000),true),(2001,false)] {
            let result = TranscriptRendering.render([w("a",0,1000,"Before"),w("b",900,900+duration,"Reply"),w("a",1100,4000,"after")],endsBoundedByAudio:true)
            #expect((result.runs[1].host != nil) == nested)
        }
        for (gap,nested) in [(Int64(400),true),(401,false)] {
            let result = TranscriptRendering.render([w("a",0,1000,"Before"),w("b",900,1400,"Reply"),w("a",1000+gap,3000,"after")],endsBoundedByAudio:true)
            #expect((result.runs.first(where:{$0.speaker == "b"})?.host != nil) == nested)
        }
        // A clean A/B/A exchange has no near-touch evidence and must stay chronological.
        let exchange = TranscriptRendering.render([w("a",0,1000,"Question?"),w("b",1050,1150,"Yes."),w("a",1200,1600,"Good.")])
        #expect(exchange.rows.map(\.speaker) == ["a","b","a"])
    }
    @Test func crosstalkRequiresEveryOwnWordAndContinuationKeepsTime() {
        var input = [w("a",0,100,"One"),w("a",100,200,"two."),w("a",5000,5100,"Three.")]
        input[0].lowConfidenceSpeaker = true
        input[1].lowConfidenceSpeaker = true
        let rows = TranscriptRendering.render(input).rows
        #expect(rows.count == 2 && rows.map(\.crosstalk) == [true,false])
        #expect(rows.map(\.continuation) == [false,true])
        #expect(rows[1].startMs == 5000)
        input[1].lowConfidenceSpeaker = false
        #expect(!TranscriptRendering.render(input).rows[0].crosstalk)
    }

    @Test func manifestAttestationRequiresLiteralTrue() throws {
        let url = try #require(Bundle.module.url(forResource:"001-minimal-v1",withExtension:"opus",subdirectory:"LibraryVectors/assets"))
        var file = try CassiniReader.read(Data(contentsOf:url))
        let original = try #require(file.manifest)
        let values: [JSON?] = [nil,.null,.object([]),.object([("wordTimings",.null)]),.object([("wordTimings",.object([]))])] +
            [JSON.bool(true),.bool(false),.string("true"),.number("1"),.null].map {
                .object([("wordTimings",.object([("endsBoundedByAudio",$0)]))])
            }
        for (index,provenance) in values.enumerated() {
            var members = try #require(original.raw.object).filter { $0.0 != "provenance" }
            if let provenance { members.append(("provenance",provenance)) }
            let manifest = try ManifestParser.parse(.object(members),formatMajor:1)
            let expected = index == 5
            #expect(manifest.wordEndsBoundedByAudio == expected)
            #expect(TranscriptRendering.endsBoundedByAudio(provenance:provenance) == expected)
            file.manifest = manifest
            let meeting = MeetingPresentation.external(file,url:url)
            #expect(meeting.wordEndsBoundedByAudio == expected)
            let rendered = TranscriptRendering.render([w("a",0,5000,"Measured．")],endsBoundedByAudio:meeting.wordEndsBoundedByAudio)
            #expect(rendered.words[0].endMs == (expected ? 5000 : 1000))
        }
    }
    @Test(arguments:["Word．","Word．」","Ⅻ．","²．","語．"])
    func fullwidthStopRepairsWordAndNumberCategories(_ text: String) {
        let input = [w("a",0,5000,text)]
        let repaired = TranscriptRendering.render(input)
        #expect(repaired.words[0].endMs == 1000)
        #expect(repaired.words[0].text == text)
        #expect(TranscriptRendering.render(input,endsBoundedByAudio:true).words == input)
    }
    @Test func zeroDurationWordsHaveNoAudibleOverlapOrNesting() {
        let examples = [
            [w("a",0,1000,"Host"),w("b",100,100,"um"),w("b",500,500,"uh")],
            [w("a",0,100,"Before"),w("b",100,100,"um"),w("a",200,1000,"after"),w("b",500,500,"uh")]
        ]
        for input in examples {
            let result = TranscriptRendering.render(input)
            #expect(result.rows.allSatisfy { $0.over.isEmpty && $0.members.allSatisfy { $0.kind == "words" } })
            #expect(result.runs.filter { $0.speaker == "b" }.allSatisfy { $0.host == nil && $0.blocks.count == 1 })
            #expect(result.rows.flatMap(\.members).flatMap(\.wordIndices).sorted() == Array(input.indices))
        }
    }
    @Test func equalOverlapUsesCanonicalRightRunOrder() {
        // B's zero-duration lead sorts its block before C, but its first sound
        // comes after C. Equal collisions still use canonical B/C run order.
        let input = [w("a",0,3000,"Host"),w("b",100,100,"lead"),w("b",1000,1500,"Later"),w("c",200,700,"Earlier")]
        let result = TranscriptRendering.render(input,endsBoundedByAudio:true)
        #expect(result.rows.first?.over == ["b","c"])
    }
    @Test func hostSearchPreservesLastBlockPositionWhenAudibleStartsReorder() throws {
        let input = [w("a",0,0,"lead"),w("a",1000,1100,"first"),
                     w("c",100,100,"lead"),w("c",1050,1080,"touch"),
                     w("a",200,200,"lead"),w("a",900,1000,"second"),
                     w("b",1050,1080,"aside"),w("a",1100,1500,"third")]
        let result = TranscriptRendering.render(input,endsBoundedByAudio:true)
        let host = try #require(result.runs.first { $0.speaker == "a" })
        let aside = try #require(result.runs.first { $0.speaker == "b" })
        #expect(host.blocks.count == 3)
        #expect(aside.host == host.id && aside.afterBlock == host.blocks[1])
    }
    @Test func elevenHourPresenterWithBackchannelsAndCompetingRemarksIsBounded() throws {
        let seconds = 11*60*60
        var input: [TranscriptRendering.Word] = []
        input.reserveCapacity(seconds*4)
        for second in 0..<seconds {
            let t = Int64(second)*1000
            input.append(w("presenter",t,t+480,"word"))
            input.append(w("presenter",t+500,t+980,"word"))
            if second < seconds-1 { input.append(w("listener",t+900,t+1100,"Yes.")) }
            if second.isMultiple(of:10) { input.append(w("competing",t+200,t+2600,"remark")) }
        }
        input = input.enumerated().sorted { $0.element.startMs == $1.element.startMs ? $0.offset < $1.offset : $0.element.startMs < $1.element.startMs }.map(\.element)
        let clock = ContinuousClock()
        let began = clock.now
        // Repair is enabled: this also guards the former per-word regex cost.
        let result = TranscriptRendering.render(input)
        let elapsed = began.duration(to:clock.now)
        #expect(elapsed < .seconds(15),"11-hour render exceeded its generous debug-build bound: \(elapsed)")
        let host = try #require(result.runs.first { $0.speaker == "presenter" })
        #expect(host.blocks.count >= seconds)
        let backchannels = result.runs.filter { $0.speaker == "listener" }
        #expect(backchannels.count == seconds-1 && backchannels.allSatisfy { $0.host == host.id })
        let competing = result.runs.filter { $0.speaker == "competing" }
        #expect(competing.count == seconds/10 && competing.allSatisfy { $0.host == nil && $0.over.contains("presenter") })
        #expect(result.rows.first?.over == ["competing"])
        let rendered = result.rows.flatMap(\.members).flatMap(\.wordIndices)
        #expect(rendered.count == input.count && Set(rendered).count == input.count)
        #expect(result.words == input,"Measured spans and stored text are unchanged")
        print("D84 eleven-hour render: \(input.count) words, \(elapsed)")
    }

    @Test(arguments:[true,false]) func embeddedAttestationSurvivesReadAndImport(_ attested: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D84-Provenance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let asset = try #require(Bundle.module.url(forResource:"001-minimal-v1",withExtension:"opus",subdirectory:"LibraryVectors/assets"))
        let base = try Data(contentsOf:asset)
        let original = try CassiniReader.read(base)
        var manifest = try #require(original.manifest?.raw)
        manifest = try manifest.setting("provenance",to:.object([("wordTimings",.object([("endsBoundedByAudio",.bool(attested))]))]))
        let speaker = try #require(original.manifest?.speakers.first?.id)
        let body = try JSONSerialization.data(withJSONObject:["items":[["speaker":speaker,"startMs":0,"endMs":5000,"text":"Measured．"]]])
        let source = root.appendingPathComponent("Measured.opus")
        _ = try OpusStreamFile.rewrite(base,tags:PortableMeetingTags.make(manifest:manifest,transcript:body,wordCount:1),to:source)
        let file = try CassiniReader.read(contentsOf:source)
        #expect(file.state == .ok && file.manifest?.wordEndsBoundedByAudio == attested)
        #expect(MeetingPresentation.external(file,url:source).wordEndsBoundedByAudio == attested)
        let library = root.appendingPathComponent("Imported")
        let imported = try LibraryImport.copy(source,into:library)
        #expect(imported.state.transcript == .done && imported.wordEndsBoundedByAudio == attested)
        // An unrelated sidecar transcription cannot inherit the original's flag.
        try body.write(to:imported.folder.appendingPathComponent("transcript.json"))
        try MeetingMetadataWriter(directory:imported.folder,id:imported.id).transaction {
            $0["transcript"] = ["status":"done","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]]
        }
        let sidecar = try #require(LibraryScanner(root:library).scan().meetings.first)
        #expect(sidecar.state.transcript == .done && !sidecar.wordEndsBoundedByAudio)
    }

    @Test func asideBeforeLegacyRunStartUsesAudibleHostAdmission() throws {
        let input = [w("s1",0,0,"um"),w("s1",1000,1150,"first"),w("c",950,1020,"touch"),
                     w("s1",800,950,"second"),w("b",960,990,"aside"),w("s1",1020,1500,"third")]
        let result = TranscriptRendering.render(input,endsBoundedByAudio:true)
        let host = try #require(result.runs.first { $0.speaker == "s1" })
        let aside = try #require(result.runs.first { $0.speaker == "b" })
        #expect(host.startMs == 1000,"Display/run ordering retains the viewer's legacy start")
        #expect(aside.host == host.id && aside.afterBlock == host.blocks[1])
        #expect(!result.rows.contains { $0.speaker == "b" })
        #expect(result.rows.flatMap(\.members).contains { $0.kind == "interjection" && $0.speaker == "b" && $0.wordIndices == [4] })
    }
    @Test func audibleOverlapBeforeLegacyRunStartIsNotEvicted() throws {
        let input = [w("s1",0,0,"um"),w("s1",1000,1150,"first"),w("b",700,1000,"competing"),w("s1",800,1000,"second")]
        let result = TranscriptRendering.render(input,endsBoundedByAudio:true)
        let host = try #require(result.runs.first { $0.speaker == "s1" })
        #expect(host.startMs == 1000)
        #expect(result.rows.first { $0.speaker == "s1" }?.over == ["b"])
        #expect(result.rows.first { $0.speaker == "b" }?.over == ["s1"])
        #expect(result.rows.flatMap(\.members).flatMap(\.wordIndices).sorted() == Array(input.indices))
    }

}
