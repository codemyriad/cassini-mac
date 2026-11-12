// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import zlib
import Testing
import CassiniKit
import CassiniLibrary
import CassiniRecording
@testable import CassiniExport

@Suite struct MeetingExportTestsBulkZip {
    private struct ParsedStoredEntry {
        let name: String
        let flags: UInt16
        let method: UInt16
        let crc32: UInt32
        let data: Data
    }

    private func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniBulkZipTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadOpusAssetsIfConfigured() throws -> OpusAssets? {
        guard let path = ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"] else {
            return nil
        }
        let dir = URL(fileURLWithPath: path)
        let hashes = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: dir.appendingPathComponent("unsigned-sha256.json")))
        return try .builtForTests(directory: dir, expectedBinarySHA256: #require(hashes["libopus.0.dylib"]))
    }

    /// Parses all entries from a Stored (method 0) ZIP32 archive to verify raw entry headers and exact payload bytes.
    private func parseStoredZip(_ zipURL: URL) throws -> [ParsedStoredEntry] {
        let bytes = try Data(contentsOf: zipURL)
        #expect(bytes.count >= 22)
        let eocdOffset = bytes.count - 22
        #expect(bytes.readU32LE(eocdOffset) == 0x0605_4b50)
        let entryCount = Int(bytes.readU16LE(eocdOffset + 10))
        let cdSize = Int(bytes.readU32LE(eocdOffset + 12))
        let cdOffset = Int(bytes.readU32LE(eocdOffset + 16))
        #expect(cdOffset + cdSize == eocdOffset)

        var entries: [ParsedStoredEntry] = []
        var cursor = cdOffset
        for _ in 0..<entryCount {
            #expect(bytes.readU32LE(cursor) == 0x0201_4b50)
            let flags = bytes.readU16LE(cursor + 8)
            let method = bytes.readU16LE(cursor + 10)
            let crc = bytes.readU32LE(cursor + 16)
            let compSize = Int(bytes.readU32LE(cursor + 20))
            let uncompSize = Int(bytes.readU32LE(cursor + 24))
            let nameLen = Int(bytes.readU16LE(cursor + 28))
            let extraLen = Int(bytes.readU16LE(cursor + 30))
            let commentLen = Int(bytes.readU16LE(cursor + 32))
            let localOffset = Int(bytes.readU32LE(cursor + 42))

            #expect(compSize == uncompSize)
            let nameData = bytes[(cursor + 46)..<(cursor + 46 + nameLen)]
            let name = try #require(String(data: nameData, encoding: .utf8))

            #expect(bytes.readU32LE(localOffset) == 0x0403_4b50)
            let localFlags = bytes.readU16LE(localOffset + 6)
            let localMethod = bytes.readU16LE(localOffset + 8)
            let localCRC = bytes.readU32LE(localOffset + 14)
            let localComp = Int(bytes.readU32LE(localOffset + 18))
            let localUncomp = Int(bytes.readU32LE(localOffset + 22))
            let localNameLen = Int(bytes.readU16LE(localOffset + 26))
            let localExtraLen = Int(bytes.readU16LE(localOffset + 28))
            #expect(localFlags == flags && localMethod == method && localCRC == crc)
            #expect(localComp == compSize && localUncomp == uncompSize)

            let dataStart = localOffset + 30 + localNameLen + localExtraLen
            let payload = Data(bytes[dataStart..<(dataStart + compSize)])
            let computedCRC = payload.withUnsafeBytes { raw -> UInt32 in
                let initCRC = zlib.crc32(0, nil, 0)
                guard let ptr = raw.bindMemory(to: Bytef.self).baseAddress, !raw.isEmpty else {
                    return UInt32(truncatingIfNeeded: initCRC)
                }
                return UInt32(truncatingIfNeeded: zlib.crc32(initCRC, ptr, uInt(raw.count)))
            }
            #expect(computedCRC == crc)

            entries.append(ParsedStoredEntry(name: name, flags: flags, method: method, crc32: crc, data: payload))
            cursor += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    // MARK: - 1. Unedited Byte-for-Byte Preservation & Duplicate Detection on Re-Import

    @Test func uneditedReceivedDocumentsAndPlainAudioCopyByteForByteAndReimportAsDuplicates() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = root.appendingPathComponent("Library")
        let tempStage = root.appendingPathComponent("Stage")
        let stereoTone = try #require(Bundle.module.url(forResource: "stereo-tone", withExtension: "opus", subdirectory: "Fixtures"))

        // Build a valid Cassini .opus document whose title lives ONLY in manifest.meeting.title
        // (no Vorbis TITLE tag), plus embedded transcript words and notes.
        let seedImported = try LibraryImport.copy(stereoTone, into: root.appendingPathComponent("Seed"))
        try MeetingMetadataWriter(directory: seedImported.folder, id: seedImported.id).transaction {
            $0["title"] = "Architecture sync"
            $0["titleSource"] = "user"
            $0["notes"] = [["atMs": 250, "text": "Original embedded note"]]
            $0["speakers"] = [["id": "s1", "name": "Alice", "provenance": "user", "colourIndex": 0]]
            $0["transcript"] = ["status": "done", "reference": ["kind": "sidecar", "file": "transcript.json", "format": "cassini.words.v1"]]
        }
        try Data("{\"language\":\"en\",\"items\":[{\"speaker\":\"s1\",\"startMs\":0,\"endMs\":400,\"text\":\"Hello team\"}]}".utf8)
            .write(to: seedImported.folder.appendingPathComponent("transcript.json"))
        let seedScanned = try #require(LibraryScanner(root: seedImported.folder.deletingLastPathComponent()).scan().meetings.first)
        let cassiniSeedArtifact = try MeetingFileExporter.cassini(seedScanned, assets: nil, temporaryRoot: root)
        let seedParsed = try CassiniReader.read(contentsOf: cassiniSeedArtifact.url)
        var manifestOnlyTags = try PortableMeetingTags.make(
            manifest: #require(seedParsed.manifest?.raw),
            transcript: Data("{\"language\":\"en\",\"items\":[{\"speaker\":\"s1\",\"startMs\":0,\"endMs\":400,\"text\":\"Hello team\"}]}".utf8),
            wordCount: 1
        )
        if let range = manifestOnlyTags.range(of: Data("TITLE=Architecture sync".utf8)) {
            manifestOnlyTags.replaceSubrange(range, with: Data("X_PAD=Architecture sync".utf8))
        }
        let cassiniDocURL = root.appendingPathComponent("ManifestOnlyTitle.opus")
        _ = try OpusStreamFile.rewrite(Data(contentsOf: cassiniSeedArtifact.url), tags: manifestOnlyTags, to: cassiniDocURL)
        let cassiniParsed = try CassiniReader.read(contentsOf: cassiniDocURL)
        #expect(cassiniParsed.state == .ok)
        #expect(cassiniParsed.tags?["TITLE"] == nil)
        #expect(cassiniParsed.manifest?.meeting.title == "Architecture sync")

        // Import BOTH the Cassini document and plain untranscribed audio into Library without editing them.
        let plainSource = root.appendingPathComponent("Plain voice memo.opus")
        try FileManager.default.copyItem(at: stereoTone, to: plainSource)

        let importedCassini = try LibraryImport.copy(cassiniDocURL, into: library)
        let importedPlain = try LibraryImport.copy(plainSource, into: library)

        let cassiniOriginalBytes = try Data(contentsOf: #require(importedCassini.audioFiles.first))
        let plainOriginalBytes = try Data(contentsOf: #require(importedPlain.audioFiles.first))
        let cassiniMetadataBefore = try Data(contentsOf: importedCassini.folder.appendingPathComponent("meeting.json"))
        let plainMetadataBefore = try Data(contentsOf: importedPlain.folder.appendingPathComponent("meeting.json"))

        let scanned = try LibraryScanner(root: library).scan().meetings
        #expect(scanned.count == 2)

        let zipURL = root.appendingPathComponent("Unedited export.zip")
        var progressCalls: [String] = []
        let count = try BulkZipExporter.export(
            scanned,
            to: zipURL,
            assets: nil,
            temporaryRoot: tempStage,
            onProgress: { done, total in progressCalls.append("\(done)/\(total)") }
        )
        #expect(count == 2)
        #expect(progressCalls == ["1/2", "2/2"])

        // Library files must NEVER be rewritten or mutated during export!
        #expect(try Data(contentsOf: #require(importedCassini.audioFiles.first)) == cassiniOriginalBytes)
        #expect(try Data(contentsOf: #require(importedPlain.audioFiles.first)) == plainOriginalBytes)
        #expect(try Data(contentsOf: importedCassini.folder.appendingPathComponent("meeting.json")) == cassiniMetadataBefore)
        #expect(try Data(contentsOf: importedPlain.folder.appendingPathComponent("meeting.json")) == plainMetadataBefore)
        // Zero temporary staging files even needed for unedited received files!
        let stageItems = (try? FileManager.default.contentsOfDirectory(atPath: tempStage.path)) ?? []
        #expect(stageItems.isEmpty)

        // Verify Stored (method 0) ZIP headers and exact byte-for-byte equality!
        let parsedEntries = try parseStoredZip(zipURL)
        #expect(parsedEntries.count == 2)
        for entry in parsedEntries {
            #expect(entry.method == 0)
            #expect((entry.flags & 0x0800) != 0)
        }
        let byName = Dictionary(uniqueKeysWithValues: parsedEntries.map { ($0.name, $0.data) })
        #expect(byName["Architecture sync.opus"] == cassiniOriginalBytes)
        #expect(byName["Plain voice memo.opus"] == plainOriginalBytes)

        // Re-importing the exported .zip into the same Library must detect BOTH as duplicates!
        var reimportSummary = LibraryImportSummary()
        _ = try ZipArchiveImport.importArchive(zipURL, into: library, temporaryRoot: tempStage, summary: &reimportSummary)
        #expect(reimportSummary.imported == 0)
        #expect(reimportSummary.duplicates == 2)
        #expect(reimportSummary.unsupported == 0)
        #expect(reimportSummary.failed == 0)
        #expect(try LibraryScanner(root: library).scan().meetings.count == 2)
    }

    // MARK: - 2. Locally Edited + Own Recordings & One-Meeting-at-a-Time Streaming

    @Test func editedAndOwnMeetingsStreamOneAtATimeWithoutAccumulatingTemporaryFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = root.appendingPathComponent("Library")
        let stageMonitor = root.appendingPathComponent("SingleMeetingStage")
        try FileManager.default.createDirectory(at: stageMonitor, withIntermediateDirectories: true)

        let stereoTone = try #require(Bundle.module.url(forResource: "stereo-tone", withExtension: "opus", subdirectory: "Fixtures"))

        // Meeting 1: Received meeting renamed locally by the user.
        let src1 = root.appendingPathComponent("first.opus")
        try FileManager.default.copyItem(at: stereoTone, to: src1)
        let m1 = try LibraryImport.copy(src1, into: library)
        try MeetingRename.apply("Renamed design review", to: m1)

        // Meeting 2: Received meeting with a user-added note.
        // Perturb last Ogg byte? No — rewrite with different valid tags so m2 has distinct audio or distinct folder.
        let m2Seed = try MeetingFileExporter.cassini(m1, assets: nil, temporaryRoot: root)
        let m2 = try LibraryImport.copy(m2Seed.url, into: root.appendingPathComponent("SecondRoot"))
        try MeetingMetadataWriter(directory: m2.folder, id: m2.id).transaction {
            $0["title"] = "Annotated retro"
            $0["titleSource"] = "user"
            $0["notes"] = [["atMs": 120, "text": "Action item: ship bulk zip"]]
        }

        var toExport: [LibraryMeeting] = [
            try #require(LibraryScanner(root: library).meeting(at: m1.folder)),
            try #require(LibraryScanner(root: m2.folder.deletingLastPathComponent()).meeting(at: m2.folder)),
        ]

        let opusAssets = try loadOpusAssetsIfConfigured()
        if let opusAssets {
            let session = try RecordingSession(parent: library, title: "Recorded standup", source: "macos")
            try session.addTrack(id: "mic", label: "Mic", kind: "microphone", sampleRate: 16_000, channels: 1)
            var pcm = Data()
            for n in 0..<16_000 {
                var sample = Int16(5_000 * sin(Double(n) * 2 * .pi * 440 / 16_000)).littleEndian
                withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
            }
            try session.appendNative(id: "mic", pcm: pcm, offsetMs: 0)
            try session.finish()
            try Data("{\"language\":\"en\",\"items\":[{\"speaker\":\"mic\",\"startMs\":0,\"endMs\":500,\"text\":\"Standup complete\"}]}".utf8)
                .write(to: session.directory.appendingPathComponent("transcript.json"))
            try MeetingMetadataWriter(directory: session.directory, id: session.manifest.id).transaction {
                $0["notes"] = [["atMs": 100, "text": "Own recording note"]]
                $0["speakers"] = [["id": "mic", "name": "Bob", "provenance": "user", "colourIndex": 1]]
                $0["transcript"] = ["status": "done", "reference": ["kind": "sidecar", "file": "transcript.json", "format": "cassini.words.v1"]]
            }
            let scannedOwn = try #require(LibraryScanner(root: library).meeting(at: session.directory))
            toExport.append(scannedOwn)
            _ = opusAssets
        }

        let zipURL = root.appendingPathComponent("Streamed.zip")
        var checkedAfterEntries = 0
        let exportedCount = try BulkZipExporter.exportInternal(
            toExport,
            to: zipURL,
            assets: opusAssets,
            temporaryRoot: stageMonitor,
            afterEachEntry: { _ in
                checkedAfterEntries += 1
                // Every single meeting's temporary export directory MUST be deleted immediately
                // after streaming its bytes into the .zip!
                let leftovers = try FileManager.default.contentsOfDirectory(atPath: stageMonitor.path)
                #expect(leftovers.isEmpty)
            }
        )
        #expect(exportedCount == toExport.count)
        #expect(checkedAfterEntries == toExport.count)

        let entries = try parseStoredZip(zipURL)
        #expect(entries.count == toExport.count)
        #expect(entries.allSatisfy { $0.method == 0 })

        // Re-import into a brand-new Library and verify user edits, notes, and transcripts round-trip!
        let restoredLibrary = root.appendingPathComponent("RestoredLibrary")
        var restoreSummary = LibraryImportSummary()
        _ = try ZipArchiveImport.importArchive(zipURL, into: restoredLibrary, temporaryRoot: stageMonitor, summary: &restoreSummary)
        #expect(restoreSummary.imported == toExport.count)
        #expect(restoreSummary.duplicates == 0)
        #expect(restoreSummary.failed == 0)

        // Also verify each individual entry in the ZIP is a valid Cassini .opus with expected title/notes.
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.data) })
        let parsedM1 = try CassiniReader.read(#require(byName["Renamed design review.opus"]))
        #expect(parsedM1.state == .ok && parsedM1.manifest?.meeting.title == "Renamed design review")

        let parsedM2 = try CassiniReader.read(#require(byName["Annotated retro.opus"]))
        #expect(parsedM2.state == .ok && parsedM2.manifest?.meeting.title == "Annotated retro")
        #expect(parsedM2.manifest?.raw["x"]?["gocassini.com"]?["notes"]?.array?.first?["text"]?.string == "Action item: ship bulk zip")

        if opusAssets != nil {
            let parsedOwn = try CassiniReader.read(#require(byName["Recorded standup.opus"]))
            #expect(parsedOwn.state == .ok && parsedOwn.manifest?.meeting.title == "Recorded standup")
            #expect(parsedOwn.defaultTranscript?.load.transcript?.items.map(\.text) == ["Standup complete"])
            #expect(parsedOwn.manifest?.raw["x"]?["gocassini.com"]?["notes"]?.array?.first?["text"]?.string == "Own recording note")
        }
    }

    // MARK: - 3. Collision Naming, Live/Missing Exclusion, Symlink Safety & Cancellation

    @Test func collisionNamesLiveRecordingExclusionSymlinkRefusalAndCleanCancellation() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let stereoTone = try #require(Bundle.module.url(forResource: "stereo-tone", withExtension: "opus", subdirectory: "Fixtures"))

        // Three meetings with identical titles in separate roots -> "Weekly sync.opus", "Weekly sync 2.opus", "Weekly sync 3.opus"
        var sameTitleMeetings: [LibraryMeeting] = []
        for idx in 1...3 {
            let subLib = root.appendingPathComponent("Lib-\(idx)")
            let imported = try LibraryImport.copy(stereoTone, into: subLib)
            try MeetingRename.apply("Weekly sync", to: imported)
            sameTitleMeetings.append(try #require(LibraryScanner(root: subLib).meeting(at: imported.folder)))
        }

        // Add live (.recording and .saving) RecordingSessions -> must be excluded!
        let liveLib = root.appendingPathComponent("LiveLib")
        let liveSession = try RecordingSession(parent: liveLib, title: "Active call", source: "macos")
        try liveSession.addTrack(id: "mic", label: "Mic", kind: "microphone", sampleRate: 16_000, channels: 1)
        try liveSession.appendNative(id: "mic", pcm: Data(repeating: 0, count: 3_200), offsetMs: 0)
        let liveScanned = try #require(LibraryScanner(root: liveLib, activity: CaptureActivitySnapshot([liveSession.manifest.id: .recording])).scan().meetings.first)
        #expect(liveScanned.state.lifecycle == .recording)
        let savingScanned = try #require(LibraryScanner(root: liveLib, activity: CaptureActivitySnapshot([liveSession.manifest.id: .saving])).scan().meetings.first)
        #expect(savingScanned.state.lifecycle == .saving)

        // Add a saved meeting whose audio file is missing -> must be excluded!
        let missingLib = root.appendingPathComponent("MissingLib")
        let missingImported = try LibraryImport.copy(stereoTone, into: missingLib)
        try FileManager.default.removeItem(at: #require(missingImported.audioFiles.first))
        let missingScanned = try #require(LibraryScanner(root: missingLib).meeting(at: missingImported.folder))
        #expect(missingScanned.state.audioAvailable == false)

        // Add a saved meeting marked as live folder via callback -> must be excluded!
        let liveCallbackLib = root.appendingPathComponent("LiveCallbackLib")
        let liveCallbackMeeting = try LibraryImport.copy(stereoTone, into: liveCallbackLib)

        // Exporting ONLY excluded meetings throws invalidSource and writes nothing.
        let emptyOut = root.appendingPathComponent("ShouldNotExist.zip")
        #expect(throws: MeetingExportError.invalidSource) {
            try BulkZipExporter.export(
                [liveScanned, savingScanned, missingScanned, liveCallbackMeeting],
                to: emptyOut,
                assets: nil,
                isLiveFolder: { $0.standardizedFileURL == liveCallbackMeeting.folder.standardizedFileURL }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: emptyOut.path))

        // Exporting the mix exports strictly the 3 saved playable meetings with collision-disambiguated names!
        let outDir = root.appendingPathComponent("Output")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let mixedZip = outDir.appendingPathComponent("Meetings.zip")
        let written = try BulkZipExporter.export(
            sameTitleMeetings + [liveScanned, savingScanned, missingScanned, liveCallbackMeeting],
            to: mixedZip,
            assets: nil,
            isLiveFolder: { $0.standardizedFileURL == liveCallbackMeeting.folder.standardizedFileURL }
        )
        #expect(written == 3)
        let entries = try parseStoredZip(mixedZip)
        #expect(entries.map(\.name) == ["Weekly sync.opus", "Weekly sync 2.opus", "Weekly sync 3.opus"])

        // Symlink refusal (both live and dangling symlinks).
        let victim = outDir.appendingPathComponent("victim.txt")
        try Data("do-not-touch".utf8).write(to: victim)
        let symlink = outDir.appendingPathComponent("symlink.zip")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: victim)
        #expect(throws: POSIXError(.ELOOP)) {
            try BulkZipExporter.export(sameTitleMeetings, to: symlink, assets: nil)
        }
        #expect(try Data(contentsOf: victim) == Data("do-not-touch".utf8))

        // Cancellation mid-export:
        // (a) New destination -> leaves NO file in outDir.
        let cancelledNew = outDir.appendingPathComponent("CancelledNew.zip")
        var cancelOnSecond = false
        #expect(throws: CancellationError.self) {
            try BulkZipExporter.export(
                sameTitleMeetings,
                to: cancelledNew,
                assets: nil,
                onProgress: { done, _ in if done == 2 { cancelOnSecond = true } },
                shouldCancel: { cancelOnSecond }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: cancelledNew.path))

        // (b) Overwriting an existing destination -> preserves existing file byte-for-byte on cancel!
        let originalMixedBytes = try Data(contentsOf: mixedZip)
        var cancelOverwrite = false
        #expect(throws: CancellationError.self) {
            try BulkZipExporter.export(
                sameTitleMeetings,
                to: mixedZip,
                assets: nil,
                onProgress: { done, _ in if done == 2 { cancelOverwrite = true } },
                shouldCancel: { cancelOverwrite }
            )
        }
        #expect(try Data(contentsOf: mixedZip) == originalMixedBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outDir.path).sorted() == ["Meetings.zip", "symlink.zip", "victim.txt"])
    }

    @Test func twoThousandIdenticalTitlesResolveInLinearThreadCPUTime() throws {
        var used = Set<String>()
        var nextByBase: [String: Int] = [:]
        let startCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var names: [String] = []
        names.reserveCapacity(2_000)
        for _ in 0..<2_000 {
            names.append(try BulkZipExporter.uniqueEntryName(
                title: "Untitled meeting",
                usedLowercased: &used,
                nextCollisionByBase: &nextByBase
            ))
        }
        let elapsedCPUNs = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - startCPU
        #expect(names.count == 2_000)
        #expect(names.first == "Untitled meeting.opus")
        #expect(names.last == "Untitled meeting 2000.opus")
        #expect(elapsedCPUNs < 500_000_000) // < 500 ms thread CPU time (typically ~3 ms)
    }

    // MARK: - 4. Non-OK Sources With Local Edits Go Byte-for-Byte & Supported Rebuilds Retain Both Transcripts

    @Test func nonOKSourcesWithLocalEditsPreserveOriginalBytesAndSupportedRebuildsRetainAllTranscripts() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = root.appendingPathComponent("Library")
        let stage = root.appendingPathComponent("Stage")
        let stereoTone = try #require(Bundle.module.url(forResource: "stereo-tone", withExtension: "opus", subdirectory: "Fixtures"))

        // Seed a valid Cassini .ok document with embedded transcript + custom tag so we can derive all non-OK variants.
        let seedDir = root.appendingPathComponent("Seed")
        let seedMeeting = try LibraryImport.copy(stereoTone, into: seedDir)
        try Data("{\"language\":\"en\",\"items\":[{\"speaker\":\"s1\",\"startMs\":0,\"endMs\":400,\"text\":\"Embedded original words\"}]}".utf8)
            .write(to: seedMeeting.folder.appendingPathComponent("transcript.json"))
        try MeetingMetadataWriter(directory: seedMeeting.folder, id: seedMeeting.id).transaction {
            $0["title"] = "Seed document"
            $0["titleSource"] = "user"
            $0["notes"] = [["atMs": 100, "text": "Original embedded note"]]
            $0["speakers"] = [["id": "s1", "name": "Alice", "provenance": "user", "colourIndex": 0]]
            $0["transcript"] = ["status": "done", "reference": ["kind": "sidecar", "file": "transcript.json", "format": "cassini.words.v1"]]
        }
        let seedScanned = try #require(LibraryScanner(root: seedDir).scan().meetings.first)
        let seedArtifact = try MeetingFileExporter.cassini(seedScanned, assets: nil, temporaryRoot: root)
        let seedBytes = try Data(contentsOf: seedArtifact.url)
        let seedParsed = try CassiniReader.read(seedBytes)
        let baseManifest = try #require(seedParsed.manifest?.raw)
        let txBody = Data("{\"language\":\"en\",\"items\":[{\"speaker\":\"s1\",\"startMs\":0,\"endMs\":400,\"text\":\"Embedded original words\"}]}".utf8)
        let txSet = try PortableMeetingTags.transcripts(own: (txBody, "en", 1), carried: nil)
        let customTags = [Comment(name: "ARTIST", value: "Original Producer"), Comment(name: "DATE", value: "2025-05-06T07:08:09+02:00")]

        // (a) .unverified document (unknown matchPolicy) carrying embedded transcript & custom tags.
        let unverifiedIntegrity = try #require(baseManifest["integrity"]).setting("matchPolicy", to: .string("future-policy-v2"))
        let unverifiedManifest = try baseManifest.setting("integrity", to: unverifiedIntegrity)
        let unverifiedTags = try PortableMeetingTags.make(manifest: unverifiedManifest, transcripts: txSet, carriedTags: customTags)
        let unverifiedURL = root.appendingPathComponent("UnverifiedSource.opus")
        _ = try OpusStreamFile.rewrite(seedBytes, tags: unverifiedTags, to: unverifiedURL)
        #expect(try CassiniReader.read(contentsOf: unverifiedURL).state == .unverified)

        // (b) .staleAudio document (mismatched audio SHA-256) carrying embedded transcript & custom tags.
        let staleIntegrity = try #require(baseManifest["integrity"]).setting("opusAudioSha256", to: .string(String(repeating: "0", count: 64)))
        let staleManifest = try baseManifest.setting("integrity", to: staleIntegrity)
        let staleTags = try PortableMeetingTags.make(manifest: staleManifest, transcripts: txSet, carriedTags: customTags)
        let staleURL = root.appendingPathComponent("StaleSource.opus")
        _ = try OpusStreamFile.rewrite(seedBytes, tags: staleTags, to: staleURL)
        #expect(try CassiniReader.read(contentsOf: staleURL).state == .staleAudio)

        // (c) .unknownCassiniFormat document (CASSINI_FORMAT v2) carrying original payload & transcript tags.
        let v1Tags = try PortableMeetingTags.make(manifest: baseManifest, transcripts: txSet, carriedTags: customTags)
        var v2Tags = v1Tags
        let v1Marker = Data("CASSINI_FORMAT=org.cassini.portable-meeting/1".utf8)
        let v2Marker = Data("CASSINI_FORMAT=org.cassini.portable-meeting/2".utf8)
        let v1Range = try #require(v2Tags.range(of: v1Marker))
        v2Tags.replaceSubrange(v1Range, with: v2Marker)
        let unknownFormatURL = root.appendingPathComponent("FutureFormatSource.opus")
        _ = try OpusStreamFile.rewrite(seedBytes, tags: v2Tags, to: unknownFormatURL)
        #expect(try CassiniReader.read(contentsOf: unknownFormatURL).state == .unknownCassiniFormat)

        // (d) .invalidCassiniMetadata document (corrupted manifest SHA256) still carrying transcript chunks & custom tags.
        var invalidTags = v1Tags
        let payloadShaPrefix = Data("CASSINI_PAYLOAD_SHA256=".utf8)
        let shaRange = try #require(invalidTags.range(of: payloadShaPrefix))
        invalidTags.replaceSubrange(shaRange.upperBound..<(shaRange.upperBound + 64), with: Data(repeating: UInt8(ascii: "f"), count: 64))
        let invalidURL = root.appendingPathComponent("InvalidMetadataSource.opus")
        _ = try OpusStreamFile.rewrite(seedBytes, tags: invalidTags, to: invalidURL)
        #expect(try CassiniReader.read(contentsOf: invalidURL).state == .invalidCassiniMetadata)

        let nonOKSources: [(label: String, url: URL)] = [
            ("Renamed unverified", unverifiedURL),
            ("Renamed stale", staleURL),
            ("Renamed future format", unknownFormatURL),
            ("Renamed invalid metadata", invalidURL),
        ]

        var expectedRawBytesByEntryName: [String: Data] = [:]
        for item in nonOKSources {
            let expectedRaw = try Data(contentsOf: item.url)
            let imported = try LibraryImport.copy(item.url, into: library)
            // Apply local edits (rename + notes + quoteOverride) that previously triggered MeetingFileExporter.cassini!
            try MeetingMetadataWriter(directory: imported.folder, id: imported.id).transaction {
                $0["title"] = item.label
                $0["titleSource"] = "user"
                $0["notes"] = [["atMs": 500, "text": "Local note on non-OK source"]]
                $0["quoteOverride"] = ["atMs": 0, "text": "Pinned quote"]
            }
            expectedRawBytesByEntryName["\(item.label).opus"] = expectedRaw
        }

        let nonOKMeetings = try LibraryScanner(root: library).scan().meetings
        #expect(nonOKMeetings.count == 4)

        let nonOKZip = root.appendingPathComponent("NonOKEdited.zip")
        let exportedNonOK = try BulkZipExporter.export(nonOKMeetings, to: nonOKZip, assets: nil, temporaryRoot: stage)
        #expect(exportedNonOK == 4)

        // Zero staging directories should even be needed because all 4 non-OK sources go byte-for-byte!
        let nonOKEntries = try parseStoredZip(nonOKZip)
        #expect(nonOKEntries.count == 4)
        for entry in nonOKEntries {
            let expected = try #require(expectedRawBytesByEntryName[entry.name])
            #expect(entry.data == expected)
            // Verify transcript chunks and custom Vorbis tags survived untouched in every ZIP entry!
            let rawTags = try #require(CassiniReader.read(entry.data).tags)
            #expect(rawTags["ARTIST"] == "Original Producer")
            #expect(rawTags["DATE"] == "2025-05-06T07:08:09+02:00")
            #expect(rawTags.comments.contains { $0.name.hasPrefix("CASSINI_TX_") })
        }

        // Round-trip re-import into the same Library detects all 4 as duplicates (proving byte-for-byte fidelity),
        // and round-trip into a fresh Library preserves every embedded transcript payload and tag!
        var dupSummary = LibraryImportSummary()
        _ = try ZipArchiveImport.importArchive(nonOKZip, into: library, temporaryRoot: stage, summary: &dupSummary)
        #expect(dupSummary.imported == 0 && dupSummary.duplicates == 4 && dupSummary.failed == 0)

        let freshNonOKLib = root.appendingPathComponent("FreshNonOKLibrary")
        var freshSummary = LibraryImportSummary()
        _ = try ZipArchiveImport.importArchive(nonOKZip, into: freshNonOKLib, temporaryRoot: stage, summary: &freshSummary)
        #expect(freshSummary.imported == 4 && freshSummary.failed == 0)
        let reimportedStates = Set(try LibraryScanner(root: freshNonOKLib).scan().meetings.compactMap { m -> TrustState? in
            guard let audioURL = m.audioFiles.first else { return nil }
            let parsed = try? CassiniReader.read(contentsOf: audioURL)
            if parsed?.state == .unverified || parsed?.state == .staleAudio {
                #expect(parsed?.defaultTranscript?.load.transcript?.items.map(\.text) == ["Embedded original words"])
            }
            return parsed?.state
        })
        #expect(reimportedStates == [.unverified, .staleAudio, .unknownCassiniFormat, .invalidCassiniMetadata])

        // Now verify supported rebuilding paths (.ok with both original + local Mac transcripts, and .plainAudio with local transcript + tags):
        let rebuildLib = root.appendingPathComponent("RebuildLibrary")
        let okSourceURL = root.appendingPathComponent("TrustedSource.opus")
        _ = try OpusStreamFile.rewrite(seedBytes, tags: v1Tags, to: okSourceURL)
        #expect(try CassiniReader.read(contentsOf: okSourceURL).state == .ok)

        let importedOK = try LibraryImport.copy(okSourceURL, into: rebuildLib)
        try Data("{\"language\":\"en\",\"items\":[{\"speaker\":\"s2\",\"startMs\":100,\"endMs\":500,\"text\":\"Local Mac words\"}]}".utf8)
            .write(to: importedOK.folder.appendingPathComponent("transcript.json"))
        try MeetingMetadataWriter(directory: importedOK.folder, id: importedOK.id).transaction {
            $0["title"] = "Rebuilt OK with both transcripts"
            $0["titleSource"] = "user"
            $0["notes"] = [["atMs": 300, "text": "Added local note"]]
            $0["speakers"] = [["id": "s2", "name": "Dana", "provenance": "user", "colourIndex": 1]]
            $0["transcript"] = ["status": "done", "reference": ["kind": "sidecar", "file": "transcript.json", "format": "cassini.words.v1"], "model": "whistle"]
        }

        let plainTaggedURL = root.appendingPathComponent("PlainTagged.opus")
        _ = try OpusStreamFile.rewrite(
            Data(contentsOf: stereoTone),
            tags: PortableMeetingTags.packet(comments: customTags),
            to: plainTaggedURL
        )
        let importedPlain = try LibraryImport.copy(plainTaggedURL, into: rebuildLib)
        try Data("{\"language\":\"en\",\"items\":[{\"speaker\":\"p1\",\"startMs\":0,\"endMs\":300,\"text\":\"Plain transcribed words\"}]}".utf8)
            .write(to: importedPlain.folder.appendingPathComponent("transcript.json"))
        try MeetingMetadataWriter(directory: importedPlain.folder, id: importedPlain.id).transaction {
            $0["title"] = "Rebuilt plain with transcript"
            $0["titleSource"] = "user"
            $0["notes"] = [["atMs": 150, "text": "Plain note"]]
            $0["transcript"] = ["status": "done", "reference": ["kind": "sidecar", "file": "transcript.json", "format": "cassini.words.v1"], "model": "whistle"]
        }

        let rebuildZip = root.appendingPathComponent("SupportedRebuilds.zip")
        let rebuildMeetings = try LibraryScanner(root: rebuildLib).scan().meetings
        #expect(try BulkZipExporter.export(rebuildMeetings, to: rebuildZip, assets: nil, temporaryRoot: stage) == 2)

        let rebuiltByName = Dictionary(uniqueKeysWithValues: try parseStoredZip(rebuildZip).map { ($0.name, $0.data) })
        let rebuiltOK = try CassiniReader.read(#require(rebuiltByName["Rebuilt OK with both transcripts.opus"]))
        #expect(rebuiltOK.state == .ok)
        #expect(rebuiltOK.tags?["ARTIST"] == "Original Producer")
        #expect(rebuiltOK.tags?["DATE"] == "2025-05-06T07:08:09+02:00")
        #expect(rebuiltOK.transcripts.count == 2)
        #expect(rebuiltOK.defaultTranscript?.load.transcript?.items.map(\.text) == ["Local Mac words"])
        let carriedTranscripts = rebuiltOK.transcripts.filter { !$0.entry.isDefault }
        #expect(carriedTranscripts.count == 1)
        #expect(carriedTranscripts.first?.load.transcript?.items.map(\.text) == ["Embedded original words"])

        let rebuiltPlain = try CassiniReader.read(#require(rebuiltByName["Rebuilt plain with transcript.opus"]))
        #expect(rebuiltPlain.state == .ok)
        #expect(rebuiltPlain.tags?["ARTIST"] == "Original Producer")
        // D95: promoting a plain DATE keeps the exact instant and mirrors UTC.
        #expect(rebuiltPlain.manifest?.meeting.recordedAtUtc == "2025-05-06T05:08:09.000Z")
        #expect(rebuiltPlain.tags?["DATE"] == rebuiltPlain.manifest?.meeting.recordedAtUtc)
        #expect(rebuiltPlain.tags?["CASSINI_RECORDED_AT_UTC"] == rebuiltPlain.manifest?.meeting.recordedAtUtc)
        #expect(rebuiltPlain.defaultTranscript?.load.transcript?.items.map(\.text) == ["Plain transcribed words"])
    }

    // MARK: - 5. Concurrent Import + Export Event-Gated Overlap & Independent Cancellation

    private final class BlockingGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var entered = false
        private var released = false
        private var onEnter: (@Sendable () -> Void)?

        init(onEnter: @escaping @Sendable () -> Void) {
            self.onEnter = onEnter
        }

        func enterAndWait() {
            let signal: (@Sendable () -> Void)?
            condition.lock()
            if !entered {
                entered = true
                signal = onEnter
                onEnter = nil
            } else {
                signal = nil
            }
            signal?()
            while !released {
                condition.wait()
            }
            condition.unlock()
        }

        func release() {
            condition.lock()
            released = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private final class CancelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    @Test func concurrentImportAndExportKeepIndependentProgressAndCancelControls() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let stereoTone = try #require(Bundle.module.url(forResource: "stereo-tone", withExtension: "opus", subdirectory: "Fixtures"))
        let exportLib = root.appendingPathComponent("ExportLib")
        var exportMeetings: [LibraryMeeting] = []
        for idx in 1...2 {
            let src = root.appendingPathComponent("export-\(idx).opus")
            _ = try OpusStreamFile.rewrite(
                Data(contentsOf: stereoTone),
                tags: PortableMeetingTags.packet(comments: [Comment(name: "TITLE", value: "Export item \(idx)")]),
                to: src
            )
            exportMeetings.append(try LibraryImport.copy(src, into: exportLib))
        }

        let importInputs: [URL] = try (1...2).map { idx in
            let url = root.appendingPathComponent("import-\(idx).opus")
            _ = try OpusStreamFile.rewrite(
                Data(contentsOf: stereoTone),
                tags: PortableMeetingTags.packet(comments: [Comment(name: "TITLE", value: "Import item \(idx)")]),
                to: url
            )
            return url
        }

        // Overlap 1: Cancel export while concurrent import is running -> export aborts cleanly, import completes!
        let importLib1 = root.appendingPathComponent("ImportLib1")
        let zipOut1 = root.appendingPathComponent("Overlap1.zip")
        let exportCancel1 = CancelBox()
        let importCancel1 = CancelBox()

        let (exportStarted1, exportCont1) = AsyncStream<Void>.makeStream()
        let exportGate1 = BlockingGate { exportCont1.yield(()); exportCont1.finish() }
        let (importStarted1, importCont1) = AsyncStream<Void>.makeStream()
        let importGate1 = BlockingGate { importCont1.yield(()); importCont1.finish() }
        defer { exportGate1.release(); importGate1.release() }

        let exportTask1 = Task.detached {
            try BulkZipExporter.export(
                exportMeetings,
                to: zipOut1,
                assets: nil,
                onProgress: { done, _ in if done == 1 { exportGate1.enterAndWait() } },
                shouldCancel: { exportCancel1.isCancelled() }
            )
        }

        var eIter1 = exportStarted1.makeAsyncIterator()
        _ = await eIter1.next()

        let importTask1 = Task.detached { () throws -> LibraryImportSummary in
            var summary = LibraryImportSummary()
            return try LibraryBatchImport.importURLs(
                importInputs,
                into: importLib1,
                summary: &summary,
                onProgress: { done, _ in if done == 1 { importGate1.enterAndWait() } },
                shouldCancel: { importCancel1.isCancelled() }
            )
        }

        var iIter1 = importStarted1.makeAsyncIterator()
        _ = await iIter1.next()

        // While BOTH operations are simultaneously gated at 1/2, verify TransferBannerPresentation keeps BOTH controls!
        let bothActive = TransferBannerPresentation(
            importProgress: .init(done: 1, total: 2),
            bulkExportProgress: .init(done: 1, total: 2)
        )
        #expect(bothActive.cards == [
            .importProgress(done: 1, total: 2),
            .bulkExportProgress(done: 1, total: 2),
        ])
        #expect(bothActive.cards.map(\.primaryAccessibilityID) == ["import-progress", "export-zip-progress"])
        #expect(bothActive.cards.map(\.actionAccessibilityID) == ["import-cancel", "export-zip-cancel"])

        // Cancel ONLY export; import remains active and finishes cleanly.
        exportCancel1.cancel()
        exportGate1.release()
        await #expect(throws: CancellationError.self) {
            _ = try await exportTask1.value
        }
        #expect(!FileManager.default.fileExists(atPath: zipOut1.path))

        importGate1.release()
        let finishedImport1 = try await importTask1.value
        #expect(finishedImport1.imported == 2 && finishedImport1.failed == 0)

        // Overlap 2: Cancel import while concurrent export is running -> import stops with partial notice, export completes!
        let importLib2 = root.appendingPathComponent("ImportLib2")
        let zipOut2 = root.appendingPathComponent("Overlap2.zip")
        let exportCancel2 = CancelBox()
        let importCancel2 = CancelBox()

        let (exportStarted2, exportCont2) = AsyncStream<Void>.makeStream()
        let exportGate2 = BlockingGate { exportCont2.yield(()); exportCont2.finish() }
        let (importStarted2, importCont2) = AsyncStream<Void>.makeStream()
        let importGate2 = BlockingGate { importCont2.yield(()); importCont2.finish() }
        defer { exportGate2.release(); importGate2.release() }

        let exportTask2 = Task.detached {
            try BulkZipExporter.export(
                exportMeetings,
                to: zipOut2,
                assets: nil,
                onProgress: { done, _ in if done == 1 { exportGate2.enterAndWait() } },
                shouldCancel: { exportCancel2.isCancelled() }
            )
        }
        var eIter2 = exportStarted2.makeAsyncIterator()
        _ = await eIter2.next()

        let importTask2 = Task.detached { () throws -> LibraryImportSummary in
            var summary = LibraryImportSummary()
            return try LibraryBatchImport.importURLs(
                importInputs,
                into: importLib2,
                summary: &summary,
                onProgress: { done, _ in if done == 1 { importGate2.enterAndWait() } },
                shouldCancel: { importCancel2.isCancelled() }
            )
        }
        var iIter2 = importStarted2.makeAsyncIterator()
        _ = await iIter2.next()

        importCancel2.cancel()
        importGate2.release()
        await #expect(throws: CancellationError.self) {
            _ = try await importTask2.value
        }

        // While import shows its cancelled notice and export is still running, BOTH remain visible!
        let noticeID = UUID()
        let importDoneExportRunning = TransferBannerPresentation(
            importNotice: .init(id: noticeID, message: "Import cancelled", isWarning: false, autoDismiss: false),
            bulkExportProgress: .init(done: 1, total: 2)
        )
        #expect(importDoneExportRunning.cards.map(\.primaryAccessibilityID) == ["import-summary", "export-zip-progress"])
        #expect(importDoneExportRunning.cards.map(\.actionAccessibilityID) == ["import-notice-done", "export-zip-cancel"])

        exportGate2.release()
        let exported2 = try await exportTask2.value
        #expect(exported2 == 2)
        #expect(try parseStoredZip(zipOut2).count == 2)
    }

    @Test func timeoutCancellationDoesNotCloseBannerObservationStreamAcrossSubsequentTransitions() async throws {
        let (stream, continuation) = AsyncStream<[TransferBannerPresentation.Card]>.makeStream()
        defer { continuation.finish() }
        var iterator = stream.makeAsyncIterator()

        func waitForCards(
            matching predicate: ([TransferBannerPresentation.Card]) -> Bool
        ) async throws -> [TransferBannerPresentation.Card] {
            let (cancelledStream, cancelledCont) = AsyncStream<Void>.makeStream()
            let timeoutTask = Task { @MainActor in
                defer {
                    cancelledCont.yield(())
                    cancelledCont.finish()
                }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                continuation.finish()
            }
            while let cards = await iterator.next() {
                if predicate(cards) {
                    timeoutTask.cancel()
                    await timeoutTask.value
                    var cancelledIter = cancelledStream.makeAsyncIterator()
                    _ = await cancelledIter.next()
                    return cards
                }
            }
            timeoutTask.cancel()
            await timeoutTask.value
            throw POSIXError(.ETIMEDOUT)
        }

        // 1. Emit initial concurrent state and consume via timeout-guarded wait;
        // waitForCards cancels and awaits timeoutTask completion + explicit cleanup event before returning.
        continuation.yield(TransferBannerPresentation(
            importProgress: .init(done: 1, total: 2),
            bulkExportProgress: .init(done: 1, total: 2)
        ).cards)
        let first = try await waitForCards { cards in
            cards.map(\.primaryAccessibilityID) == ["import-progress", "export-zip-progress"]
        }
        #expect(first.map(\.actionAccessibilityID) == ["import-cancel", "export-zip-cancel"])

        // 2. Stream must remain open after cancelled timeoutTask completed and deliver subsequent transitions!
        continuation.yield(TransferBannerPresentation(
            importProgress: .init(done: 1, total: 2)
        ).cards)
        let second = try await waitForCards { cards in
            cards.map(\.primaryAccessibilityID) == ["import-progress"]
        }
        #expect(second.map(\.actionAccessibilityID) == ["import-cancel"])

        let receiptID = UUID()
        continuation.yield(TransferBannerPresentation(
            bulkExportReceipt: .init(id: receiptID, count: 3)
        ).cards)
        let third = try await waitForCards { cards in
            cards.map(\.primaryAccessibilityID) == ["export-zip-success"]
        }
        #expect(third.map(\.actionAccessibilityID) == ["export-zip-show"])
    }
}

private extension Data {
    func readU16LE(_ offset: Int) -> UInt16 {
        let b0 = UInt16(self[startIndex + offset])
        let b1 = UInt16(self[startIndex + offset + 1]) << 8
        return b0 | b1
    }

    func readU32LE(_ offset: Int) -> UInt32 {
        let b0 = UInt32(self[startIndex + offset])
        let b1 = UInt32(self[startIndex + offset + 1]) << 8
        let b2 = UInt32(self[startIndex + offset + 2]) << 16
        let b3 = UInt32(self[startIndex + offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }
}
