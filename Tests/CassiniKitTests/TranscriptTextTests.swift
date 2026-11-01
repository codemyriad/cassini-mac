// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import CassiniKit

struct TranscriptTextTests {
    @Test func quotesPairAcrossWordBoundariesAndDropOnlyTheUnpairedLastMark() {
        #expect(TranscriptText.quotes(["He", "said", "\"hello", "there\".", "Then\""]) == ["He","said","“hello","there”.","Then"])
        #expect(TranscriptText.quotes(["\"alone"]) == ["alone"])
        #expect(TranscriptText.quotes(["No quotes", "‘apostrophes’", "“already curly”"]) == ["No quotes", "‘apostrophes’", "“already curly”"])
        #expect(TranscriptText.quotes(["\"one\" then \"two\" and \""]) == ["“one” then “two” and "])
    }
}

/// D53.2: an unknown recognizer language is written as "und", never "auto" or "".
struct D53TranscriptLanguageTests {
    @Test func unknownLanguageIsWrittenAsUnd() {
        #expect(TranscriptLanguage.written(nil) == "und")
        #expect(TranscriptLanguage.written("auto") == "und")
        #expect(TranscriptLanguage.written("") == "und")
        #expect(TranscriptLanguage.written("it-IT") == "it-IT")
        #expect(TranscriptLanguage.written("en") == "en")
    }
}
