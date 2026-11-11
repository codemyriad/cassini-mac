// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Testing
import CassiniLibrary
import CassiniKit
@testable import CassiniSearch

private final class SearchFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniSearchTest-" + UUID().uuidString)
    var root: URL { directory.appendingPathComponent("trees/main/root") }
    var cache: URL { directory.appendingPathComponent("Caches/Search") }
    let now = Date(timeIntervalSince1970:1793107080)
    let zone = TimeZone(identifier:"Europe/Rome")!
    init() throws {
        let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vectors = repository.appendingPathComponent("Tests/CassiniLibraryTests/LibraryVectors")
        let pin = try JSONSerialization.jsonObject(with:Data(contentsOf:vectors.appendingPathComponent("UPSTREAM.json"))) as! [String:Any]
        for (name,hash) in pin["sha256"] as! [String:String] {
            #expect(SHA256.hash(data:try Data(contentsOf:vectors.appendingPathComponent(name))).map { String(format:"%02x",$0) }.joined() == hash)
        }
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/env")
        process.arguments = ["python3",vectors.appendingPathComponent("make.py").path,directory.appendingPathComponent("trees").path]
        process.standardOutput = FileHandle.nullDevice; try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw POSIXError(.EIO) }
    }
    deinit { try? FileManager.default.removeItem(at:directory) }
    func meetings() throws -> [LibraryMeeting] { try LibraryScanner(root:root).scan(now:now).meetings }
    func bytes() throws -> [String:Data] {
        let enumerator = FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey])!
        var result: [String:Data] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {
            result[url.path] = Data(SHA256.hash(data:try Data(contentsOf:url)))
        }
        return result
    }
}

