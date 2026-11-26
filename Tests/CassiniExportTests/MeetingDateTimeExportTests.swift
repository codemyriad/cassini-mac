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
        #expect(MeetingExportKind.primary(for: imported) == [.originalAudio])
        try MeetingMetadataWriter(directory: imported.folder, id: imported.id).transaction {
            $0["namePrefix"] = "2026-11-24--09.15-"
            $0["namePrefixSource"] = "import-time"
        }

        let chosen = try #require(MeetingTime.parseInstant("2026-11-23T13:36:00Z")) // 14:36:00+01:00
        try MeetingDateTime.apply(chosen, timeZone: zone, to: imported)
        let scannedA = try #require(LibraryScanner(root: libraryA).meeting(at: imported.folder))

        // UI export-kind selection must switch from .originalAudio to .cassini once a user date is set.
        #expect(MeetingExportKind.primary(for: scannedA) == [.cassini])
        #expect(throws: MeetingExportError.invalidSource) {
            _ = try MeetingFileExporter.originalAudio(scannedA, temporaryRoot: root)
        }
        let selectedKind = try #require(MeetingExportKind.primary(for: scannedA).first)
        let artifact: ExportArtifact
        switch selectedKind {
        case .cassini:
            artifact = try MeetingFileExporter.cassini(scannedA, assets: nil, temporaryRoot: root, timeZone: zone)
        case .originalAudio:
            artifact = try MeetingFileExporter.originalAudio(scannedA, temporaryRoot: root)
        default:
            Issue.record("Unexpected primary export kind: \(selectedKind)")
            return
        }
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

    @Test func exportingExcludedImportTimePlainOpusBeforeUserDateDoesNotResurrectDate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-dt-excl-plain-" + UUID().uuidString)
        let libraryA = root.appendingPathComponent("LibraryA")
        let libraryB = root.appendingPathComponent("LibraryB")
        try FileManager.default.createDirectory(at: libraryA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: libraryB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let zone = try #require(TimeZone(secondsFromGMT: 3600))
        let tagged = root.appendingPathComponent("legacy-import-time.opus")
        _ = try OpusStreamFile.rewrite(
            Data(contentsOf: try fixture("002-plain-audio")),
            tags: PortableMeetingTags.packet(comments: [.init(name: "DATE", value: "2026-11-24T09:15:00+01:00")]),
            to: tagged
        )
        let importedA = try LibraryImport.copy(tagged, into: libraryA)
        try MeetingMetadataWriter(directory: importedA.folder, id: importedA.id).transaction {
            $0["namePrefix"] = "2026-11-24--09.15-"
            $0["namePrefixSource"] = "import-time"
        }

        let scannedA = try #require(LibraryScanner(root: libraryA).meeting(at: importedA.folder))
        #expect(scannedA.meetingTime == nil)

        let artifact = try MeetingFileExporter.cassini(scannedA, assets: nil, temporaryRoot: root, timeZone: zone)
        let exported = try CassiniReader.read(contentsOf: artifact.url)
        #expect(exported.state == .ok)
        #expect(exported.manifest?.meeting.startedAt == nil)
        #expect(exported.manifest?.meeting.recordedAtUtc == nil)
        #expect(exported.manifest?.meeting.recordedAtLocal == nil)
        #expect(exported.tags?["DATE"] == nil)
        #expect(exported.meetingTime == nil)

        let importedB = try LibraryImport.copy(artifact.url, into: libraryB)
        #expect(importedB.meetingTime == nil)
        let now = try #require(MeetingTime.parseInstant("2026-11-24T12:00:00Z"))
        let format = LibraryFormat(timeZone: zone, now: now, locale: Locale(identifier: "en_GB"), language: .en)
        let groupsB = try LibraryScanner(root: libraryB).scan(now: now).groups(format: format)
        #expect(groupsB.map(\.title) == ["Date unknown"])
    }

    @Test func exportingExcludedImportTimeCassiniFilePreservesExplicitRecordedAtUtc() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-dt-excl-utc-" + UUID().uuidString)
        let libraryA = root.appendingPathComponent("LibraryA")
        let libraryB = root.appendingPathComponent("LibraryB")
        try FileManager.default.createDirectory(at: libraryA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: libraryB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let zone = try #require(TimeZone(secondsFromGMT: 3600))
        let baseData = try Data(contentsOf: try fixture("002-plain-audio"))
        let digest = try OpusAudioDigest.compute(baseData)
        let explicitUtc = "2026-11-22T10:00:00Z"
        let info: JSON = .object([
            ("id", .string("mtg_" + digest.sha256)),
            ("title", .string("Mixed fields")),
            ("createdAtUtc", .string("2026-11-24T08:15:00Z")),
            ("startedAt", .string("2026-11-24T09:15:00+01:00")),
            ("recordedAtUtc", .string(explicitUtc)),
            ("recordedAtLocal", .string("2026-11-24T09:15:00")),
            ("durationMs", .number(String(digest.durationMs))),
        ])
        let audio: JSON = .object([
            ("container", .string("ogg")), ("codec", .string("opus")), ("sampleRate", .number("48000")),
            ("channels", .number(String(digest.channels))), ("sampleCount", .number(String(digest.sampleCount))),
            ("durationMs", .number(String(digest.durationMs))),
        ])
        let integrity: JSON = .object([
            ("matchPolicy", .string("exact-opus-audio-v1")), ("opusAudioSha256", .string(digest.sha256)),
            ("sampleRate", .number("48000")), ("channels", .number(String(digest.channels))),
            ("sampleCount", .number(String(digest.sampleCount))), ("durationMs", .number(String(digest.durationMs))),
        ])
        let manifest: JSON = .object([
            ("kind", .string("cassini-portable-meeting")), ("version", .number("1")), ("profile", .string("ogg-opus")),
            ("meeting", info), ("audio", audio), ("integrity", integrity), ("speakers", .array([])),
        ])
        let transcripts = try PortableMeetingTags.transcripts(own: nil, carried: nil)
        let tags = try PortableMeetingTags.make(manifest: manifest, transcripts: transcripts)
        let source = root.appendingPathComponent("mixed.opus")
        _ = try OpusStreamFile.rewrite(baseData, tags: tags, to: source)

        let importedA = try LibraryImport.copy(source, into: libraryA)
        try MeetingMetadataWriter(directory: importedA.folder, id: importedA.id).transaction {
            $0["namePrefix"] = "2026-11-24--09.15-"
            $0["namePrefixSource"] = "import-time"
        }

        let scannedA = try #require(LibraryScanner(root: libraryA).meeting(at: importedA.folder))
        #expect(scannedA.meetingTime?.source == .recordedAtUtc)
        #expect(scannedA.meetingTime?.instant == MeetingTime.parseInstant(explicitUtc))

        let artifact = try MeetingFileExporter.cassini(scannedA, assets: nil, temporaryRoot: root, timeZone: zone)
        let exported = try CassiniReader.read(contentsOf: artifact.url)
        #expect(exported.state == .ok)
        #expect(exported.manifest?.meeting.startedAt == nil)
        #expect(exported.manifest?.meeting.recordedAtLocal == nil)
        #expect(exported.manifest?.meeting.recordedAtUtc == explicitUtc)
        #expect(exported.tags?["DATE"] == explicitUtc)

        let importedB = try LibraryImport.copy(artifact.url, into: libraryB)
        #expect(importedB.meetingTime?.source == .recordedAtUtc)
        #expect(importedB.meetingTime?.instant == MeetingTime.parseInstant(explicitUtc))
    }

    @Test func exportingWithBothNamespacesHonorsLocalImportTimeExclusionOverEmbeddedNamespace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-dt-both-ns-" + UUID().uuidString)
        let libraryA = root.appendingPathComponent("LibraryA")
        let libraryB = root.appendingPathComponent("LibraryB")
        try FileManager.default.createDirectory(at: libraryA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: libraryB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let zone = try #require(TimeZone(secondsFromGMT: 3600))
        let baseData = try Data(contentsOf: try fixture("002-plain-audio"))
        let digest = try OpusAudioDigest.compute(baseData)
        let explicitUtc = "2026-11-22T10:00:00Z"
        let info: JSON = .object([
            ("id", .string("mtg_" + digest.sha256)),
            ("title", .string("Both namespaces")),
            ("createdAtUtc", .string("2026-11-24T08:15:00Z")),
            ("startedAt", .string("2026-11-24T09:15:00+01:00")),
            ("recordedAtUtc", .string(explicitUtc)),
            ("recordedAtLocal", .string("2026-11-24T09:15:00")),
            ("durationMs", .number(String(digest.durationMs))),
        ])
        let audio: JSON = .object([
            ("container", .string("ogg")), ("codec", .string("opus")), ("sampleRate", .number("48000")),
            ("channels", .number(String(digest.channels))), ("sampleCount", .number(String(digest.sampleCount))),
            ("durationMs", .number(String(digest.durationMs))),
        ])
        let integrity: JSON = .object([
            ("matchPolicy", .string("exact-opus-audio-v1")), ("opusAudioSha256", .string(digest.sha256)),
            ("sampleRate", .number("48000")), ("channels", .number(String(digest.channels))),
            ("sampleCount", .number(String(digest.sampleCount))), ("durationMs", .number(String(digest.durationMs))),
        ])
        let embeddedNamespace: JSON = .object([
            ("schema", .number("1")),
            ("sessionId", .string(UUID().uuidString.lowercased())),
            ("origin", .string("Received")),
            ("namePrefix", .string("2026-11-22--11.00-")),
            ("namePrefixSource", .string("recorded")),
            ("revision", .number("1")),
            ("meeting", .object([
                ("version", .number("1")),
                ("title", .null),
                ("titleSource", .string("meeting-window")),
                ("speakers", .array([])),
                ("transcript", .object([("status", .string("none")), ("reference", .null)])),
                ("etaMinutes", .null),
                ("error", .null),
                ("quoteOverride", .null),
                ("received", .null),
            ])),
            ("automaticTitle", .string("Both namespaces")),
        ])
        let manifest: JSON = .object([
            ("kind", .string("cassini-portable-meeting")), ("version", .number("1")), ("profile", .string("ogg-opus")),
            ("meeting", info), ("audio", audio), ("integrity", integrity), ("speakers", .array([])),
            ("x", .object([("codemyriad.io", embeddedNamespace)])),
        ])
        let transcripts = try PortableMeetingTags.transcripts(own: nil, carried: nil)
        let tags = try PortableMeetingTags.make(manifest: manifest, transcripts: transcripts)
        let source = root.appendingPathComponent("both-namespaces.opus")
        _ = try OpusStreamFile.rewrite(baseData, tags: tags, to: source)

        let importedA = try LibraryImport.copy(source, into: libraryA)
        try MeetingMetadataWriter(directory: importedA.folder, id: importedA.id).transaction {
            $0["namePrefix"] = "2026-11-24--09.15-"
            $0["namePrefixSource"] = "import-time"
        }

        let scannedA = try #require(LibraryScanner(root: libraryA).meeting(at: importedA.folder))
        #expect(scannedA.meetingTime?.source == .recordedAtUtc)
        #expect(scannedA.meetingTime?.instant == MeetingTime.parseInstant(explicitUtc))

        let artifact = try MeetingFileExporter.cassini(scannedA, assets: nil, temporaryRoot: root, timeZone: zone)
        let exported = try CassiniReader.read(contentsOf: artifact.url)
        #expect(exported.state == .ok)
        #expect(exported.manifest?.meeting.startedAt == nil)
        #expect(exported.manifest?.meeting.recordedAtLocal == nil)
        #expect(exported.manifest?.meeting.recordedAtUtc == explicitUtc)
        #expect(exported.tags?["DATE"] == explicitUtc)

        let importedB = try LibraryImport.copy(artifact.url, into: libraryB)
        #expect(importedB.meetingTime?.source == .recordedAtUtc)
        #expect(importedB.meetingTime?.instant == MeetingTime.parseInstant(explicitUtc))
    }
}
