// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CassiniLibrary
@testable import CassiniTranscription

final class TranscriptProgressTests: XCTestCase {
    private func word(_ text: String, _ start: Int64, _ end: Int64, speaker: String = "me") -> LibraryTranscriptItem {
        .init(speaker:speaker,startMs:start,endMs:end,text:text)
    }
    func testBoundaryOverhangAndRoundingNeverDuplicateAcrossRepeatedResumes() {
        let crossing = word("crossing",900,1800), boundary = word("boundary",1000,1100), tail = word("tail",3000,3500)
        let fresh = [crossing,boundary].enumerated().map { TranscriptProgress.Item(word:$0.element,track:0,ordinal:$0.offset) }
        var saved = [crossing,boundary,tail]
        for _ in 0..<5 {
            var progress = TranscriptProgress(previous:saved,speakers:["me"])
            XCTAssertEqual(progress.published([]),saved)
            progress.advance(track:0,to:1000)
            saved = progress.published(fresh)
            XCTAssertEqual(saved,[crossing,boundary,tail])
        }
    }
    func testSharedSpeakerWaitsForEveryTrackAndPreservesItsUnprocessedTail() {
        let first = word("first track",0,1800), second = word("second track",100,200), tail = word("later",3000,3400)
        let fresh = [TranscriptProgress.Item(word:first,track:0,ordinal:0),.init(word:second,track:1,ordinal:1)]
        var saved = [first,second,tail]
        for _ in 0..<5 {
            var progress = TranscriptProgress(previous:saved,speakers:["me","me"])
            progress.advance(track:0,to:2000); progress.finish(track:0)
            XCTAssertEqual(progress.published([fresh[0]]),saved,"The other track has not been re-recognised")
            progress.advance(track:1,to:1000)
            saved = progress.published(fresh)
            XCTAssertEqual(saved,[first,second,tail])
        }
        var complete = TranscriptProgress(previous:saved,speakers:["me","me"])
        complete.finish(track:0); complete.finish(track:1)
        XCTAssertEqual(complete.published(fresh),[first,second])
        XCTAssertEqual(complete.published(fresh,complete:true),[first,second])
    }
    func testFreshSpeakersPublishImmediatelyAndCompletedSilentTracksReleaseTheirGroup() {
        let old = word("old",400,500), other = word("other",0,100,speaker:"others")
        var progress = TranscriptProgress(previous:[old],speakers:["me","me","others"])
        XCTAssertEqual(progress.published([.init(word:other,track:2,ordinal:0)]),[other,old])
        progress.finish(track:0); progress.finish(track:1)
        XCTAssertEqual(progress.published([.init(word:other,track:2,ordinal:0)]),[other])
    }
}
