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
