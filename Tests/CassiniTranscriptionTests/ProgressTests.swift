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
    func testSpeakerMetadataPreservesEstablishedSlotsAcrossPartialsResumeAndRetries() {
        let tracks: [TranscriptSpeaker] = [
            .init(id: "track-later", name: nil),
            .init(id: "track-earlier", name: nil),
            .init(id: "track-silent", name: nil),
        ]
        // Initial running publish before any words: unspoken tracks do not grab slots prematurely.
        let p0 = MeetingTranscriber.updatedSpeakerMetadata(existing: [], tracks: tracks, ordered: [], status: "running", uiLanguage: .en)
        XCTAssertTrue(p0.isEmpty)

        // Partial 1: track-later speaks first at 30 s and receives slot 0.
        let p1 = MeetingTranscriber.updatedSpeakerMetadata(
            existing: p0,
            tracks: tracks,
            ordered: [word("Hello", 30_000, 30_400, speaker: "track-later")],
            status: "running",
            uiLanguage: .en
        )
        XCTAssertEqual(p1.count, 1)
        XCTAssertEqual(p1[0]["id"] as? String, "track-later")
        XCTAssertEqual(p1[0]["colourIndex"] as? Int, 0)
        XCTAssertEqual(p1[0]["label"] as? String, "Speaker 1")

        // Partial 2: track-earlier arrives at 0 ms. track-later keeps slot 0; track-earlier gets slot 1,
        // while unnamed labels update to speaking order ("Speaker 1" for earlier, "Speaker 2" for later).
        let p2 = MeetingTranscriber.updatedSpeakerMetadata(
            existing: p1,
            tracks: tracks,
            ordered: [
                word("First", 0, 400, speaker: "track-earlier"),
                word("Hello", 30_000, 30_400, speaker: "track-later"),
            ],
            status: "running",
            uiLanguage: .en
        )
        let byID2 = Dictionary(uniqueKeysWithValues: p2.compactMap { entry in (entry["id"] as? String).map { ($0, entry) } })
        XCTAssertEqual(byID2["track-later"]?["colourIndex"] as? Int, 0)
        XCTAssertEqual(byID2["track-earlier"]?["colourIndex"] as? Int, 1)
        XCTAssertEqual(byID2["track-earlier"]?["label"] as? String, "Speaker 1")
        XCTAssertEqual(byID2["track-later"]?["label"] as? String, "Speaker 2")
        XCTAssertNil(byID2["track-silent"])

        // Final publish ("done"): silent track gets the next unused slot (2) without shifting 0 or 1.
        let done = MeetingTranscriber.updatedSpeakerMetadata(
            existing: p2,
            tracks: tracks,
            ordered: [
                word("First", 0, 400, speaker: "track-earlier"),
                word("Hello", 30_000, 30_400, speaker: "track-later"),
            ],
            status: "done",
            uiLanguage: .en
        )
        let byIDDone = Dictionary(uniqueKeysWithValues: done.compactMap { entry in (entry["id"] as? String).map { ($0, entry) } })
        XCTAssertEqual(byIDDone["track-later"]?["colourIndex"] as? Int, 0)
        XCTAssertEqual(byIDDone["track-earlier"]?["colourIndex"] as? Int, 1)
        XCTAssertEqual(byIDDone["track-silent"]?["colourIndex"] as? Int, 2)

        // Retry against existing nonsequential slots (e.g. from another platform or prior edit):
        // existing slots [5, 2] and custom speaker keys survive intact; new speakers take unused slots [0, 1].
        let nonsequentialExisting: [[String: Any]] = [
            ["id": "a", "name": "Ada", "provenance": "user", "colourIndex": 5, "customField": "keep"],
            ["id": "unspoken-prev", "name": "Zoe", "provenance": "user", "colourIndex": 2],
        ]
        let retryTracks: [TranscriptSpeaker] = [
            .init(id: "b", name: nil),
            .init(id: "a", name: "Me"),
            .init(id: "d", name: "The others"),
        ]
        let retryRunning = MeetingTranscriber.updatedSpeakerMetadata(
            existing: nonsequentialExisting,
            tracks: retryTracks,
            ordered: [
                word("Lead", 100, 300, speaker: "b"),
                word("Reply", 500, 800, speaker: "a"),
            ],
            status: "running",
            uiLanguage: .en
        )
        let retryDone = MeetingTranscriber.updatedSpeakerMetadata(
            existing: retryRunning,
            tracks: retryTracks,
            ordered: [
                word("Lead", 100, 300, speaker: "b"),
                word("Reply", 500, 800, speaker: "a"),
            ],
            status: "done",
            uiLanguage: .en
        )
        let retryByID = Dictionary(uniqueKeysWithValues: retryDone.compactMap { entry in (entry["id"] as? String).map { ($0, entry) } })
        XCTAssertEqual(retryByID["a"]?["colourIndex"] as? Int, 5)
        XCTAssertEqual(retryByID["a"]?["name"] as? String, "Ada")
        XCTAssertEqual(retryByID["a"]?["customField"] as? String, "keep")
        XCTAssertEqual(retryByID["unspoken-prev"]?["colourIndex"] as? Int, 2)
        XCTAssertEqual(retryByID["b"]?["colourIndex"] as? Int, 0)
        XCTAssertEqual(retryByID["b"]?["label"] as? String, "Speaker 1")
        XCTAssertEqual(retryByID["d"]?["colourIndex"] as? Int, 1)
    }
}
