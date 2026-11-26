// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
import CassiniRecording
@testable import CassiniLibrary

@Suite struct MeetingDateTimeTests {
    private func plainOpusFixture() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repo.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/002-plain-audio.opus")
    }

    @Test func startedAtValidationFollowsQ17AndSchema() throws {
        for good in [
            "2026-11-23T14:36:00Z",
            "2026-11-23T14:36:00+00:00",
            "2026-11-23T14:36:00+01:00",
            "2026-11-23T14:36:00-00:01",
            "2026-11-23T14:36:00-12:00",
            "2026-11-23T14:36:00+14:00",
        ] {
            #expect(MeetingTime.isValidStartedAt(good), "expected valid: \(good)")
            #expect(MeetingTime.userStartedAt(good) != nil)
        }
        for bad in [
            "2026-11-23T14:36:00-00:00",
            "2026-11-23T14:36:00-12:01",
            "2026-11-23T14:36:00+14:01",
            "2026-11-23T14:36:00.500Z",
            "2026-02-30T14:36:00+01:00",
            "2026-11-23 14:36:00+01:00",
            "not-a-date",
        ] {
            #expect(!MeetingTime.isValidStartedAt(bad), "expected invalid: \(bad)")
            #expect(MeetingTime.userStartedAt(bad) == nil)
        }
    }

    @Test func schemaEnforcesDependentRequiredOnStartedAtPair() throws {
        let id = UUID()
        func parse(_ extra: [String: Any]) throws -> AppMetadata {
            var doc = MeetingMetadataWriter.defaultDocument(id: id)
            for (k, v) in extra { doc[k] = v }
            let data = try JSONSerialization.data(withJSONObject: doc)
            let parsed = try AppMetadata.parse(data)
            try parsed.validate(id: id, received: false)
            return parsed
        }
        _ = try parse(["startedAt": "2026-11-23T14:36:00+01:00", "startedAtSource": "user"])
        #expect(throws: Error.self) { _ = try parse(["startedAt": "2026-11-23T14:36:00+01:00"]) }
        #expect(throws: Error.self) { _ = try parse(["startedAtSource": "user"]) }
        #expect(throws: Error.self) { _ = try parse(["startedAt": "2026-11-23T14:36:00-00:00", "startedAtSource": "user"]) }
        #expect(throws: Error.self) { _ = try parse(["startedAt": "2026-11-23T14:36:00+01:00", "startedAtSource": "import"]) }
    }

    @Test func prefillUsesRecordingTimeThenFileSavedTimeMinusLengthThenNow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-dt-prefill-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let zone = try #require(TimeZone(secondsFromGMT: 3600))
        let now = try #require(MeetingTime.parseInstant("2026-11-24T12:00:00Z"))

        // 1. Imported file with no recording time: preserves source mtime and prefills mtime - duration.
        let source = root.appendingPathComponent("gadget-clip.opus")
        try FileManager.default.copyItem(at: try plainOpusFixture(), to: source)
        let savedAt = try #require(MeetingTime.parseInstant("2026-11-23T14:12:00Z")) // 15:12 +01:00
        try FileManager.default.setAttributes([.modificationDate: savedAt], ofItemAtPath: source.path)

        let imported = try LibraryImport.copy(source, into: root.appendingPathComponent("Library"))
        #expect(imported.meetingTime == nil)
        let filePrefill = MeetingDateTime.prefill(for: imported, now: now, timeZone: zone)
        #expect(filePrefill.fromFileSavedTime == true)
        let expectedDuration = Double(imported.durationMs ?? 0) / 1000.0
        #expect(abs(filePrefill.date.timeIntervalSince(savedAt.addingTimeInterval(-expectedDuration))) < 1.0)

        // 2. After setting a recording date, prefill uses the recording time with no hint.
        let chosen = try #require(MeetingTime.parseInstant("2026-11-23T13:36:00Z")) // 14:36 +01:00
        try MeetingDateTime.apply(chosen, timeZone: zone, to: imported)
        let updated = try #require(LibraryScanner(root: root.appendingPathComponent("Library")).meeting(at: imported.folder))
        let existingPrefill = MeetingDateTime.prefill(for: updated, now: now, timeZone: zone)
        #expect(existingPrefill.fromFileSavedTime == false)
        #expect(abs(existingPrefill.date.timeIntervalSince(chosen)) < 0.5)

        // 3. No recording time and no audio file: falls back to now with no hint.
        var empty = updated
        empty.start = nil
        empty.recordedTime = nil
        empty.userStartedAt = nil
        empty.audioFiles = []
        let fallbackPrefill = MeetingDateTime.prefill(for: empty, now: now, timeZone: zone)
        #expect(fallbackPrefill.fromFileSavedTime == false)
        #expect(fallbackPrefill.date == now)
    }

    @Test func settingDateMovesUnknownImportedMeetingOutOfDateUnknownWithoutRenamingFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-dt-move-" + UUID().uuidString)
        let library = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let zone = try #require(TimeZone(secondsFromGMT: 3600))
        let now = try #require(MeetingTime.parseInstant("2026-11-24T12:00:00Z"))
        let format = LibraryFormat(timeZone: zone, now: now, locale: Locale(identifier: "en_GB"), language: .en)

        let imported = try LibraryImport.copy(try plainOpusFixture(), into: library)
        let originalFolderName = imported.folder.lastPathComponent
        let scanner = LibraryScanner(root: library)

        let beforeGroups = try scanner.scan(now: now).groups(format: format)
        #expect(beforeGroups.map(\.title) == ["Date unknown"])

        let yesterday = try #require(MeetingTime.parseInstant("2026-11-23T13:36:00Z")) // 14:36 +01:00
        try MeetingDateTime.apply(yesterday, timeZone: zone, to: imported)

        let afterScan = try scanner.scan(now: now)
        let afterGroups = afterScan.groups(format: format)
        #expect(afterGroups.map(\.title) == ["Yesterday"])
        #expect(!afterGroups.contains { $0.title == "Date unknown" })
        let updated = try #require(afterScan.meetings.first)
        #expect(updated.folder.lastPathComponent == originalFolderName)
        #expect(updated.userStartedAt == "2026-11-23T14:36:00+01:00")
        #expect(updated.meetingTime?.instant == yesterday)
        let subtitle = format.previewSubtitle(updated.meetingTime, durationMs: updated.durationMs, received: true)
        #expect(subtitle.contains("Yesterday, 14:36"))
        #expect(!subtitle.contains("Date unknown"))
        let markdown = MeetingMarkdown.render(updated, timeZone: zone, locale: Locale(identifier: "en_GB"), language: .en)
        #expect(markdown.contains("23 November 2026"))
        #expect(markdown.contains("14:36"))
    }

    @Test func legacyImportTimeSynthesizedDateIsExcludedUntilUserSetsDate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-dt-legacy-" + UUID().uuidString)
        let library = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Build a plain opus with a legacy synthesized DATE tag, then mark meeting.json with namePrefixSource = import-time.
        let tagged = root.appendingPathComponent("legacy.opus")
        _ = try OpusStreamFile.rewrite(
            Data(contentsOf: try plainOpusFixture()),
            tags: PortableMeetingTags.packet(comments: [.init(name: "DATE", value: "2026-11-24T09:15:00+01:00")]),
            to: tagged
        )
        let imported = try LibraryImport.copy(tagged, into: library)
        try MeetingMetadataWriter(directory: imported.folder, id: imported.id).transaction {
            $0["namePrefix"] = "2026-11-24--09.15-"
            $0["namePrefixSource"] = "import-time"
        }

        let scanner = LibraryScanner(root: library)
        let zone = try #require(TimeZone(secondsFromGMT: 3600))
        let now = try #require(MeetingTime.parseInstant("2026-11-24T12:00:00Z"))
        let format = LibraryFormat(timeZone: zone, now: now, locale: Locale(identifier: "en_GB"), language: .en)

        let before = try scanner.scan(now: now)
        #expect(before.meetings.first?.meetingTime == nil)
        #expect(before.groups(format: format).map(\.title) == ["Date unknown"])

        let chosen = try #require(MeetingTime.parseInstant("2026-11-23T13:36:00Z"))
        try MeetingDateTime.apply(chosen, timeZone: zone, to: try #require(before.meetings.first))

        let after = try scanner.scan(now: now)
        #expect(after.meetings.first?.userStartedAt == "2026-11-23T14:36:00+01:00")
        #expect(after.groups(format: format).map(\.title) == ["Yesterday"])
    }

    @Test func savingDatePreservesLegacySidecarTranscriptWithoutMeetingJson() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-dt-legacy-tx-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let zone = try #require(TimeZone(secondsFromGMT: 3600))
        let chosen = try #require(MeetingTime.parseInstant("2026-11-23T13:36:00Z"))

        // 1. Valid legacy transcript.json without meeting.json stays done and readable after saving a date.
        let session = try RecordingSession(parent: root, title: "Legacy words", source: "macos")
        try session.addTrack(id: "mic", label: "Me", kind: "microphone", sampleRate: 16000, channels: 1)
        try session.appendNative(id: "mic", pcm: Data(count: 32000), offsetMs: 0)
        try session.finish()
        let transcriptURL = session.directory.appendingPathComponent("transcript.json")
        try Data(#"{"language":"en","items":[{"speaker":"track-mic","startMs":0,"endMs":400,"text":"budget"}]}"#.utf8).write(to: transcriptURL)
        #expect(!FileManager.default.fileExists(atPath: session.directory.appendingPathComponent("meeting.json").path))

        let scanner = LibraryScanner(root: root)
        let before = try #require(scanner.meeting(at: session.directory))
        #expect(before.state.transcript == .done)
        #expect(before.transcriptItems.map(\.text) == ["budget"])

        try MeetingDateTime.apply(chosen, timeZone: zone, to: before)

        let after = try #require(scanner.scan().meetings.first(where: { $0.id == before.id }))
        #expect(after.userStartedAt == "2026-11-23T14:36:00+01:00")
        #expect(after.state.transcript == .done)
        #expect(after.transcriptReferenced == true)
        #expect(after.transcriptItems.map(\.text) == ["budget"])

        // 2. Damaged legacy transcript.json without meeting.json stays damaged (never downgraded to none).
        let damagedSession = try RecordingSession(parent: root, title: "Damaged legacy", source: "macos")
        try damagedSession.addTrack(id: "mic", label: "Me", kind: "microphone", sampleRate: 16000, channels: 1)
        try damagedSession.appendNative(id: "mic", pcm: Data(count: 32000), offsetMs: 0)
        try damagedSession.finish()
        try Data("not valid json".utf8).write(to: damagedSession.directory.appendingPathComponent("transcript.json"))

        let damagedBefore = try #require(scanner.meeting(at: damagedSession.directory))
        #expect(damagedBefore.state.transcript == .damaged)

        try MeetingDateTime.apply(chosen, timeZone: zone, to: damagedBefore)

        let damagedAfter = try #require(scanner.scan().meetings.first(where: { $0.id == damagedBefore.id }))
        #expect(damagedAfter.userStartedAt == "2026-11-23T14:36:00+01:00")
        #expect(damagedAfter.state.transcript == .damaged)
        #expect(damagedAfter.transcriptReferenced == true)
    }

    @Test func localImportTimeExclusionFallsBackToExplicitRecordedAtUtcOverLegacyStartedAt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-dt-mixed-" + UUID().uuidString)
        let library = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let baseData = try Data(contentsOf: try plainOpusFixture())
        let digest = try OpusAudioDigest.compute(baseData)
        let explicitUtc = "2026-11-22T10:00:00Z"
        let info: JSON = .object([
            ("id", .string("mtg_" + digest.sha256)),
            ("title", .string("Mixed manifest")),
            ("createdAtUtc", .string("2026-11-24T08:15:00Z")),
            ("startedAt", .string("2026-11-24T09:15:00+01:00")),
            ("recordedAtUtc", .string(explicitUtc)),
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

        let imported = try LibraryImport.copy(source, into: library)
        try MeetingMetadataWriter(directory: imported.folder, id: imported.id).transaction {
            $0["namePrefix"] = "2026-11-24--09.15-"
            $0["namePrefixSource"] = "import-time"
        }

        let zone = try #require(TimeZone(secondsFromGMT: 3600))
        let now = try #require(MeetingTime.parseInstant("2026-11-24T12:00:00Z"))
        let format = LibraryFormat(timeZone: zone, now: now, locale: Locale(identifier: "en_GB"), language: .en)
        let scan = try LibraryScanner(root: library).scan(now: now)
        let meeting = try #require(scan.meetings.first)
        #expect(meeting.meetingTime?.source == .recordedAtUtc)
        #expect(meeting.meetingTime?.instant == MeetingTime.parseInstant(explicitUtc))
        #expect(!scan.groups(format: format).contains { $0.title == "Date unknown" })
    }

    @Test @MainActor func prefillLoaderFetchesOffMainActorAndIgnoresCancelledOrStaleResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-dt-async-" + UUID().uuidString)
        let library = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let zone = try #require(TimeZone(secondsFromGMT: 3600))
        let now = try #require(MeetingTime.parseInstant("2026-11-24T12:00:00Z"))
        let savedAt = try #require(MeetingTime.parseInstant("2026-11-23T14:12:00Z"))
        let imported = try LibraryImport.copy(try plainOpusFixture(), into: library)
        #expect(imported.meetingTime == nil)

        final class Gate: @unchecked Sendable {
            let release = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var ranOffMainThread = false
            private var didEnter = false
            private var enteredContinuation: CheckedContinuation<Void, Never>?

            func markEntered() {
                let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
                    didEnter = true
                    let pending = enteredContinuation
                    enteredContinuation = nil
                    return pending
                }
                continuation?.resume()
            }

            func waitForEntry() async {
                await withCheckedContinuation { continuation in
                    let alreadyEntered = lock.withLock {
                        if didEnter {
                            return true
                        }
                        enteredContinuation = continuation
                        return false
                    }
                    if alreadyEntered {
                        continuation.resume()
                    }
                }
            }
        }

        // 1. Non-blocking open on MainActor + off-main-actor metadata read + publication.
        let gate1 = Gate()
        let loader1 = MeetingDateTime.PrefillLoader { _ in
            gate1.lock.withLock { gate1.ranOffMainThread = !Thread.isMainThread }
            gate1.markEntered()
            gate1.release.wait()
            return savedAt
        }
        var published1: [(MeetingDateTime.Prefill, Bool)] = []
        let task1 = loader1.load(for: imported, now: now, timeZone: zone) { prefill, isPending in
            published1.append((prefill, isPending))
        }
        // Returns immediately while the metadata reader is blocked on gate1.release.
        #expect(published1.count == 1)
        #expect(published1[0].0 == MeetingDateTime.Prefill(date: now, fromFileSavedTime: false))
        #expect(published1[0].1 == true)

        await gate1.waitForEntry()
        #expect(gate1.lock.withLock { gate1.ranOffMainThread })
        gate1.release.signal()
        await task1?.value

        #expect(published1.count == 2)
        #expect(published1[1].0.fromFileSavedTime == true)
        #expect(published1[1].1 == false)
        let expectedDuration = Double(imported.durationMs ?? 0) / 1000.0
        #expect(abs(published1[1].0.date.timeIntervalSince(savedAt.addingTimeInterval(-expectedDuration))) < 1.0)

        // 2. Cancellation and superseding drop stale in-flight results.
        let gate2 = Gate()
        let loader2 = MeetingDateTime.PrefillLoader { _ in
            gate2.markEntered()
            gate2.release.wait()
            return savedAt
        }
        var published2: [(MeetingDateTime.Prefill, Bool)] = []
        let staleTask = loader2.load(for: imported, now: now, timeZone: zone) { prefill, isPending in
            published2.append((prefill, isPending))
        }
        await gate2.waitForEntry()
        // Supersede with a known-date meeting (completes synchronously with no I/O) before gate2 releases.
        let knownDate = try #require(MeetingTime.parseInstant("2026-11-20T08:00:00Z"))
        var knownMeeting = imported
        knownMeeting.start = knownDate
        knownMeeting.recordedTime = MeetingTime(instant: knownDate)
        loader2.load(for: knownMeeting, now: now, timeZone: zone) { prefill, isPending in
            published2.append((prefill, isPending))
        }
        gate2.release.signal()
        await staleTask?.value

        #expect(published2.count == 2)
        #expect(published2[1].0 == MeetingDateTime.Prefill(date: knownDate, fromFileSavedTime: false))
        #expect(published2[1].1 == false)
    }
}
