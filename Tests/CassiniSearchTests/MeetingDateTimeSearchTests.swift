// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
import CassiniLibrary
@testable import CassiniSearch

@Suite struct MeetingDateTimeSearchTests {
    private func plainOpusFixture() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repo.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/002-plain-audio.opus")
    }

    @Test func searchDateFilterReflectsUserSetDateImmediately() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-dt-search-" + UUID().uuidString)
        let library = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let zone = try #require(TimeZone(secondsFromGMT: 3600))
        let now = try #require(MeetingTime.parseInstant("2026-11-24T12:00:00Z"))

        let imported = try LibraryImport.copy(try plainOpusFixture(), into: library)
        let transcriptURL = imported.folder.appendingPathComponent("transcript.json")
        let transcriptData = Data(#"{"language":"en","items":[{"speaker":"spk-1","startMs":0,"endMs":500,"text":"budget"}]}"#.utf8)
        try transcriptData.write(to: transcriptURL)
        try MeetingMetadataWriter(directory: imported.folder, id: imported.id).transaction {
            $0["transcript"] = ["status": "done", "reference": ["kind": "sidecar", "file": "transcript.json", "format": "cassini.words.v1"]]
        }

        let scanner = LibraryScanner(root: library)
        let index = try SearchIndex(cache: root.appendingPathComponent("search-cache"))

        let beforeMeetings = try scanner.scan(now: now).meetings
        try await index.replace(beforeMeetings)
        let beforeHits = try await index.search("budget", filter: .init(date: .week), now: now, timeZone: zone)
        #expect(beforeHits.isEmpty)

        let yesterday = try #require(MeetingTime.parseInstant("2026-11-23T13:36:00Z"))
        try MeetingDateTime.apply(yesterday, timeZone: zone, to: try #require(beforeMeetings.first))
        let afterMeetings = try scanner.scan(now: now).meetings
        try await index.replace(afterMeetings)
        let afterHits = try await index.search("budget", filter: .init(date: .week), now: now, timeZone: zone)
        #expect(afterHits.count == 1)
    }
}
