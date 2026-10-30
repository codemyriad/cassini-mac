// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Testing
@testable import CassiniLibrary

struct ExportGoldenTests {
    private func input(_ name: String, sha: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource:name,withExtension:"json",subdirectory:"ExportGolden"))
        let data = try Data(contentsOf:url)
        #expect(SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() == sha)
        return data
    }
    @Test func markdownMatchesBothPublishedCasesByteForByte() throws {
        struct Cases: Decodable {
            struct Case: Decodable {
                struct Input: Decodable {
                    struct Speaker: Decodable { let id: String; let name: String }
                    let title: String; let startMs: Int64; let tz: String; let durationMs: Int64?
                    let speakers: [Speaker]; let items: [LibraryTranscriptItem]; let notes: [MeetingNote]
                }
                let name: String; let input: Input; let expected: String
            }
            let cases: [Case]
        }
        let values = try JSONDecoder().decode(Cases.self,from:input("markdown-cases",sha:"16541a9fc08815064000fc935c0d2d0e4b1933c8bbf2d7046232e1a8882bd5da"))
        #expect(values.cases.count == 2)
        for value in values.cases {
            let v = value.input
            let text = MeetingMarkdown.render(title:v.title,start:Date(timeIntervalSince1970:Double(v.startMs)/1000),durationMs:v.durationMs,
                timeZone:try #require(TimeZone(identifier:v.tz)),names:Dictionary(uniqueKeysWithValues:v.speakers.map { ($0.id,$0.name) }),items:v.items,notes:v.notes,locale:Locale(identifier:"en_GB"))
            #expect(Data(text.utf8) == Data(value.expected.utf8),"\(value.name)")
        }
    }
    @Test func everyPublishedEncodeChoiceMatches() throws {
        struct Cases: Decodable {
            struct Vector: Decodable { let name: String; let sources: [AudioEncodeSource]; let bitrateBps: Int; let cutoffHz: Int }
            let vectors: [Vector]
        }
        let values = try JSONDecoder().decode(Cases.self,from:input("export-vectors",sha:"698e445c11c1c81c333f54074efd6770a06bbb353559db6527d5c115b8cc30ba"))
        #expect(values.vectors.count == 15)
        for vector in values.vectors {
            let choice = AudioEncodeChoice.choose(vector.sources)
            #expect(choice.bitrateBps == vector.bitrateBps,"\(vector.name)")
            #expect(choice.cutoffHz == vector.cutoffHz,"\(vector.name)")
            #expect(choice.policy == "match-source" && choice.application == "audio")
        }
    }
    @Test func speechRateDoesNotAverageSilentFramesIntoSpeech() {
        #expect(AudioEncodeChoice.speechBitrate(histogram:[1200:100,32000:50]) == 32000)
        #expect(AudioEncodeChoice.speechBitrate(histogram:[64000:49]) == nil)
        #expect(AudioEncodeChoice.speechBitrate(histogram:[24000:50]) == 24000)
    }
    @Test func filenamesAndMarkdownCannotCreateExtraBlocksOrPaths() {
        #expect(MeetingMarkdown.filename(title:"   ") == "Untitled meeting.md")
        #expect(MeetingMarkdown.filename(title:"a/b\\c\u{0}d",collision:2) == "a-b-c-d 2.md")
        #expect(MeetingMarkdown.filename(title:String(repeating:"界",count:121)).dropLast(3).count == 120)
        #expect(MeetingMarkdown.escape("  # Head\n\ttext ") == "\\# Head text")
        let slash = String(Unicode.Scalar(92)!)
        #expect(MeetingMarkdown.escape("42. text *bold* [link]") == "42" + slash + ". text " + slash + "*bold" + slash + "* " + slash + "[link" + slash + "]")
        #expect(MeetingMarkdown.escape(slash) == slash + slash)
    }
}
