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
    @Test func markdownMatchesAllPublishedCasesWithNativeDateLines() throws {
        struct Cases: Decodable {
            struct Case: Decodable {
                struct Input: Decodable {
                    struct Speaker: Decodable { let id: String; let name: String }
                    let title: String; let startMs: Int64; let tz: String; let durationMs: Int64?; let uiLanguage: String?
                    let speakers: [Speaker]; let items: [LibraryTranscriptItem]; let notes: [MeetingNote]
                }
                let name: String; let input: Input; let expected: String
            }
            let cases: [Case]
        }
        let values = try JSONDecoder().decode(Cases.self,from:input("markdown-cases",sha:"3e4bfb01771e3f82a5d289026915454a8e17dc75095cfe4f9bbf6a16b06d7d3e"))
        #expect(values.cases.count == 4)
        for value in values.cases {
            let v = value.input
            let language=CassiniLanguage(languageTag:v.uiLanguage ?? "en")
            let locale=Locale(identifier:v.uiLanguage ?? "en_GB")
            let zone=try #require(TimeZone(identifier:v.tz))
            let start=Date(timeIntervalSince1970:Double(v.startMs)/1000)
            let text = MeetingMarkdown.render(title:v.title,start:Date(timeIntervalSince1970:Double(v.startMs)/1000),durationMs:v.durationMs,
                timeZone:zone,names:Dictionary(uniqueKeysWithValues:v.speakers.map { ($0.id,$0.name) }),items:v.items,notes:v.notes,locale:locale,language:language)
            var expected=value.expected
            if v.uiLanguage != nil {
                let day=DateFormatter();day.locale=locale;day.timeZone=zone;day.dateStyle = .full;day.timeStyle = .none
                let time=DateFormatter();time.locale=locale;time.timeZone=zone;time.dateStyle = .none;time.timeStyle = .short
                // Published localized fixtures both have 52 min. Only their
                // platform date/time is variable; all other bytes are frozen.
                #expect(v.durationMs==3120000)
                let dateLine=day.string(from:start)+", "+time.string(from:start)+" · 52 min"
                expected=expected.replacingOccurrences(of:"{DATE_LINE}",with:dateLine)
            }
            #expect(Data(text.utf8) == Data(expected.utf8),"\(value.name)")
        }
    }
    @Test func unknownTitlesUseTheSelectedDocumentLanguage() {
        for language in CassiniLanguage.allCases {
            let title=LibraryLocalization.shared.text("library.untitled",language:language)
            #expect(MeetingMarkdown.filename(title:"  ",language:language)==title+".md")
            let text=MeetingMarkdown.render(title:"  ",start:nil,durationMs:nil,timeZone:TimeZone(secondsFromGMT:0)!,names:[:],items:[],notes:[],language:language)
            #expect(text.hasPrefix("# "+title+"\n\n"))
            #expect(!text.contains("Speakers:"))
            #expect(!text.contains("{DATE_LINE}"))
        }
    }
    @Test func markdownDateAndHeadingsUseFrenchWithAmericanRegionalSettings() {
        let start=Date(timeIntervalSince1970:0),zone=TimeZone(secondsFromGMT:0)!,french=Locale(identifier:"fr")
        let day=DateFormatter();day.locale=french;day.timeZone=zone;day.dateStyle = .full;day.timeStyle = .none
        let time=DateFormatter();time.locale=french;time.timeZone=zone;time.dateStyle = .none;time.timeStyle = .short
        let text=MeetingMarkdown.render(title:"Stored title",start:start,durationMs:nil,timeZone:zone,names:["a":"Speaker 7"],items:[.init(speaker:"a",startMs:0,endMs:100,text:"Stored words")],notes:[],locale:Locale(identifier:"en_US"),language:.fr)
        #expect(text.contains(day.string(from:start)+", "+time.string(from:start)))
        #expect(text.contains("Intervenants\u{a0}: Speaker 7"))
        #expect(text.contains("## Transcription"))
        #expect(text.contains("**Speaker 7** · 00:00:00\nStored words"))
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
        #expect(MeetingMarkdown.filename(title:"   ",language:.en) == "Untitled meeting.md")
        #expect(MeetingMarkdown.filename(title:"a/b\\c\u{0}d",collision:2) == "a-b-c-d 2.md")
        #expect(MeetingMarkdown.filename(title:String(repeating:"界",count:121)).dropLast(3).count == 120)
        #expect(MeetingMarkdown.escape("  # Head\n\ttext ") == "\\# Head text")
        let slash = String(Unicode.Scalar(92)!)
        #expect(MeetingMarkdown.escape("42. text *bold* [link]") == "42" + slash + ". text " + slash + "*bold" + slash + "* " + slash + "[link" + slash + "]")
        #expect(MeetingMarkdown.escape(slash) == slash + slash)
    }
}
