// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniLibrary

@Suite struct D70SpeakerRowTests {
    private let locale = Locale(identifier:"en_GB")
    private func row(_ words: [LibraryTranscriptItem], percent: Int = 0, provenance: NameProvenance? = .unnamed,
                     language: CassiniLanguage = .en) -> SpeakerRowPresentation {
        .init(speaker:.init(id:"voice",name:provenance == .user ? "Claire Lee" : nil,provenance:provenance,colourIndex:0),
              turns:SpeakerTurn.grouping(words).filter { $0.speaker == "voice" },percent:percent,language:language,locale:locale)
    }
    @Test func captionCountsListeningRunsRatherThanReadingParagraphs() {
        let words: [LibraryTranscriptItem] = [.init(speaker:"voice",startMs:1518000,endMs:1518300,text:"Yes."),
            .init(speaker:"voice",startMs:1600000,endMs:1600500,text:"Still here."),
            .init(speaker:"other",startMs:1700000,endMs:1701000,text:"Next."),
            .init(speaker:"voice",startMs:1800000,endMs:1800500,text:"Agreed.")]
        let presentation = row(words)
        #expect(presentation.caption == "Not named yet · 2 times, first at 00:25:18")
        #expect(presentation.playAccessibilityLabel == "Play this speaker’s turns: Speaker 1, 2 times, first at 00:25:18")
        #expect(presentation.share == "< 1%")
        #expect(row(Array(words.prefix(2))).when == "once, at 00:25:18","long pauses do not split listening turns")
        #expect(row(words,percent:7).share == "7%")
        let merged = SpeakerMerges.apply(words,SpeakerMerges.resolve([.init(from:"other",into:"voice")],known:["other","voice"]))
        #expect(row(merged).when == "once, at 00:25:18","merge refresh uses the resolved turn count")
    }
    @Test func absentAndZeroLengthVoicesNeverClaimSmallPositiveShareOrInventATime() {
        let absent = row([])
        #expect(absent.caption == "Not named yet" && absent.when == nil && absent.share == "0%")
        #expect(row([.init(speaker:"voice",startMs:1000,endMs:1000,text:"Point.")]).share == "0%")
        let legacy = row([.init(speaker:"voice",startMs:1000,endMs:1300,text:"Yes.")],provenance:.source)
        #expect(legacy.caption == "once, at 00:00:01" && !legacy.accessibilityLabel.contains(", ,"))
    }
    @Test func sharedEnglishVectorDistinguishesAllEightOneTurnVoices() throws {
        struct Vector: Decodable { let items: [LibraryTranscriptItem] }
        let path = try #require(Bundle.module.url(forResource:"turns",withExtension:"json",subdirectory:"Golden/listen-by-speaker"))
        let turns = SpeakerTurn.grouping(try JSONDecoder().decode(Vector.self,from:Data(contentsOf:path)).items)
        let grouped = Dictionary(grouping:turns,by: \.speaker).filter { $0.value.count == 1 }
        let labels = grouped.map { id, turns in
            SpeakerRowPresentation(speaker:.init(id:id,name:nil,provenance:.unnamed,colourIndex:0,label:"Unidentified voice"),
                                   turns:turns,percent:0,language:.en,locale:locale).playAccessibilityLabel
        }
        #expect(labels.count == 8 && Set(labels).count == 8)
        #expect(labels.allSatisfy { $0.contains("once, at 00:") && !$0.contains("{") })
    }
    @Test func allSixLanguagesUseSharedCaptionAndPlayCopy() {
        let words: [LibraryTranscriptItem] = [.init(speaker:"voice",startMs:1000,endMs:1300,text:"Yes.")]
        for language in CassiniLanguage.allCases {
            let presentation = row(words,provenance:.user,language:language)
            #expect(presentation.when?.contains("00:00:01") == true)
            #expect(presentation.caption?.contains(" · ") == true)
            #expect(presentation.playAccessibilityLabel.contains("Claire Lee"))
            #expect(!presentation.playAccessibilityLabel.contains("{"))
        }
    }
}
