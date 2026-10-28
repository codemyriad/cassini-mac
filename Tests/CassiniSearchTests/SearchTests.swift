// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Testing
import CassiniLibrary
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