struct SearchTests {
    @Test func recordingLabelsAndUnknownTimesRefreshWithoutChangingTranscriptCache() async throws {
        let fixture = try SearchFixture()
        var meeting = try #require(fixture.meetings().first { $0.transcriptItems.contains { $0.text.lowercased().contains("budget") } })
        let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var info = try #require(CassiniReader.read(contentsOf:repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/028-date-is-created-at.opus")).manifest?.meeting)
        info.recordedAtLocal = "2026-11-09T00:15:00"
        meeting.start = nil; meeting.recordedTime = MeetingTime.resolve(meeting:info,dateTag:info.createdAtUtc)
        let now = try #require(MeetingTime.parseInstant("2026-11-08T23:30:00Z"))
        let index = try SearchIndex(cache:fixture.cache)
        try await index.replace([meeting])
        #expect(try await !index.search("budget",filter:.init(date:.today),now:now,timeZone:fixture.zone).isEmpty)
        info.recordedAtLocal = "2026-11-08T00:15:00"
        meeting.recordedTime = MeetingTime.resolve(meeting:info,dateTag:info.createdAtUtc)
        try await index.replace([meeting])
        #expect(try await index.search("budget",filter:.init(date:.today),now:now,timeZone:fixture.zone).isEmpty)
        meeting.recordedTime = nil; meeting.sortingFallback = now
        try await index.replace([meeting])
        #expect(try await index.search("budget",filter:.init(date:.today),now:now,timeZone:fixture.zone).isEmpty)
        #expect(try await !index.search("budget",now:now,timeZone:fixture.zone).isEmpty)
    }
    @Test func sharedMainHasFourPlacesInThreeMeetingsInD14OrderWithoutWritingTheLibrary() async throws {
        let fixture = try SearchFixture(), before = try fixture.bytes(), meetings = try fixture.meetings()
        let index = try SearchIndex(cache:fixture.cache); try await index.replace(meetings)
        let hits = try await index.search("budget",filter:.init(speaker:"Marta"),now:fixture.now,timeZone:fixture.zone)
        #expect(hits.count == 4 && Set(hits.map(\.meetingKey)).count == 3)
        #expect(hits.map(\.positionMs) == [4000,872000,1870000,527000])
        #expect(hits.prefix(2).allSatisfy { hit in meetings.first(where:{ $0.libraryKey == hit.meetingKey })?.title == "Budget review" })
        #expect(hits.allSatisfy { $0.text.contains("budget") && !$0.spans.isEmpty })
        #expect(try fixture.bytes() == before)
        #expect(FileManager.default.fileExists(atPath:fixture.cache.appendingPathComponent("transcripts.sqlite").path))
        #expect(try await index.search("budget",filter:.init(speaker:"Marta",date:.today,own:true),now:fixture.now,timeZone:fixture.zone).count == 2)
        #expect(try await index.search("budget",filter:.init(speaker:"Dario"),now:fixture.now,timeZone:fixture.zone).isEmpty)
        #expect(!SearchIndex.names(meetings).contains(where:{ $0.hasPrefix("Speaker ") }))
        #expect(SearchIndex.names(meetings).contains("Marta"))
        #expect(try await index.search("record").allSatisfy { $0.meetingKey.hasPrefix("Received-") })
        #expect(!(try await index.search("record")).isEmpty)
        #expect(try await index.search("record",filter:.init(own:true)).isEmpty)
    }
    @Test func phraseIsLiteralDiacriticsAndUnicodeAreHighlightedAndRepeatedPlacesKeepTheirTimes() async throws {
        let fixture = try SearchFixture(); var meeting = try #require(fixture.meetings().first)
        meeting.transcriptItems = [
            .init(speaker:"a",startMs:100,endMs:200,text:"👩🏽‍💻 Café budget today. <mark> literal"),
            .init(speaker:"a",startMs:900,endMs:1000,text:"The café budget returns."),
            .init(speaker:"b",startMs:1100,endMs:1200,text:"budget appears but far from café")]
        let index = try SearchIndex(cache:fixture.cache); try await index.replace([meeting])
        let hits = try await index.search("cafe budget")
        #expect(hits.count == 2 && hits.map(\.positionMs) == [100,900])
        #expect(hits.map(\.id).count == Set(hits.map(\.id)).count)
        for hit in hits {
            let excerpt = hit.excerpt
            #expect(excerpt.text.contains("👩🏽‍💻") && excerpt.text.contains("<mark>"))
            #expect(excerpt.spans.count == 2)
            for span in excerpt.spans {
                #expect((excerpt.text as NSString).substring(with:NSRange(location:span.start,length:span.length)).lowercased() == "café budget")
            }
        }
        #expect(try await index.search("cafe OR budget").isEmpty)
        #expect(try await index.search("\" OR *").isEmpty)
        #expect(try await index.search("* NEAR()").isEmpty)
        #expect(try await index.search("...").isEmpty)
        #expect(try await index.search(" ").isEmpty)
        #expect(try await index.search("\0").isEmpty)
        let pasted = try await index.search("cafe\0budget").map(\.id)
        let spaced = try await index.search("cafe budget").map(\.id)
        #expect(pasted == spaced)
    }
    @Test func changedRemovedAndRenamedMeetingsDoNotLeaveStaleHits() async throws {
        let fixture = try SearchFixture(); let all = try fixture.meetings()
        var meeting = try #require(all.first(where:{ $0.title == "Budget review" }))
        let index = try SearchIndex(cache:fixture.cache); try await index.replace([meeting])
        #expect(try await index.search("budget").count == 2)
        meeting.speakers[0].name = "Ana"
        try await index.replace([meeting])
        #expect(try await index.search("budget",filter:.init(speaker:"Marta")).isEmpty)
        #expect(try await index.search("budget",filter:.init(speaker:"Ana")).count == 2)
        meeting.transcriptItems = [.init(speaker:meeting.speakers[0].id,startMs:123,endMs:456,text:"Replacement words")]
        try await index.replace([meeting])
        #expect(try await index.search("budget").isEmpty)
        #expect(try await index.search("replacement words").first?.positionMs == 123)
        try await index.replace([])
        #expect(try await index.search("replacement").isEmpty)
    }
    @Test func localCalendarDaysHandleDSTBoundariesAndFutureMeetings() throws {
        let iso = ISO8601DateFormatter(), zone = TimeZone(identifier:"Europe/Rome")!
        let now = try #require(iso.date(from:"2026-10-26T12:00:00Z")) // After the 25-hour day.
        #expect(SearchDate.today.contains(iso.date(from:"2026-10-25T23:00:00Z"),now:now,timeZone:zone))
        #expect(!SearchDate.today.contains(iso.date(from:"2026-10-25T22:59:59Z"),now:now,timeZone:zone))
        #expect(SearchDate.week.contains(iso.date(from:"2026-10-19T22:00:00Z"),now:now,timeZone:zone))
        #expect(!SearchDate.week.contains(iso.date(from:"2026-10-19T21:59:59Z"),now:now,timeZone:zone))
        #expect(!SearchDate.month.contains(iso.date(from:"2026-10-26T23:00:00Z"),now:now,timeZone:zone))
        #expect(SearchDate.any.contains(nil,now:now,timeZone:zone))
    }
    @Test func corruptDerivedCacheRebuildsFromTheReadOnlySnapshot() async throws {
        let fixture = try SearchFixture()
        try FileManager.default.createDirectory(at:fixture.cache,withIntermediateDirectories:true)
        try Data("broken cache".utf8).write(to:fixture.cache.appendingPathComponent("transcripts.sqlite"))
        let index = try SearchIndex(cache:fixture.cache)
        try await index.replace(fixture.meetings())
        #expect(try await index.search("budget").count == 4)
    }
    @Test func cacheAndDatabaseSymlinksAreRejected() throws {
        let fixture = try SearchFixture(), outside = fixture.directory.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:fixture.directory.appendingPathComponent("CacheLink"),withDestinationURL:outside)
        #expect(throws:(any Error).self) { try SearchIndex(cache:fixture.directory.appendingPathComponent("CacheLink")) }
        try FileManager.default.createDirectory(at:fixture.cache,withIntermediateDirectories:true)
        let source = outside.appendingPathComponent("untouched"); try Data("keep".utf8).write(to:source)
        try FileManager.default.createSymbolicLink(at:fixture.cache.appendingPathComponent("transcripts.sqlite"),withDestinationURL:source)
        #expect(throws:(any Error).self) { try SearchIndex(cache:fixture.cache) }
        #expect(try Data(contentsOf:source) == Data("keep".utf8))
        try FileManager.default.removeItem(at:fixture.cache.appendingPathComponent("transcripts.sqlite"))
        try FileManager.default.linkItem(at:source,to:fixture.cache.appendingPathComponent("transcripts.sqlite"))
        #expect(throws:(any Error).self) { try SearchIndex(cache:fixture.cache) }
        #expect(try Data(contentsOf:source) == Data("keep".utf8))
    }
}

