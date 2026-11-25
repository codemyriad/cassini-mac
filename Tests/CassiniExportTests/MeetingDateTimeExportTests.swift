// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
import CassiniLibrary
@testable import CassiniExport

@Suite struct MeetingDateTimeExportTests {
    private func fixture(_ name: String) throws -> URL {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repo.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/" + name + ".opus")
    }

    @Test func exportedOpusCarriesUserStartedAtAcrossAppsAndPreservesNamePrefix() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-dt-export-" + UUID().uuidString)
        let libraryA = root.appendingPathComponent("LibraryA")
        let libraryB = root.appendingPathComponent("LibraryB")
        try FileManager.default.createDirectory(at: libraryA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: libraryB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let zone = try #require(TimeZone(secondsFromGMT: 3600))
        let imported = try LibraryImport.copy(try fixture("002-plain-audio"), into: libraryA)
        try MeetingMetadataWriter(directory: imported.folder, id: imported.id).transaction {
            $0["namePrefix"] = "2026-11-24--09.15-"
            $0["namePrefixSource"] = "import-time"
        }

        let chosen = try #require(MeetingTime.parseInstant("2026-11-23T13:36:00Z")) // 14:36:00+01:00
        try MeetingDateTime.apply(chosen, timeZone: zone, to: imported)
        let scannedA = try #require(LibraryScanner(root: libraryA).meeting(at: imported.folder))

        let artifact = try MeetingFileExporter.cassini(scannedA, assets: nil, temporaryRoot: root, timeZone: zone)
        let exported = try CassiniReader.read(contentsOf: artifact.url)
        #expect(exported.state == .ok)
        #expect(exported.tags?["DATE"] == "2026-11-23T14:36:00+01:00")
        #expect(exported.manifest?.meeting.startedAt == "2026-11-23T14:36:00+01:00")
        #expect(exported.manifest?.meeting.recordedAtLocal == "2026-11-23T14:36:00")
        #expect(exported.manifest?.meeting.createdAtUtc != "2026-11-23T13:36:00Z")
        let x = try #require(exported.manifest?.raw["x"]?["codemyriad.io"])
        #expect(x["namePrefix"] == .string("2026-11-24--09.15-"))
        #expect(x["namePrefixSource"] == .string("import-time"))
        #expect(x["meeting"]?["startedAt"] == .string("2026-11-23T14:36:00+01:00"))
        #expect(x["meeting"]?["startedAtSource"] == .string("user"))
        #expect(x["passthrough"]?["startedAt"] == nil)
        #expect(x["passthrough"]?["startedAtSource"] == nil)

        // Re-import in another library: keeps the exact user-set date and never falls back to Date unknown.
        let importedB = try LibraryImport.copy(artifact.url, into: libraryB)
        #expect(importedB.userStartedAt == "2026-11-23T14:36:00+01:00")
        #expect(importedB.meetingTime?.instant == chosen)
        let now = try #require(MeetingTime.parseInstant("2026-11-24T12:00:00Z"))
        let format = LibraryFormat(timeZone: zone, now: now, locale: Locale(identifier: "en_GB"), language: .en)
        let groupsB = try LibraryScanner(root: libraryB).scan(now: now).groups(format: format)
        #expect(groupsB.map(\.title) == ["Yesterday"])
    }
}
