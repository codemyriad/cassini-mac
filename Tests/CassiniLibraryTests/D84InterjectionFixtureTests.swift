// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
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

}