extension SearchTests {
    @Test func legacyEchoFieldsRemainSearchable() async throws {
        let fixture=try SearchFixture();var meeting=try #require(fixture.meetings().first)
        let body=Data("[{\"speaker\":\"me\",\"startMs\":300,\"endMs\":400,\"text\":\"microphone repeat\",\"echo\":true}]".utf8)
        meeting.transcriptItems=try JSONDecoder().decode([LibraryTranscriptItem].self,from:body)
        let index=try SearchIndex(cache:fixture.cache);try await index.replace([meeting])
        #expect(try await index.search("microphone repeat").first?.positionMs == 300)
    }

    @Test func storedQuotesKeepSearchOffsetsAndPlaybackPositions() async throws {
        let fixture = try SearchFixture(); var meeting = try #require(fixture.meetings().first)
        meeting.transcriptItems = [
            .init(speaker:"a",startMs:100,endMs:200,text:"\"👩🏽‍💻 Café"),
            .init(speaker:"a",startMs:900,endMs:1000,text:"budget returns.")]
        let index = try SearchIndex(cache:fixture.cache); try await index.replace([meeting])
        let hits = try await index.search("budget")
        #expect(hits.count == 1 && hits.first?.positionMs == 900)
        let hit = try #require(hits.first), span = try #require(hit.spans.first)
        #expect(hit.text == "\"👩🏽‍💻 Café budget returns.")
        #expect((hit.text as NSString).substring(with:NSRange(location:span.start,length:span.length)) == "budget")
        #expect(meeting.transcriptItems[0].text.hasPrefix("\""))
    }
}

