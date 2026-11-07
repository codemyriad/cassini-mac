// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniLibrary

@Suite struct D70ListeningBarTests {
    private let locale = Locale(identifier:"en_GB")
    @Test func contextIsBoundedAndSeparatesTheLeadInSpeaker() {
        var words: [LibraryTranscriptItem] = []
        for index in 0..<12 {
            let start = Int64(index)*100
            words.append(.init(speaker:"sam",startMs:start,endMs:start+90,text:"before\(index)"))
        }
        for index in 0..<15 {
            let start = Int64(1518000)+Int64(index)*100
            words.append(.init(speaker:"claire",startMs:start,endMs:start+90,text:"after\(index)"))
        }
        let turns = SpeakerTurn.grouping(words)
        let bar = ListeningBarPresentation(name:"Claire Lee",turn:turns[1],previous:turns[0],index:2,count:4,firstStartMs:62000,language:.en,locale:locale)
        #expect(bar.label == "Turn 3 of 4 · 00:25:18")
        #expect(bar.announcement == "Turn 3 of 4, 00:25:18")
        #expect(bar.speakerAnnouncement == "Claire Lee, 4 times, first at 00:01:02")
        #expect(bar.accessibilityLabel == "Listening to Claire Lee")
        #expect(bar.previousExcerpt == "before7 before8 before9 before10 before11")
        #expect(bar.currentExcerpt == "after0 after1 after2 after3 after4 after5 after6 after7")
    }
    @Test func legacyMultiwordItemsStillLimitExcerptsByWords() {
        let turns = SpeakerTurn.grouping([.init(speaker:"sam",startMs:0,endMs:900,text:"zero one two three four five six seven eight nine"),
            .init(speaker:"claire",startMs:1000,endMs:2000,text:"One two three four five six seven eight nine ten.")])
        let bar = ListeningBarPresentation(name:"Claire",turn:turns[1],previous:turns[0],index:0,count:1,firstStartMs:turns[1].startMs,language:.en,locale:locale)
        #expect(bar.previousExcerpt == "five six seven eight nine")
        #expect(bar.currentExcerpt == "One two three four five six seven eight")
    }
    @Test func firstTurnAndAsideKeepTheirOwnContextAndClock() {
        let turns = SpeakerTurn.grouping([.init(speaker:"claire",startMs:0,endMs:900,text:"Hello."),
            .init(speaker:"guest",startMs:300,endMs:600,text:"Yes."),.init(speaker:"claire",startMs:700,endMs:1000,text:"Thanks.")])
        let first = ListeningBarPresentation(name:"Claire Lee",turn:turns[0],previous:nil,index:0,count:2,firstStartMs:0,language:.en,locale:locale)
        #expect(first.previousExcerpt.isEmpty && first.currentExcerpt == "Hello.")
        let aside = ListeningBarPresentation(name:"Unidentified voice",turn:turns[1],previous:turns[0],index:0,count:1,firstStartMs:300,language:.en,locale:locale)
        #expect(aside.speakerAnnouncement == "Unidentified voice, once, at 00:00:00")
        #expect(aside.label == "Turn 1 of 1 · 00:00:00")
        #expect(aside.previousExcerpt == "Hello." && aside.currentExcerpt == "Yes.")
    }
    @Test func allLanguagesKeepNamesVerbatimAndResolveCounterAndAnnouncements() {
        let turn = SpeakerTurn.grouping([.init(speaker:"claire",startMs:1518000,endMs:1518300,text:"Agreed.")])[0]
        for language in CassiniLanguage.allCases {
            for count in [1,4] {
                let bar = ListeningBarPresentation(name:"Claire {name}",turn:turn,previous:nil,index:0,count:count,firstStartMs:62000,language:language,locale:locale)
                let when = LibraryLocalization.shared.text(count == 1 ? "speakers.when.once" : "speakers.when.times",
                    ["position":"00:01:02","count":String(count),"n":String(count)],language:language,locale:locale)
                #expect(bar.speakerAnnouncement == "Claire {name}, " + when)
                #expect(!when.contains("{") && !when.contains("00:25:18"))
                #expect(bar.accessibilityLabel.contains("Claire {name}"))
                #expect(bar.label.contains("00:25:18") && bar.announcement.contains("00:25:18"))
                #expect(!bar.label.contains("{") && !bar.announcement.contains("{"))
            }
        }
    }
}
