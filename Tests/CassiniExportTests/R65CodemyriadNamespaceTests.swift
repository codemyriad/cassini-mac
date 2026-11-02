// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
import CassiniLibrary
import CassiniRecording
@testable import CassiniExport

/// R65 (D55): x["codemyriad.io"] schema 1 per library-v2 MAPPING.md, and foreign copies of
/// it carried through import and re-export without a change.
struct R65CodemyriadNamespaceTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("R65-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url
    }
    private func raw(_ url: URL) throws -> JSON { try JSONParser.parse(Data(contentsOf:url)) }
    /// JSON value equality: object member order ignored, array order and number literals significant.
    private func same(_ a: JSON?, _ b: JSON?) -> Bool {
        switch (a,b) {
        case (nil,nil): return true
        case (.object(let x)?,.object(let y)?):
            guard x.count == y.count else { return false }
            return x.allSatisfy { pair in y.contains { $0.0 == pair.0 && same($0.1,pair.1) } }
        case (.array(let x)?,.array(let y)?): return x.count == y.count && zip(x,y).allSatisfy { same($0,$1) }
        default: return a == b
        }
    }
    /// MAPPING.md's rebuild rule.
    private func rebuild(_ x: JSON, notes: JSON?) -> JSON {
        var fields: [(String,JSON)] = [("id",x["sessionId"]!),("revision",x["revision"]!),("namePrefix",x["namePrefix"]!),("notes",notes ?? .array([]))]
        fields += x["meeting"]?.object ?? []
        fields += x["passthrough"]?.object ?? []
        if let source = x["namePrefixSource"] { fields.append(("namePrefixSource",source)) }
        return .object(fields)
    }
    private func recording(_ root: URL) throws -> (RecordingSession,LibraryMeeting) {
        let session = try RecordingSession(parent:root,title:"Weekly sync",source:"macos")
        try session.addTrack(id:"mic",label:"Me",kind:"microphone",sampleRate:16000,channels:1)
        try session.appendNative(id:"mic",pcm:Data(repeating:1,count:32000),offsetMs:0)
        try session.appendNative(id:"mic",pcm:Data(repeating:1,count:32000),offsetMs:2500,gapKind:"input")
        session.addDroppedFrames(id:"mic",frames:7)
        try session.finish()
        try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id).transaction { metadata in
            metadata["notes"] = [["atMs":1500,"text":"Decision","colour":"amber"]]
        }
        // A member this app does not know, with an integer above 2^53, must survive as written.
        let url = session.directory.appendingPathComponent("meeting.json")
        let body = try String(contentsOf:url,encoding:.utf8)
        try Data((body.dropLast(body.hasSuffix("\n") ? 2 : 1) + ",\"futureMember\":{\"big\":9007199254740993}}").utf8).write(to:url)
        return (session,try #require(LibraryScanner(root:root).scan().meetings.first))
    }

    @Test func aRecordingMirrorsMeetingJSONAndItsTracks() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (session,meeting) = try recording(root)
        let rome = try #require(TimeZone(identifier:"Europe/Rome"))
        let x = try #require(try CodemyriadNamespace.make(meeting,dateTag:nil,originalTitle:nil,now:Date(),zone:rome))
        let stored = try raw(session.directory.appendingPathComponent("meeting.json"))
        let manifest = try raw(session.directory.appendingPathComponent("session.json"))
        #expect(x["schema"] == .number("1") && x["origin"]?.string == "Recording")
        #expect(x["sessionId"] == stored["id"] && x["revision"] == stored["revision"])
        // No recorded UTC offset on Mac: the capture start in the Library device's zone.
        let expected = try LibraryNames.prefix(.capture(startUtc:try #require(manifest["createdAt"]?.string),utcOffsetMinutes:nil,libraryTimeZone:"Europe/Rome"))
        #expect(x["namePrefix"]?.string == expected.namePrefix && x["namePrefixSource"]?.string == "legacy-device-tz")
        #expect(LibraryNames.isPrefix(x["namePrefix"]?.string ?? ""))
        #expect(x["automaticTitle"]?.string == "Weekly sync")
        // Lossless: the unknown member keeps its exact integer.
        #expect(x["passthrough"]?["futureMember"]?["big"] == .number("9007199254740993"))
        let forbidden = Set(["id","revision","notes","namePrefix","namePrefixSource","published"] + CodemyriadNamespace.meetingMembers)
        #expect(!(x["passthrough"]?.object ?? []).contains { forbidden.contains($0.0) })
        // MAPPING's rebuild gives meeting.json back (notes come from x["gocassini.com"]), plus the
        // namePrefix names.py chose, since this v1 meeting.json had none.
        let chosen: [(String,JSON)] = [("namePrefix",x["namePrefix"]!),("namePrefixSource",x["namePrefixSource"]!)]
        #expect(stored["namePrefix"] == nil)
        #expect(same(rebuild(x,notes:stored["notes"]),.object((stored.object ?? []).filter { $0.0 != "published" } + chosen)))
        // Tracks: one span per session.json track, with its gap facts.
        let track = try #require(x["tracks"]?.array?.first), source = try #require(manifest["tracks"]?.array?.first)
        #expect(track["id"] == source["id"] && track["kind"]?.string == "microphone")
        let span = try #require(track["spans"]?.array?.first)
        #expect(span["file"] == source["file"] && span["sampleRate"] == source["sampleRate"] && span["frames"] == source["frames"])
        #expect(span["startOffsetMs"] == source["startOffsetMs"])
        #expect(track["gaps"] == source["gaps"] && track["gaps"]?.array?.isEmpty == false)
        #expect(track["droppedFrames"] == .number("7") && track["gapFrames"] == source["gapFrames"])
    }
    /// Through the real Opus export (assets supplied by the export CI job).
    @Test(.enabled(if:ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"] != nil))
    func anExportedRecordingCarriesTheNamespace() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (session,meeting) = try recording(root)
        let path = try #require(ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"])
        let directory = URL(fileURLWithPath:path)
        let hashes = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:directory.appendingPathComponent("unsigned-sha256.json")))
        let assets = try OpusAssets.builtForTests(directory:directory,expectedBinarySHA256:#require(hashes["libopus.0.dylib"]))
        let exported = try MeetingFileExporter.cassini(meeting,assets:assets,temporaryRoot:root)
        let file = try CassiniReader.read(contentsOf:exported.url)
        let x = try #require(file.manifest?.raw["x"]?["codemyriad.io"])
        let stored = try raw(session.directory.appendingPathComponent("meeting.json"))
        #expect(file.state == .ok && x["origin"]?.string == "Recording" && x["sessionId"] == stored["id"])
        #expect(x["tracks"]?.array?.count == 1)
        #expect(file.manifest?.raw["x"]?["gocassini.com"]?["notes"] == stored["notes"],"note objects verbatim, unknown members kept")
    }
    @Test func aPersistedNamePrefixIsKeptWithItsSource() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (session,_) = try recording(root)
        try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id).transaction { $0["namePrefix"] = "2026-10-30--18.02-"; $0["namePrefixSource"] = "recorded" }
        let meeting = try #require(LibraryScanner(root:root).scan().meetings.first)
        let x = try #require(try CodemyriadNamespace.make(meeting,dateTag:nil,originalTitle:nil,now:Date(),zone:.current))
        #expect(x["namePrefix"]?.string == "2026-10-30--18.02-" && x["namePrefixSource"]?.string == "recorded")
    }

    /// Another writer's namespace (GNOME schema 1, or a future schema) in a real Cassini file,
    /// imported into a Mac Library.
    private func foreignFile(_ root: URL, schema: Int, cleared: Bool = false) throws -> (namespace: JSON, meeting: LibraryMeeting) {
        let fixture = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        // A real Cassini file first (the fixture is plain Opus), then the namespace in it.
        let plain = try LibraryImport.copy(fixture,into:root.appendingPathComponent("Seed"))
        let seed = try MeetingFileExporter.cassini(plain,assets:nil,temporaryRoot:root)
        let bytes = try Data(contentsOf:seed.url)
        let manifest = try #require(CassiniReader.read(bytes).manifest?.raw)
        let foreign = try JSONParser.parse(Data("""
        {"schema":\(schema),"sessionId":"8B7D3C2E-5f1a-4c9e-9a6b-1d2e3f4a5b6c","origin":"Recording","namePrefix":"2026-10-30--18.02-","namePrefixSource":"recorded","revision":7,\
        "meeting":{"version":1,"title":null,"titleSource":"meeting-window","speakers":[{"id":"spk-me","name":"Me","provenance":"source","colourIndex":0,"futureSpeakerMember":1},{"id":"spk-1","name":null,"provenance":"unnamed","colourIndex":1\(cleared ? ",\"nameCleared\":true" : "")}],\
        "transcript":{"status":"none","reference":null},"etaMinutes":null,"error":null,"quoteOverride":null,"received":null,"recordingDetails":{"writingDown":{"x":1}}},\
        "passthrough":{"later":9007199254740993},"automaticTitle":"Weekly sync","tracks":[{"id":"t","spans":[{"file":"track.wav","sampleRate":48000,"frames":10,"startOffsetMs":12.5}],"futureTrackMember":true}],"unknownTop":[1,2]}
        """.utf8))
        let tags = try PortableMeetingTags.make(manifest:manifest.setting("x",to:.object([("codemyriad.io",foreign)])),transcript:Data("{\"items\":[]}".utf8),wordCount:0)
        let input = root.appendingPathComponent("gnome.opus")
        _ = try OpusStreamFile.rewrite(bytes,tags:tags,to:input)
        let imported = try LibraryImport.copy(input,into:root.appendingPathComponent("Library"))
        return (foreign,imported)
    }
    private func reexport(_ root: URL) throws -> JSON {
        let meeting = try #require(LibraryScanner(root:root.appendingPathComponent("Library")).scan().meetings.first)
        let exported = try MeetingFileExporter.cassini(meeting,assets:nil,temporaryRoot:root)
        return try #require(CassiniReader.read(contentsOf:exported.url).manifest?.raw["x"]?["codemyriad.io"])
    }
    /// Nothing changed on Mac: the namespace round-trips byte-for-byte, any schema.
    @Test(arguments:[1,2]) func anUnchangedForeignNamespaceRoundTripsByteForByte(schema: Int) throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (foreign,_) = try foreignFile(root,schema:schema)
        #expect(try reexport(root).encoded() == foreign.encoded())
    }
    /// D55.1: a rename and a speaker name set on Mac go into a schema-1 namespace in place,
    /// with a revision bump; every other member stays verbatim.
    @Test func macEditsGoIntoASchemaOneNamespaceAndNothingElseChanges() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (foreign,meeting) = try foreignFile(root,schema:1)
        try MeetingRename.apply("Renamed on Mac",to:meeting)
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction {
            $0["speakers"] = [["id":"spk-1","name":"Dana","provenance":"user","colourIndex":1]]
        }
        let result = try reexport(root)
        #expect(result["meeting"]?["title"]?.string == "Renamed on Mac" && result["meeting"]?["titleSource"]?.string == "user")
        #expect(result["revision"] == .number("8"))
        let speakers = try #require(result["meeting"]?["speakers"]?.array)
        #expect(speakers[1]["name"]?.string == "Dana" && speakers[1]["provenance"]?.string == "user")
        #expect(speakers[0] == foreign["meeting"]?["speakers"]?.array?[0],"an untouched speaker keeps unknown members")
        // Putting the three changed members back gives the original bytes.
        let restored = try result.setting("revision",to:foreign["revision"]).setting("meeting",to:result["meeting"]!
            .setting("title",to:.null).setting("titleSource",to:.string("meeting-window")).setting("speakers",to:foreign["meeting"]!["speakers"]))
        #expect(try restored.encoded() == foreign.encoded())
    }
    /// Naming on Mac a speaker another writer had cleared removes the clear (it goes only with unnamed).
    @Test func namingAClearedSpeakerRemovesTheClear() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (_,meeting) = try foreignFile(root,schema:1,cleared:true)
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction {
            $0["speakers"] = [["id":"spk-1","name":"Dana","provenance":"user","colourIndex":1]]
        }
        let speaker = try #require(reexport(root)["meeting"]?["speakers"]?.array?[1])
        #expect(speaker["name"]?.string == "Dana" && speaker["provenance"]?.string == "user" && speaker["nameCleared"] == nil)
    }
    /// Metadata this app cannot validate is never rewritten, and the namespace is still built.
    @Test func invalidMetadataIsLeftAloneAndDoesNotBlockTheNamespace() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (session,_) = try recording(root)
        let url = session.directory.appendingPathComponent("meeting.json")
        var stored = try #require(try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        stored["title"] = ""; stored["titleSource"] = "user"   // breaks the metadata rules
        let bytes = try JSONSerialization.data(withJSONObject:stored); try bytes.write(to:url)
        let meeting = try #require(LibraryScanner(root:root).scan().meetings.first)
        #expect(meeting.issues.contains(.invalidMetadata))
        try CodemyriadNamespace.persistNamePrefix(meeting,dateTag:nil,now:Date(),zone:.current)
        #expect(try Data(contentsOf:url) == bytes,"never rewritten")
        #expect(try CodemyriadNamespace.make(meeting,dateTag:nil,originalTitle:nil,now:Date(),zone:.current) != nil)
    }
    /// A schema this app does not know stays unchanged even after an edit.
    @Test func aFutureSchemaIsNeverRewritten() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (foreign,meeting) = try foreignFile(root,schema:2)
        try MeetingRename.apply("Renamed on Mac",to:meeting)
        #expect(try reexport(root).encoded() == foreign.encoded())
    }
    /// D55.1: the namePrefix is chosen on the first export, saved, and never recomputed.
    @Test func theNamePrefixIsSavedOnFirstExportAndKept() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let fixture = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        let imported = try LibraryImport.copy(fixture,into:root.appendingPathComponent("Library"))
        #expect(try raw(imported.folder.appendingPathComponent("meeting.json"))["namePrefix"] == nil)
        let first = try MeetingFileExporter.cassini(imported,assets:nil,temporaryRoot:root,timeZone:try #require(TimeZone(identifier:"Pacific/Kiritimati")))
        let saved = try raw(imported.folder.appendingPathComponent("meeting.json"))
        let prefix = try #require(saved["namePrefix"]?.string)
        #expect(LibraryNames.isPrefix(prefix) && saved["namePrefixSource"]?.string != nil)
        let firstX = try CassiniReader.read(Data(contentsOf:first.url)).manifest?.raw["x"]?["codemyriad.io"]
        #expect(firstX?["namePrefix"]?.string == prefix)
        let meeting = try #require(LibraryScanner(root:root.appendingPathComponent("Library")).scan().meetings.first)
        let again = try MeetingFileExporter.cassini(meeting,assets:nil,temporaryRoot:root,timeZone:try #require(TimeZone(identifier:"Pacific/Pago_Pago")))
        let againX = try CassiniReader.read(Data(contentsOf:again.url)).manifest?.raw["x"]?["codemyriad.io"]
        #expect(againX?["namePrefix"]?.string == prefix,"never recomputed")
        #expect(try raw(imported.folder.appendingPathComponent("meeting.json"))["namePrefix"]?.string == prefix)
    }
    /// A received file without our namespace gets one from Mac's meeting.json: origin
    /// Received, a date-tag namePrefix, the original title as automaticTitle, no tracks.
    @Test func aReceivedFileWithoutOurNamespaceGetsOne() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let fixture = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        let imported = try LibraryImport.copy(fixture,into:root.appendingPathComponent("Library"))
        let meeting = try #require(LibraryScanner(root:root.appendingPathComponent("Library")).scan().meetings.first)
        let file = try CassiniReader.read(contentsOf:fixture)
        let exported = try MeetingFileExporter.cassini(meeting,assets:nil,temporaryRoot:root,timeZone:try #require(TimeZone(identifier:"Europe/Rome")))
        let x = try #require(CassiniReader.read(contentsOf:exported.url).manifest?.raw["x"]?["codemyriad.io"])
        let stored = try raw(imported.folder.appendingPathComponent("meeting.json"))
        #expect(x["origin"]?.string == "Received" && x["sessionId"] == stored["id"] && x["tracks"] == nil)
        #expect(same(x["meeting"]?["received"],stored["received"]))
        let expected = try LibraryNames.prefix(.received(dateTag:file.tags?["DATE"],importUtc:"2026-01-01T00:00:00Z",libraryTimeZone:"Europe/Rome"))
        if expected.source == "date-tag" { #expect(x["namePrefix"]?.string == expected.namePrefix) }
        #expect(["date-tag","import-time"].contains(x["namePrefixSource"]?.string ?? ""))
        #expect(x["automaticTitle"]?.string == [file.manifest?.meeting.title,file.tags?["TITLE"]].compactMap { $0 }.first { !$0.isEmpty })
    }
}
