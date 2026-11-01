import Foundation
import Darwin
import Testing
import CryptoKit
import CassiniKit
@testable import CassiniLibrary

private let sidecar: [String: String] = ["kind": "sidecar", "file": "transcript.json", "format": "cassini.words.v1"]
private func body(_ f: Fixture, items: [[String: Any]] = [["speaker": "a", "startMs": 0, "endMs": 1000, "text": "Words"]]) throws {
    try JSONSerialization.data(withJSONObject: ["items": items]).write(to: f.folder.appendingPathComponent("transcript.json"), options: .atomic)
}
private func row(_ f: Fixture) throws -> LibraryMeeting { try #require(LibraryScanner(root: f.root).scan().meetings.first) }

@Suite struct LibraryD6RegressionTests {
    @Test(arguments: ["none", "queued", "running", "failed", "done", "damaged"])
    func transcriptStatusPrecedenceAndNoQuoteWithoutUsableWords(status: String) throws {
        let f = try Fixture()
        try f.metadata {
            $0["transcript"] = ["status": status, "reference": sidecar]
            $0["quoteOverride"] = ["atMs": 0, "text": "  \\\" remembered \\\"  "]
        }
        let missing = try row(f)
        #expect(missing.state.transcript.rawValue == (status == "done" ? "damaged" : status))
        #expect(missing.quote == nil)
        if status == "failed" { #expect(missing.state.error == MeetingIssue(id: "transcribe-failed", action: "Try again")) }
        if ["queued", "running"].contains(status) { #expect(missing.state.badge?.text == "Transcribing…") }
        try body(f)
        let readable = try row(f)
        #expect(readable.state.transcript.rawValue == status)
        #expect((readable.quote != nil) == ["queued", "running", "done"].contains(status))
        if status == "damaged" { #expect(readable.speakers.isEmpty && readable.state.error?.id == "transcript-damaged") }
    }
    @Test func invalidMetadataFallsBackAsAWholeButNewVersionsAreReadOnly() throws {
        let f = try Fixture(); try body(f)
        try f.metadata { $0.removeValue(forKey: "notes") }
        let invalid = try row(f)
        #expect(invalid.title != "Renamed" && invalid.issues.contains(.invalidMetadata))
        #expect(invalid.state.transcript == .done) // R2 absent/ignored sidecar fallback.
        try f.metadata { $0["version"] = 2 }
        let newer = try row(f)
        #expect(newer.metadataReadOnly && newer.issues.contains(.unsupportedVersion))
        #expect(!newer.issues.contains(.invalidMetadata) && newer.state.transcript == .done)
    }
    @Test func queuedNullEtaIsUnknownButInvalidEstimatesIgnoreMetadata() throws {
        let f = try Fixture()
        for eta: Any in [NSNull(), "bad", -1, 1.5] {
            try f.metadata { $0["transcript"] = ["status": "running", "reference": sidecar]; $0["etaMinutes"] = eta }
            let meeting = try row(f)
            if eta is NSNull {
                #expect(meeting.state.transcript == .running && meeting.state.etaMinutes == nil)
                #expect(meeting.state.badge?.text == "Transcribing…")
            } else {
                #expect(meeting.issues.contains(.invalidMetadata) && meeting.state.transcript == .none)
            }
        }
        try f.metadata {
            $0["transcript"] = ["status": "damaged", "reference": sidecar]
            $0["error"] = ["id": "transcribe-failed", "action": "Try again"]
        }
        let damaged = try row(f)
        #expect(damaged.state.error == MeetingIssue(id: "transcribe-failed", action: "Try again"))
        #expect(damaged.state.badge?.text == "Needs attention")
    }
    @Test func rootsAndNonRegularFilesCannotAliasOrBlockMeetings() throws {
        let f = try Fixture()
        let link = f.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.root)
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(try LibraryScanner(root: link).scan().meetings.count == 1)
        let child = f.root.appendingPathComponent("Recording-00000000-0000-0000-0000-000000000001")
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: f.folder)
        #expect(try LibraryScanner(root: f.root).scan().meetings.count == 1)
        let file = f.folder.appendingPathComponent("session.json")
        try FileManager.default.removeItem(at: file)
        #expect(mkfifo(file.path, 0o600) == 0)
        let recovered = try row(f)
        #expect(recovered.durationMs == 1000 && recovered.state.interruptedAtMs == 1000)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.root.appendingPathComponent("absent"))
        #expect(throws: (any Error).self) { try LibraryScanner(root: link).scan() }
    }
    @Test func noCountedAudioMeansUnknownEndAndNoWriteDown() throws {
        let f = try Fixture()
        try f.editCapture { $0["state"] = "interrupted"; $0["tracks"] = [] }
        let empty = try row(f)
        #expect(empty.durationMs == nil && empty.state.interruptedAtMs == nil && empty.state.badge == nil)
        #expect(!empty.canWriteDown)
        #expect(LibraryFormat.rowMeta(durationMs: nil, names: []) == "")
        #expect(LibraryFormat.rowMeta(durationMs: nil, names: ["Ada"]) == "Ada")
        let format = LibraryFormat(timeZone: TimeZone(secondsFromGMT: 0)!, now: Date(timeIntervalSince1970: 0),locale:Locale(identifier:"en_GB"),language:.en)
        #expect(format.previewSubtitle(Date(timeIntervalSince1970: 0), durationMs: nil) == "Today, 00:00")
    }
    @Test func firstSpeakingOrderIgnoresStoredColoursAndSilentSpeakersAndDoesNotJoinInterjections() throws {
        let f = try Fixture()
        try f.metadata {
            $0["transcript"] = ["status": "done", "reference": sidecar]
            $0["speakers"] = [["id": "silent", "name": "Not heard", "provenance": "user", "colourIndex": 0],
                              ["id": "a", "name": NSNull(), "provenance": "unnamed", "colourIndex": 99]]
        }
        try body(f, items: [
            ["speaker": "a", "startMs": 5300, "endMs": 20000, "text": " Second\n  part says \"yes\" "],
            ["speaker": "a", "startMs": 0, "endMs": 5000, "text": "First part"],
            ["speaker": "b", "startMs": 5000, "endMs": 5300, "text": "yeah"],
            ["speaker": "b", "startMs": 600000, "endMs": 999999, "text": "Excluded"]])
        let meeting = try row(f)
        #expect(meeting.speakerNames == ["Speaker 1", "Speaker 2"])
        #expect(meeting.speakers.map(\.colourIndex) == [0, 1])
        #expect(meeting.quote?.displayText == "“Second part says \"yes\"”")
        try f.metadata {
            $0["transcript"] = ["status": "done", "reference": sidecar]
            $0["quoteOverride"] = ["atMs": 12, "text": "  “ chosen\n words ”  "]
        }
        #expect(try row(f).quote?.displayText == "“chosen words”")
    }
    @Test func receivedReferencesAreExactAndUnchangedOpusIsVerifiedOnlyOnce() throws {
        let f = try Fixture(); let folder = try f.received()
        let url = folder.appendingPathComponent("original.opus")
        let imported: [String: Any] = ["originalName": "original.opus", "sha256": String(repeating: "0", count: 64), "importedAtMs": 0]
        #expect(try LibraryScanner(root: f.root).scan().meetings.isEmpty) // Import not committed.
        for reference in [["kind": "embedded", "file": "original.opus", "transcriptId": "missing"],
                          ["kind": "embedded", "file": "wrong.opus"]] {
            try f.metadata(in: folder, received: imported) { $0["transcript"] = ["status": "done", "reference": reference] }
            let meeting = try row(f)
            #expect(meeting.state.transcript == .damaged && meeting.speakers.isEmpty && meeting.quote == nil)
        }
        try f.metadata(in: folder, received: imported) {
            $0["transcript"] = ["status": "done", "reference": ["kind": "embedded", "file": "original.opus"]]
        }
        let scanner = LibraryScanner(root: f.root)
        #expect(try scanner.scan().meetings.first?.state.transcript == .done)
        _ = try scanner.scan(); #expect(try scanner.scan(affected: folder).meetings.count == 1)
        #expect(scanner.cache.parseCount(url) == 1)
        let beforeInfo = try #require(try pathInfo(url))
        let before = FileKey(beforeInfo)
        let replacement = folder.appendingPathComponent("replacement.opus")
        try Data(contentsOf: url).write(to: replacement)
        #expect(rename(replacement.path, url.path) == 0)
        let afterInfo = try #require(try pathInfo(url))
        #expect(FileKey(afterInfo) != before)
        #expect(try scanner.scan().meetings.count == 1)
        #expect(scanner.cache.parseCount(url) == 2) // Same bytes, new inode.
    }
    @Test func incrementalScanOnlyReplacesTheAffectedMeeting() throws {
        let f = try Fixture()
        let secondID = "00000000-0000-0000-0000-000000000002"
        let second = f.root.appendingPathComponent("Recording-" + secondID)
        try FileManager.default.copyItem(at: f.folder, to: second)
        func change(_ directory: URL, id: String, title: String) throws {
            let url = directory.appendingPathComponent("session.json")
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            json["id"] = id; json["title"] = title
            try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
        }
        try change(second, id: secondID, title: "Before")
        let scanner = LibraryScanner(root: f.root)
        #expect(try scanner.scan().meetings.count == 2)
        try change(second, id: secondID, title: "After")
        let incremental = try scanner.scan(affected: f.folder)
        #expect(incremental.meetings.count == 2)
        #expect(incremental.meetings.first { $0.id.uuidString.lowercased() == secondID }?.title == "Before")
        let full = try scanner.scan()
        #expect(full.meetings.first { $0.id.uuidString.lowercased() == secondID }?.title == "After")
    }
    @Test func staleReceivedAudioCannotClaimItsEmbeddedWordsOrHideTheAudio() throws {
        let f = try Fixture(); let folder = try f.received()
        let source = f.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/010-stale-audio.opus")
        try Data(contentsOf: source).write(to: folder.appendingPathComponent("original.opus"))
        try f.metadata(in: folder, received: ["originalName": "original.opus", "sha256": String(repeating: "0", count: 64), "importedAtMs": 0]) {
            $0["transcript"] = ["status": "done", "reference": ["kind": "embedded", "file": "original.opus"]]
        }
        let meeting = try row(f)
        #expect(meeting.state.transcript == .damaged && meeting.quote == nil)
        #expect(meeting.audioFiles.count == 1 && meeting.durationMs != nil)
    }

    @Test func fractionalDisplayEndsUseExactDecimalAndSampleRemainders() throws {
        // .75 ms plus .5 ms must carry into the next integer millisecond.
        let offset = try #require(DisplayOffset(try JSONParser.parse(Data("12.75".utf8))))
        #expect(offset.end(frames: 24, rate: 48000) == 13)
        #expect(offset.end(frames: 48, rate: 48000) == 13)
        let tinyBelow = try #require(DisplayOffset(try JSONParser.parse(Data("11.99999999999999999999999999999999999999999".utf8))))
        #expect(tinyBelow.end(frames: 0, rate: 48000) == 11)
        let edge = try #require(DisplayOffset(try JSONParser.parse(Data("0.125".utf8))))
        #expect(edge.end(frames: 7, rate: 8000) == 1)
        let exponential = try #require(DisplayOffset(try JSONParser.parse(Data("1275e-2".utf8))))
        #expect(exponential.end(frames: 24, rate: 48000) == 13)
    }
    @Test func sameUUIDUnderBothPrefixesIsTwoMeetingsAndReceivedNeedsMetadataObject() throws {
        let f = try Fixture()
        try f.editCapture { $0["createdAt"] = "1970-01-01T00:00:00Z"; $0["title"] = "Both" }
        let received = f.root.appendingPathComponent("Received-" + f.id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: received, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/002-plain-audio.opus"), to: received.appendingPathComponent("original.opus"))
        try f.metadata(in: received) // received:null is not a committed import.
        #expect(try LibraryScanner(root: f.root).scan().meetings.count == 1)
        try f.metadata(in: received, received: ["originalName": "original.opus", "sha256": String(repeating: "0", count: 64), "importedAtMs": 0]) { $0["title"] = "Both" }
        let meetings = try LibraryScanner(root: f.root).scan().meetings
        #expect(meetings.count == 2 && Set(meetings.map(\.id)).count == 1)
        #expect(Set(meetings.map(\.libraryKey)).count == 2)
        #expect(meetings.map(\.libraryKey) == [received.lastPathComponent, f.folder.lastPathComponent])
    }

}