extension SearchTests {
    @Test func d84InlineInterjectionSearchKeepsItsWordAnchorAndRenamedCopy() async throws {
        let fixture = try SearchFixture(); var meeting = try #require(fixture.meetings().first(where:{ !$0.speakers.isEmpty }))
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        struct Body: Decodable { let items: [LibraryTranscriptItem] }
        meeting.transcriptItems = try JSONDecoder().decode(Body.self,from:Data(contentsOf:root.appendingPathComponent("Tests/CassiniLibraryTests/Golden/interjections/acknowledgment.words.json"))).items
        var ada = try #require(meeting.speakers.first); ada.id = "ada"; ada.name = "Ada"; ada.provenance = .user
        var ben = ada; ben.id = "ben"; ben.name = "Ben"; ben.colourIndex = 1
        meeting.speakers = [ada,ben]
        let index = try SearchIndex(cache:fixture.cache)
        try await index.replace([meeting])
        let hits = try await index.search("Sounds good",filter:.init(speaker:"Ben"))
        #expect(hits.count == 1)
        let hit = try #require(hits.first)
        #expect(hit.positionMs == 3050 && hit.speaker == "ben")
        #expect(try await index.search("Ben").isEmpty,"Chip labels are not spoken words")
        let hostPhrase = try await index.search("testing and")
        #expect(hostPhrase.count == 1 && hostPhrase.first?.speaker == "ada")
        #expect(hostPhrase.first?.spans.count == 2,"A continuous spoken phrase crosses the visual chip without highlighting it")
        #expect(hit.text.contains("(Ben: Sounds good.)"))
        #expect(hit.context.count == 1 && hit.contextText[0] == hit.text)
        #expect(hit.context.first?.turn.over.isEmpty == true)
        meeting.speakers[1].name = "Sam"
        try await index.replace([meeting])
        let renamed = try await index.search("Sounds good",filter:.init(speaker:"Sam"))
        #expect(renamed.count == 1 && renamed.first?.text.contains("(Sam: Sounds good.)") == true)
        #expect(renamed.first?.positionMs == 3050)
        #expect(try await index.search("Sam").isEmpty)
        // A label identical to a spoken query cannot add a second hit or highlight.
        meeting.speakers[1].name = "testing"
        try await index.replace([meeting])
        let real = try await index.search("testing")
        #expect(real.count == 1 && real.first?.speaker == "ada")
        #expect(real.first?.spans.count == 1)
    }
    @Test func croppedMonologueContextIntroducesItsSpeaker() async throws {
        let fixture = try SearchFixture()
        var meeting = try #require(fixture.meetings().first(where:{ !$0.speakers.isEmpty }))
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        struct Body: Decodable { let items: [LibraryTranscriptItem] }
        meeting.transcriptItems = try JSONDecoder().decode(Body.self,from:Data(contentsOf:root.appendingPathComponent("Tests/CassiniLibraryTests/Golden/interjections/monologue.words.json"))).items
        let index = try SearchIndex(cache:fixture.cache)
        try await index.replace([meeting])
        let hit = try #require(try await index.search("crash").first)
        let first = try #require(hit.context.first)
        #expect(first.turn.continuation)
        #expect(hit.showsSpeakerHeader(at:first.index))
        #expect(!hit.showsSpeakerHeader(at:hit.turn),"Later continuation rows retain the viewer rule")
    }

    @Test func repeatedAsidesAndHostHitsHaveParagraphWideVisualOccurrences() async throws {
        let fixture = try SearchFixture()
        var meeting = try #require(fixture.meetings().first(where:{ !$0.speakers.isEmpty }))
        meeting.transcriptItems = [
            .init(speaker:"ada",startMs:0,endMs:1000,text:"before"),
            .init(speaker:"ben",startMs:900,endMs:1100,text:"yes"),
            .init(speaker:"ada",startMs:1100,endMs:2000,text:"middle"),
            .init(speaker:"ben",startMs:1900,endMs:2100,text:"yes"),
            .init(speaker:"ada",startMs:2100,endMs:3000,text:"yes")]
        var ada = try #require(meeting.speakers.first); ada.id = "ada"; ada.name = "Ada"; ada.provenance = .user
        var ben = ada; ben.id = "ben"; ben.name = "Ben"
        meeting.speakers = [ada,ben]
        let index = try SearchIndex(cache:fixture.cache)
        try await index.replace([meeting])
        let hits = try await index.search("yes")
        #expect(hits.map(\.positionMs) == [900,1900,2100])
        #expect(hits.map(\.speaker) == ["ben","ben","ada"])
        #expect(hits.map(\.turn) == [0,0,0])
        #expect(hits.map(\.occurrence) == [0,1,2])
        #expect(Set(hits.map(\.id)).count == 3)
        #expect(hits.map(\.id) == (0..<3).map { meeting.libraryKey + ":0:\($0)" },"Keep the existing accessibility identifier contract")
        #expect(hits.allSatisfy { $0.spans.count == 3 })
        let filtered = try await index.search("yes",filter:.init(speaker:"Ben"))
        #expect(filtered.map(\.id) == Array(hits.prefix(2)).map(\.id))
        #expect(filtered.map(\.positionMs) == [900,1900])
        for hit in hits {
            let selected = try #require(hit.spans.dropFirst(hit.occurrence).first)
            #expect((hit.text as NSString).substring(with:NSRange(location:selected.start,length:selected.length)) == "yes")
        }
    }

}
