// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Testing
@testable import CassiniKit
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
        let x = try #require(try CodemyriadNamespace.make(meeting,stored:CodemyriadNamespace.current(meeting) ?? .null,dateTag:nil,originalTitle:nil,now:Date(),zone:rome))
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
        let x = try #require(try CodemyriadNamespace.make(meeting,stored:CodemyriadNamespace.current(meeting) ?? .null,dateTag:nil,originalTitle:nil,now:Date(),zone:.current))
        #expect(x["namePrefix"]?.string == "2026-10-30--18.02-" && x["namePrefixSource"]?.string == "recorded")
    }

    /// Another writer's namespace (GNOME schema 1, or a future schema) in a real Cassini file,
    /// imported into a Mac Library.
    private func foreignFile(_ root: URL, schema: Int, cleared: Bool = false, revision: String = "7", notes: String? = nil, words: String = #"{"items":[]}"#, wordCount: Int = 0, moreSpeakers: String = "", title: String = "null", titleSource: String = "meeting-window") throws -> (namespace: JSON, meeting: LibraryMeeting) {
        let fixture = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        // A real Cassini file first (the fixture is plain Opus), then the namespace in it.
        let plain = try LibraryImport.copy(fixture,into:root.appendingPathComponent("Seed"))
        let seed = try MeetingFileExporter.cassini(plain,assets:nil,temporaryRoot:root)
        let bytes = try Data(contentsOf:seed.url)
        let manifest = try #require(CassiniReader.read(bytes).manifest?.raw)
        let foreign = try JSONParser.parse(Data("""
        {"schema":\(schema),"sessionId":"8B7D3C2E-5f1a-4c9e-9a6b-1d2e3f4a5b6c","origin":"Recording","namePrefix":"2026-10-30--18.02-","namePrefixSource":"recorded","revision":\(revision),\
        "meeting":{"version":1,"title":\(title),"titleSource":"\(titleSource)","speakers":[{"id":"spk-me","name":"Me","provenance":"source","colourIndex":0,"futureSpeakerMember":1},{"id":"spk-1","name":null,"provenance":"unnamed","colourIndex":1\(cleared ? ",\"nameCleared\":true" : "")}\(moreSpeakers)],\
        "transcript":{"status":"none","reference":null,"futureTranscriptMember":{"a":1}},"etaMinutes":null,"error":null,"quoteOverride":null,"received":null,"recordingDetails":{"writingDown":{"x":1}}},\
        "passthrough":{"later":9007199254740993},"automaticTitle":"Weekly sync","tracks":[{"id":"t","spans":[{"file":"track.wav","sampleRate":48000,"frames":10,"startOffsetMs":12.5}],"futureTrackMember":true}],"unknownTop":[1,2]}
        """.utf8))
        var x: [(String,JSON)] = [("codemyriad.io",foreign)]
        if let notes { x.append(("gocassini.com",.object([("notes",try JSONParser.parse(Data(notes.utf8)))]))) }
        let tags = try PortableMeetingTags.make(manifest:manifest.setting("x",to:.object(x)),transcript:Data(words.utf8),wordCount:wordCount)
        let input = root.appendingPathComponent("gnome.opus")
        _ = try OpusStreamFile.rewrite(bytes,tags:tags,to:input)
        let imported = try LibraryImport.copy(input,into:root.appendingPathComponent("Library"))
        return (foreign,imported)
    }
    private func reexport(_ root: URL) throws -> JSON { try #require(reexportFile(root).manifest?.raw["x"]?["codemyriad.io"]) }
    private func reexportFile(_ root: URL, snapshot: LibraryMeeting? = nil, afterRead: ((Int) throws -> Void)? = nil) throws -> CassiniFile {
        let meeting = try snapshot ?? #require(LibraryScanner(root:root.appendingPathComponent("Library")).scan().meetings.first)
        let exported = try MeetingFileExporter.cassini(meeting,assets:nil,temporaryRoot:root,timeZone:.current,shouldCancel:{ false },afterRead:afterRead)
        return try CassiniReader.read(contentsOf:exported.url)
    }
    /// Nothing changed on Mac: the namespace round-trips byte-for-byte, any schema.
    @Test func anUnchangedForeignNamespaceRoundTripsByteForByte() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (foreign,_) = try foreignFile(root,schema:1)
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
    /// #116 review: each exported change takes a new revision above the last one Mac
    /// exported (not only above the imported original), notes included; an unchanged
    /// re-export keeps it, and a revision never names two different contents.
    @Test func successiveEditsTakeNewRevisionsAndUnchangedReexportsKeepThem() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (foreign,meeting) = try foreignFile(root,schema:1)
        try MeetingRename.apply("First rename",to:meeting)
        let first = try reexport(root)
        #expect(first["revision"] == .number("8") && first["meeting"]?["title"]?.string == "First rename")
        #expect(try reexport(root).encoded() == first.encoded(),"an unchanged re-export is the same namespace")
        try MeetingRename.apply("Second rename",to:meeting)
        let second = try reexport(root)
        #expect(second["revision"] == .number("9") && second["meeting"]?["title"]?.string == "Second rename")
        // Notes live in x["gocassini.com"], but a rebuild reads them, so a notes-only edit is a change.
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction { $0["notes"] = [["atMs":1500,"text":"Decision"]] }
        let noted = try reexport(root)
        #expect(noted["revision"] == .number("10") && noted["meeting"] == second["meeting"])
        #expect(try reexport(root)["revision"] == .number("10"))
        // Going back to the original content is newer than every export before it.
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction {
            $0["notes"] = [Any](); $0["title"] = NSNull(); $0["titleSource"] = "meeting-window"
        }
        let reverted = try reexport(root)
        #expect(reverted["revision"] == .number("11"))
        #expect(try reverted.setting("revision",to:.number("7")).encoded() == foreign.encoded())
        // Mac-local bookkeeping: saved in meeting.json, never in any exported member.
        let stored = try raw(meeting.folder.appendingPathComponent("meeting.json"))
        #expect(stored[CodemyriadNamespace.baselineMember]?["revision"] == .number("11"))
        #expect(try !String(decoding:reverted.encoded(),as:UTF8.self).contains(CodemyriadNamespace.baselineMember))
    }
    /// A notes-only edit of a freshly imported file is a change too (it kept revision 7 before).
    @Test func aNotesOnlyEditAdvancesTheRevision() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (foreign,meeting) = try foreignFile(root,schema:1)
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction { $0["notes"] = [["atMs":200,"text":"Note"]] }
        let result = try reexport(root)
        #expect(result["revision"] == .number("8") && result["meeting"] == foreign["meeting"])
    }
    /// A change whose revision cannot be saved fails the export with its own error: the
    /// folder is app-owned, so an unwritable one is a fault (Coordinator, #116).
    @Test func anUnwritableFolderFailsTheExportWhenARevisionMustBeSaved() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (foreign,meeting) = try foreignFile(root,schema:1)
        let folder = meeting.folder.path
        // Unchanged: nothing to save, so a read-only folder still exports byte-for-byte.
        try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath:folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:folder) }
        #expect(try reexport(root).encoded() == foreign.encoded())
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:folder)
        try MeetingRename.apply("Renamed on Mac",to:meeting)
        try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath:folder)
        #expect { _ = try reexport(root) } throws:{ error in
            if case MeetingExportError.libraryFolderNotWritable = error { return true }; return false
        }
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:folder)
        #expect(try reexport(root)["revision"] == .number("8"),"no revision was used by the failed export")
    }
    /// What MeetingTranscriber writes to a received meeting's meeting.json (its publish and
    /// setStatus); the Export tests do not link the transcriber, whose recognition needs models.
    private func writeDown(_ meeting: LibraryMeeting, status: String, eta: Int? = nil, label: String = "Speaker 1") throws {
        let reference: [String:Any] = ["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]
        try Data(#"{"language":"en","items":[{"speaker":"track-original","startMs":0,"endMs":400,"text":"Hello"}]}"#.utf8)
            .write(to:meeting.folder.appendingPathComponent("transcript.json"))
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction { metadata in
            var transcript = metadata["transcript"] as? [String:Any] ?? [:]
            transcript["status"] = status; transcript["reference"] = reference; transcript["model"] = "parakeet-tdt-0.6b-v3"
            metadata["transcript"] = transcript
            metadata["etaMinutes"] = eta.map { $0 as Any } ?? NSNull(); metadata["error"] = NSNull()
            var speakers = metadata["speakers"] as? [[String:Any]] ?? []
            if !speakers.contains(where:{ $0["id"] as? String == "track-original" }) {
                speakers.append(["id":"track-original","name":NSNull(),"provenance":"unnamed","colourIndex":speakers.count])
            }
            speakers[0]["label"] = label
            metadata["speakers"] = speakers
            if status == "done" {
                metadata["recordingDetails"] = ["writingDown":["wallDurationMs":1200,"resumed":false,"speechSegments":1,
                                                               "speakerSeparation":["status":"skipped","reason":"unavailable"]]]
            }
        }
    }
    private func setStatus(_ meeting: LibraryMeeting, _ status: String) throws {
        // MeetingTranscriber.setStatus.
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction { metadata in
            var transcript = metadata["transcript"] as! [String:Any]
            if status == "queued", (transcript["status"] as? String) == "failed" { transcript["reference"] = NSNull() }
            transcript["status"] = status; metadata["transcript"] = transcript
            metadata["etaMinutes"] = NSNull()
            metadata["error"] = status == "failed" ? ["id":"transcribe-failed","action":"Try again"] : NSNull()
        }
    }
    /// #116 r2: import a schema-1 file with no transcript, Write down on Mac, export. The
    /// namespace carries Mac's transcription state, the speaker it added and its writingDown
    /// facts, keeps the other writer's unknown members, and takes a new revision.
    @Test func aWriteDownOnMacGoesIntoTheNamespace() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (foreign,meeting) = try foreignFile(root,schema:1)
        #expect(try reexport(root).encoded() == foreign.encoded(),"imported, nothing written down yet")
        try writeDown(meeting,status:"done")
        let scanned = try #require(LibraryScanner(root:root.appendingPathComponent("Library")).scan().meetings.first)
        let exported = try MeetingFileExporter.cassini(scanned,assets:nil,temporaryRoot:root)
        let file = try CassiniReader.read(contentsOf:exported.url)
        #expect(file.defaultTranscript?.load.transcript?.items.count == 1)
        let x = try #require(file.manifest?.raw["x"]?["codemyriad.io"])
        #expect(x["revision"] == .number("8"))
        let transcript = try #require(x["meeting"]?["transcript"])
        #expect(transcript["status"]?.string == "done" && transcript["model"]?.string == "parakeet-tdt-0.6b-v3")
        #expect(transcript["reference"]?["kind"]?.string == "sidecar")
        #expect(transcript["futureTranscriptMember"] == foreign["meeting"]?["transcript"]?["futureTranscriptMember"],"unknown member kept")
        #expect(x["meeting"]?["etaMinutes"] == .null && x["meeting"]?["error"] == .null)
        let speakers = try #require(x["meeting"]?["speakers"]?.array)
        try #require(speakers.compactMap { $0["id"]?.string } == ["spk-me","spk-1","track-original"],"Mac's new speaker appended")
        #expect(speakers[0] == foreign["meeting"]?["speakers"]?.array?[0],"an existing speaker keeps its unknown members")
        #expect(speakers[2]["label"]?.string == "Speaker 1" && speakers[2]["provenance"]?.string == "unnamed")
        let writing = try #require(x["meeting"]?["recordingDetails"]?["writingDown"])
        #expect(writing["x"] == .number("1"),"the other writer's unknown fact stays")
        #expect(writing["speechSegments"] == .number("1") && writing["speakerSeparation"]?["status"]?.string == "skipped")
        #expect(try reexport(root)["revision"] == .number("8"),"unchanged re-export")
    }
    /// A speaker id both writers use (track-original): Mac's Write down label replaces the
    /// other writer's, and the entry's other members stay.
    @Test func aSharedSpeakerIdTakesMacsLabel() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (_,meeting) = try foreignFile(root,schema:1,moreSpeakers:#",{"id":"track-original","name":null,"provenance":"unnamed","colourIndex":2,"label":"Other writer 1","futureX":1}"#)
        try writeDown(meeting,status:"done")
        let speakers = try #require(reexport(root)["meeting"]?["speakers"]?.array)
        try #require(speakers.count == 3)
        #expect(speakers[2]["label"]?.string == "Speaker 1" && speakers[2]["futureX"] == .number("1") && speakers[2]["colourIndex"] == .number("2"))
    }
    /// D70 item 11 / MAPPING Q2: a received meeting Mac wrote down, with a merge recorded in
    /// meeting.json. The file's own speakers stay first; Mac's words keep their ids in the body
    /// and in the manifest, each labelled with the name of the speaker it resolves to.
    @Test func mergedMacSpeakersShareTheirTargetsLabelInAReceivedFile() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (_,meeting) = try foreignFile(root,schema:1)
        try Data(#"{"language":"en","items":[{"speaker":"track-a","startMs":0,"endMs":400,"text":"Hello"},{"speaker":"track-c","startMs":500,"endMs":900,"text":"there"}]}"#.utf8)
            .write(to:meeting.folder.appendingPathComponent("transcript.json"))
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction { metadata in
            metadata["transcript"] = ["status":"done","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"],"model":"parakeet-tdt-0.6b-v3"]
            metadata["etaMinutes"] = NSNull(); metadata["error"] = NSNull()
            var speakers = metadata["speakers"] as? [[String:Any]] ?? []
            speakers += [["id":"track-a","name":NSNull(),"provenance":"unnamed","colourIndex":speakers.count,"label":"Speaker 1"],
                         ["id":"track-c","name":"Carla","provenance":"user","colourIndex":speakers.count + 1]]
            metadata["speakers"] = speakers
            metadata["speakerMerges"] = [["from":"track-a","into":"track-c"]]
            metadata["recordingDetails"] = ["writingDown":["wallDurationMs":1200,"resumed":false,"speechSegments":2,
                                                           "speakerSeparation":["status":"skipped","reason":"unavailable"]]]
        }
        let file = try reexportFile(root)
        let speakers = try #require(file.manifest?.raw["speakers"]?.array)
        let mine = speakers.filter { ["track-a","track-c"].contains($0["id"]?.string ?? "") }
        #expect(mine.map { $0["id"]?.string } == ["track-a","track-c"])
        #expect(mine.map { $0["label"]?.string } == ["Carla","Carla"],"merged ids share the target's name")
        #expect(file.defaultTranscript?.load.transcript?.items.map(\.speaker) == ["track-a","track-c"],"the body keeps its own ids")
    }
    /// Every Mac transcription state reaches the namespace with its own revision: failed with
    /// its error, a retry (queued, reference cleared), running with its estimate, then done.
    @Test func transcriptionStatesFollowTheLifecycle() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (_,meeting) = try foreignFile(root,schema:1)
        try writeDown(meeting,status:"running",eta:3)
        var x = try reexport(root)
        #expect(x["revision"] == .number("8") && x["meeting"]?["transcript"]?["status"]?.string == "running" && x["meeting"]?["etaMinutes"] == .number("3"))
        try setStatus(meeting,"failed")
        x = try reexport(root)
        #expect(x["revision"] == .number("9") && x["meeting"]?["transcript"]?["status"]?.string == "failed")
        #expect(x["meeting"]?["error"]?["id"]?.string == "transcribe-failed")
        try setStatus(meeting,"queued")
        x = try reexport(root)
        #expect(x["revision"] == .number("10") && x["meeting"]?["transcript"]?["reference"] == .null && x["meeting"]?["error"] == .null)
        try writeDown(meeting,status:"done")
        x = try reexport(root)
        #expect(x["revision"] == .number("11") && x["meeting"]?["transcript"]?["status"]?.string == "done" && x["meeting"]?["etaMinutes"] == .null)
    }
    /// A namespace whose meeting has no transcript member still gains Mac's transcription.
    @Test func aMissingTranscriptMemberGainsMacsState() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (foreign,meeting) = try foreignFile(root,schema:1)
        try writeDown(meeting,status:"done")
        // The same file, its namespace without meeting.transcript: build it directly.
        let stripped = try foreign.setting("meeting",to:foreign["meeting"]!.setting("transcript",to:nil))
        let current = try #require(LibraryScanner(root:root.appendingPathComponent("Library")).meeting(at:meeting.folder))
        let merged = try #require(try CodemyriadNamespace.merged(stripped,with:current,originalNotes:nil))
        #expect(merged.namespace["meeting"]?["transcript"]?["status"]?.string == "done")
        #expect(merged.namespace["revision"] != stripped["revision"])
    }
    /// A file that arrives transcribed keeps its namespace: the embedded reference import
    /// stores is not a Mac transcription.
    @Test func anImportedTranscriptIsNotAMacChange() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (foreign,meeting) = try foreignFile(root,schema:1,words:#"{"language":"en","items":[{"speaker":"spk-me","startMs":0,"endMs":400,"text":"Hello"}]}"#,wordCount:1)
        let stored = try raw(meeting.folder.appendingPathComponent("meeting.json"))
        #expect(stored["transcript"]?["status"]?.string == "done" && stored["transcript"]?["reference"]?["kind"]?.string == "embedded")
        #expect(try reexport(root).encoded() == foreign.encoded())
    }
    /// Notes the import normalised (an unknown member dropped, an invalid note skipped) are
    /// not a Mac edit: the unchanged file still comes back byte-for-byte at its revision.
    @Test func importNormalisedNotesAreNotAnEdit() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let notes = #"[{"atMs":1500,"text":"hi","id":"n-1"},{"atMs":-4,"text":"bad"}]"#
        let originalNotes = try JSONParser.parse(Data(notes.utf8))
        let (foreign,meeting) = try foreignFile(root,schema:1,notes:notes)
        let stored = try raw(meeting.folder.appendingPathComponent("meeting.json"))
        #expect(stored["notes"]?.array?.count == 1,"the import kept the valid note only")
        let file = try reexportFile(root)
        #expect(try file.manifest?.raw["x"]?["codemyriad.io"]?.encoded() == foreign.encoded())
        #expect(file.manifest?.raw["x"]?["gocassini.com"]?["notes"] == originalNotes,"the original note objects, unknown members included")
        #expect(try raw(meeting.folder.appendingPathComponent("meeting.json"))[CodemyriadNamespace.baselineMember] == nil)
        // A real notes edit after that is a change.
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction { $0["notes"] = [["atMs":1500,"text":"hi, edited"]] }
        #expect(try reexport(root)["revision"] == .number("8"))
    }
    /// #116 r3: unrelated edits keep the original note objects (unknown members included);
    /// only a notes edit writes Mac's own.
    @Test func originalNoteObjectsSurviveUnrelatedEdits() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let notes = try JSONParser.parse(Data(#"[{"atMs":1500,"text":"hi","id":"n-1"}]"#.utf8))
        let (_,meeting) = try foreignFile(root,schema:1,notes:#"[{"atMs":1500,"text":"hi","id":"n-1"}]"#)
        try MeetingRename.apply("Renamed on Mac",to:meeting)
        var file = try reexportFile(root)
        #expect(file.manifest?.raw["x"]?["codemyriad.io"]?["revision"] == .number("8"))
        #expect(file.manifest?.raw["x"]?["gocassini.com"]?["notes"] == notes)
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction { $0["notes"] = [["atMs":1500,"text":"hi, edited"]] }
        file = try reexportFile(root)
        #expect(file.manifest?.raw["x"]?["codemyriad.io"]?["revision"] == .number("9"))
        #expect(file.manifest?.raw["x"]?["gocassini.com"]?["notes"]?.array?.first?["text"]?.string == "hi, edited")
        #expect(file.manifest?.raw["x"]?["gocassini.com"]?["notes"]?.array?.first?["id"] == nil)
    }
    /// #116 r3: Export opened while Write down ran (the caller's snapshot has no words) and
    /// saved after it finished: the file carries the words and a namespace that says done,
    /// at a revision no other content has.
    @Test func aWriteDownFinishingBetweenOpeningExportAndSavingIsExportedWhole() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (_,meeting) = try foreignFile(root,schema:1)
        try writeDown(meeting,status:"running",eta:1)
        let early = try reexportFile(root)
        #expect(early.defaultTranscript?.load.transcript?.items.isEmpty == true)
        #expect(early.manifest?.raw["x"]?["codemyriad.io"]?["revision"] == .number("8"))
        // Export opens: the dialog's snapshot is taken while running.
        let opened = try #require(LibraryScanner(root:root.appendingPathComponent("Library")).scan().meetings.first)
        #expect(opened.state.transcript == .running)
        try writeDown(meeting,status:"done")
        let saved = try reexportFile(root,snapshot:opened)
        #expect(saved.defaultTranscript?.load.transcript?.items.map(\.text) == ["Hello"])
        let x = try #require(saved.manifest?.raw["x"]?["codemyriad.io"])
        #expect(x["meeting"]?["transcript"]?["status"]?.string == "done" && x["revision"] == .number("9"))
    }
    /// #116 r3: the Write down finishes after the export read the meeting and before its
    /// namespace was decided: the export reads again, and words and namespace agree.
    @Test func aWriteDownFinishingDuringTheExportIsReadAgain() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (_,meeting) = try foreignFile(root,schema:1)
        try writeDown(meeting,status:"running",eta:1)
        var attempts: [Int] = []
        let file = try reexportFile(root) { attempt in
            attempts.append(attempt)
            if attempt == 0 { try self.writeDown(meeting,status:"done") }
        }
        #expect(attempts == [0,1])
        #expect(file.defaultTranscript?.load.transcript?.items.map(\.text) == ["Hello"])
        let x = try #require(file.manifest?.raw["x"]?["codemyriad.io"])
        #expect(x["meeting"]?["transcript"]?["status"]?.string == "done" && x["revision"] == .number("8"))
        #expect(try reexport(root)["revision"] == .number("8"),"same words, same revision")
    }
    /// The same on our own namespace (a received file without one): its revision is
    /// meeting.json's, and it always comes from the read the words come from.
    @Test func ourOwnNamespaceComesFromTheReadItsWordsComeFrom() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let fixture = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        let meeting = try LibraryImport.copy(fixture,into:root.appendingPathComponent("Library"))
        try writeDown(meeting,status:"running",eta:1)
        var attempts: [Int] = []
        let file = try reexportFile(root) { attempt in
            attempts.append(attempt)
            if attempt == 0 { try self.writeDown(meeting,status:"done") }
        }
        let stored = try raw(meeting.folder.appendingPathComponent("meeting.json"))
        #expect(attempts == [0,1])
        #expect(file.defaultTranscript?.load.transcript?.items.map(\.text) == ["Hello"])
        let x = try #require(file.manifest?.raw["x"]?["codemyriad.io"])
        #expect(x["meeting"]?["transcript"]?["status"]?.string == "done" && x["revision"] == stored["revision"])
    }
    /// Export-path review: while the words aren't exported (a Write down still running), the
    /// manifest lists none of their speakers either.
    @Test func noSpeakersAreListedWithoutExportedWords() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (_,meeting) = try foreignFile(root,schema:1)
        try writeDown(meeting,status:"running",eta:2)
        let file = try reexportFile(root)
        #expect(file.defaultTranscript?.load.transcript?.items.isEmpty == true)
        #expect(file.manifest?.raw["speakers"]?.array?.isEmpty == true)
    }
    /// Export-path review: words the Library could read but no longer can are exported as
    /// damaged, never as done, and that takes a new revision.
    @Test func unreadableWordsAreExportedAsDamaged() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (_,meeting) = try foreignFile(root,schema:1)
        try writeDown(meeting,status:"done")
        #expect(try reexport(root)["revision"] == .number("8"))
        try FileManager.default.removeItem(at:meeting.folder.appendingPathComponent("transcript.json"))
        let file = try reexportFile(root)
        let x = try #require(file.manifest?.raw["x"]?["codemyriad.io"])
        #expect(file.defaultTranscript?.load.transcript?.items.isEmpty == true)
        #expect(x["meeting"]?["transcript"]?["status"]?.string == "damaged" && x["revision"] == .number("9"))
    }
    /// Export-path review: a title cleared on Mac shows, in the manifest and TITLE, what the
    /// namespace implies (meeting.title, then automaticTitle), not the original manifest title.
    @Test func aClearedTitleMatchesTheNamespace() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (_,meeting) = try foreignFile(root,schema:1,title:#""Design review""#,titleSource:"user")
        let scanned = try #require(LibraryScanner(root:root.appendingPathComponent("Library")).meeting(at:meeting.folder))
        try MeetingRename.apply("  ",to:scanned)
        let file = try reexportFile(root)
        let x = try #require(file.manifest?.raw["x"]?["codemyriad.io"])
        #expect(x["meeting"]?["title"] == .null && x["automaticTitle"]?.string == "Weekly sync")
        #expect(file.manifest?.meeting.title == "Weekly sync" && file.tags?["TITLE"] == "Weekly sync")
    }
    /// Export-path review: a file opened from outside the Library has nothing Mac can change:
    /// another writer's namespace and notes go out unchanged, and Mac makes none up.
    @Test func anExternalFileKeepsItsNamespaceAndNotesAndGetsNoneMadeUp() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let notes = #"[{"atMs":1500,"text":"hi","id":"n-1"}]"#
        let (foreign,_) = try foreignFile(root,schema:1,notes:notes)
        let input = root.appendingPathComponent("gnome.opus")
        let external = MeetingPresentation.external(try CassiniReader.read(contentsOf:input),url:input)
        let artifact = try MeetingFileExporter.cassini(external,assets:nil,temporaryRoot:root)
        let file = try CassiniReader.read(contentsOf:artifact.url)
        #expect(try file.manifest?.raw["x"]?["codemyriad.io"]?.encoded() == foreign.encoded())
        let parsedNotes = try JSONParser.parse(Data(notes.utf8))
        #expect(file.manifest?.raw["x"]?["gocassini.com"]?["notes"] == parsedNotes)
        let fixture = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        let plain = MeetingPresentation.external(try CassiniReader.read(contentsOf:fixture),url:fixture)
        let plainArtifact = try MeetingFileExporter.cassini(plain,assets:nil,temporaryRoot:root)
        let exported = try CassiniReader.read(contentsOf:plainArtifact.url)
        #expect(exported.state == .ok && exported.manifest?.raw["x"]?["codemyriad.io"] == nil)
    }
    /// Export-path review: a recording folder with transcript.json and no meeting.json (the
    /// Library reads it as done) keeps its words when the first export creates meeting.json.
    @Test func theFirstExportOfALegacyFolderKeepsItsWords() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Legacy",source:"macos")
        try session.addTrack(id:"mic",label:"Me",kind:"microphone",sampleRate:16000,channels:1)
        try session.appendNative(id:"mic",pcm:Data(repeating:1,count:32000),offsetMs:0)
        try session.finish()
        try? FileManager.default.removeItem(at:session.directory.appendingPathComponent("meeting.json"))
        try Data(#"{"language":"en","items":[{"speaker":"mic","startMs":0,"endMs":400,"text":"Hello"}]}"#.utf8)
            .write(to:session.directory.appendingPathComponent("transcript.json"))
        let before = try #require(LibraryScanner(root:root).scan().meetings.first)
        #expect(before.state.transcript == .done && before.transcriptItems.count == 1)
        try CodemyriadNamespace.persistNamePrefix(before,dateTag:nil,now:Date(),zone:.current)
        let after = try #require(LibraryScanner(root:root).scan().meetings.first)
        #expect(after.state.transcript == .done && after.transcriptItems.map(\.text) == ["Hello"])
        #expect(try raw(session.directory.appendingPathComponent("meeting.json"))["namePrefix"]?.string != nil)
    }
    /// D65: at the shared ceiling (2^53-1) an unchanged file still goes out unchanged, but a
    /// change, which would need a higher revision, is refused; past it (even Int.max) the
    /// namespace is refused outright.
    @Test func aRevisionThatCannotAdvanceIsRefused() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (foreign,meeting) = try foreignFile(root,schema:1,revision:"9007199254740991")
        #expect(try reexport(root).encoded() == foreign.encoded())
        try MeetingRename.apply("Renamed on Mac",to:meeting)
        #expect(refused(root))
        let beyond = try self.root(); defer { try? FileManager.default.removeItem(at:beyond) }
        _ = try foreignFile(beyond,schema:1,revision:"9223372036854775807")
        #expect(refused(beyond))
    }
    /// Every transcript payload tag (CASSINI_TX_…) of a file, as written.
    private func payloadTags(_ file: CassiniFile) -> [String] {
        (file.tags?.comments ?? []).filter { $0.name.uppercased().hasPrefix("CASSINI_TX_") }.map { $0.name + "=" + $0.value }.sorted()
    }
    /// #122 review: words Mac didn't write go out byte for byte, with every item fact Mac
    /// doesn't model (attribution), and the namespace keeps its revision.
    @Test func anUnchangedTranscriptKeepsItsAttributionFactsByteForByte() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let words = #"{"language":"en","items":[{"speaker":"spk-me","startMs":0,"endMs":400,"text":"Hello","lowConfidenceSpeaker":true,"attributionGapDb":4.5}]}"#
        let (foreign,meeting) = try foreignFile(root,schema:1,words:words,wordCount:1)
        let input = try CassiniReader.read(contentsOf:root.appendingPathComponent("gnome.opus"))
        let file = try reexportFile(root)
        #expect(payloadTags(file) == payloadTags(input) && !payloadTags(file).isEmpty)
        #expect(try file.manifest?.raw["x"]?["codemyriad.io"]?.encoded() == foreign.encoded(),"revision 7, unchanged")
        #expect(file.manifest?.raw["transcripts"] == input.manifest?.raw["transcripts"])
        // Also next to an unrelated edit: the payload is still the original's.
        try MeetingRename.apply("Renamed on Mac",to:meeting)
        let renamed = try reexportFile(root)
        #expect(payloadTags(renamed) == payloadTags(input))
        #expect(renamed.manifest?.raw["x"]?["codemyriad.io"]?["revision"] == .number("8"))
    }
    /// #122 review: a Library import of conformance vector 016 (two transcripts) exports both,
    /// byte for byte; after a Write down on Mac, Mac's words are the default and both originals
    /// stay beside them unchanged.
    @Test func everyOriginalTranscriptSurvivesALibraryReexport() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let input = try CassiniReader.read(contentsOf:vector("016-two-transcripts"))
        #expect(input.transcripts.count == 2)
        let meeting = try LibraryImport.copy(vector("016-two-transcripts"),into:root.appendingPathComponent("Library"))
        let file = try reexportFile(root)
        #expect(file.manifest?.transcripts.map(\.id) == ["raw-asr","second-pass"])
        #expect(file.manifest?.raw["transcripts"] == input.manifest?.raw["transcripts"])
        #expect(payloadTags(file) == payloadTags(input))
        #expect(file.tags?["CASSINI_TRANSCRIPT_IDS"] == "raw-asr,second-pass" && file.tags?["CASSINI_TRANSCRIPT_DEFAULT"] == input.tags?["CASSINI_TRANSCRIPT_DEFAULT"])
        try writeDown(meeting,status:"done")
        let written = try reexportFile(root)
        #expect(written.manifest?.transcripts.map(\.id) == ["script","raw-asr","second-pass"])
        #expect(written.manifest?.defaultTranscript?.id == "script" && written.defaultTranscript?.load.transcript?.items.map(\.text) == ["Hello"])
        #expect(written.manifest?.raw["transcripts"]?.array?.dropFirst().allSatisfy { $0["default"] == .bool(false) } == true)
        let originals = Set(payloadTags(input))
        #expect(originals.isSubset(of:Set(payloadTags(written))),"every original payload tag, byte for byte")
        #expect(written.transcripts.dropFirst().allSatisfy { $0.load.transcript != nil })
    }
    private func vector(_ name: String) -> URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CassiniKitTests/Conformance/opus/\(name).opus")
    }
    /// #122 review, MAPPING §6: what a received file carries that Mac doesn't model goes out
    /// unchanged: a top-level member and a speaker member (vector 014), and its own tags
    /// (vector 016: DATE, DESCRIPTION, ENCODER, CASSINI_DECODE_HINT).
    @Test func membersAndTagsMacDoesNotModelAreCarried() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let unknown = try CassiniReader.read(contentsOf:vector("014-unknown-manifest-member"))
        _ = try LibraryImport.copy(vector("014-unknown-manifest-member"),into:root.appendingPathComponent("Library"))
        let file = try reexportFile(root)
        #expect(file.manifest?.raw["cassiniFutureField"] != nil && file.manifest?.raw["cassiniFutureField"] == unknown.manifest?.raw["cassiniFutureField"])
        #expect(file.manifest?.raw["speakers"]?.array?.first?["pronouns"] == unknown.manifest?.raw["speakers"]?.array?.first?["pronouns"])
        #expect(file.manifest?.raw["speakers"]?.array?.first?["pronouns"] != nil)
        let tagged = try self.root(); defer { try? FileManager.default.removeItem(at:tagged) }
        let input = try CassiniReader.read(contentsOf:vector("016-two-transcripts"))
        _ = try LibraryImport.copy(vector("016-two-transcripts"),into:tagged.appendingPathComponent("Library"))
        let exported = try reexportFile(tagged)
        for name in ["DATE","DESCRIPTION","ENCODER","CASSINI_DECODE_HINT"] {
            #expect(exported.tags?[name] != nil && exported.tags?[name] == input.tags?[name],"\(name) carried")
        }
    }
    /// A copy of `source` with its manifest and tags changed, the manifest chunk set rebuilt.
    private func rewritten(_ source: URL, in root: URL, manifest change: (JSON) throws -> JSON,
                           comments edit: ([CassiniKit.Comment]) -> [CassiniKit.Comment] = { $0 }) throws -> URL {
        let data = try Data(contentsOf:source), file = try CassiniReader.read(data)
        let raw = try change(#require(file.manifest?.raw)).encoded(), compressed = try PortableMeetingTags.gzip(raw)
        let base64 = compressed.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        let bytes = Array(base64.utf8)
        let chunks = stride(from:0,to:bytes.count,by:4096).map { String(decoding:bytes[$0..<min($0 + 4096,bytes.count)],as:UTF8.self) }
        var comments = edit(file.tags?.comments ?? []).filter { !PortableMeetingTags.isChunk($0.name,of:"CASSINI_PAYLOAD_") }
        for (suffix,value) in [("MIME","application/vnd.cassini.portable-meeting+json"),("ENCODING",CassiniReader.encoding),("CHUNK_COUNT",String(chunks.count)),
                               ("SHA256",SHA256Hex(raw)),("RAW_BYTES",String(raw.count)),("GZIP_BYTES",String(compressed.count))] {
            comments.append(.init(name:"CASSINI_PAYLOAD_" + suffix,value:value))
        }
        for (index,chunk) in chunks.enumerated() { comments.append(.init(name:"CASSINI_PAYLOAD_" + String(format:"%03d",index),value:chunk)) }
        let output = root.appendingPathComponent("Shaped-\(UUID().uuidString).opus")
        _ = try OpusStreamFile.rewrite(data,tags:PortableMeetingTags.packet(comments:comments),to:output)
        #expect(try CassiniReader.read(contentsOf:output).state == .ok)
        return output
    }
    private func libraryExport(_ url: URL, _ root: URL, before: ((LibraryMeeting) throws -> Void)? = nil) throws -> CassiniFile {
        let meeting = try LibraryImport.copy(url,into:root.appendingPathComponent("Library"))
        try before?(meeting)
        return try reexportFile(root)
    }
    /// #122 follow-up review: display transcripts (readableTranscripts) keep their payloads, and a
    /// withdrawn one's missing tags stay missing (vector 026).
    @Test func displayTranscriptsKeepTheirPayloads() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let input = try CassiniReader.read(contentsOf:vector("026-display-and-withdrawn-cleanup"))
        let file = try libraryExport(vector("026-display-and-withdrawn-cleanup"),root)
        #expect(file.manifest?.raw["readableTranscripts"] == input.manifest?.raw["readableTranscripts"])
        #expect(payloadTags(file) == payloadTags(input) && payloadTags(file).contains { $0.hasPrefix("CASSINI_TX_DISPLAY_PAYLOAD_") })
    }
    /// Payload tags are matched exactly: a prefix outside CASSINI_TX_ and a prefix that begins
    /// another one are each carried once; an entry this app can't read (no payloadRef) stays.
    @Test func oddPayloadShapesAreCarriedExactlyOnce() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let shaped = try rewritten(vector("016-two-transcripts"),in:root,manifest:{ manifest in
            var entries = manifest["transcripts"]!.array!
            entries[0] = try entries[0].setting("payloadRef",to:entries[0]["payloadRef"]!.setting("prefix",to:.string("X_WORDS_PAYLOAD_")))
            entries[1] = try entries[1].setting("payloadRef",to:entries[1]["payloadRef"]!.setting("prefix",to:.string("X_WORDS_PAYLOAD_2_PAYLOAD_")))
            entries.append(.object([("id",.string("vtt")),("format",.string("text/vtt"))]))
            return try manifest.setting("transcripts",to:.array(entries))
        },comments:{ comments in comments.map { comment in
            var renamed = comment
            renamed.name = renamed.name.replacingOccurrences(of:"CASSINI_TX_RAW_ASR_PAYLOAD_",with:"X_WORDS_PAYLOAD_")
                .replacingOccurrences(of:"CASSINI_TX_SECOND_PASS_PAYLOAD_",with:"X_WORDS_PAYLOAD_2_PAYLOAD_")
            if renamed.name == "CASSINI_TRANSCRIPT_IDS" { renamed.value = "raw-asr,second-pass,vtt" }
            return renamed
        } })
        let input = try CassiniReader.read(contentsOf:shaped)
        #expect(input.transcripts.filter { $0.load.transcript != nil }.count == 2)
        let file = try libraryExport(shaped,root)
        let names = (file.tags?.comments ?? []).map(\.name)
        #expect(names.count == Set(names.map { $0.uppercased() }).count,"no tag written twice")
        #expect(file.manifest?.raw["transcripts"] == input.manifest?.raw["transcripts"])
        #expect(file.transcripts.filter { $0.load.transcript != nil }.count == 2)
    }
    /// A Write down still queued, running or failed adds no words: the originals go out as they
    /// are, the original default included.
    @Test func anUnfinishedWriteDownChangesNoTranscript() throws {
        for status in ["running","failed"] {
            let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
            let input = try CassiniReader.read(contentsOf:vector("016-two-transcripts"))
            let file = try libraryExport(vector("016-two-transcripts"),root) { meeting in
                try self.writeDown(meeting,status:"running",eta:1)
                if status == "failed" { try self.setStatus(meeting,"failed") }
            }
            #expect(file.manifest?.raw["transcripts"] == input.manifest?.raw["transcripts"],"\(status)")
            #expect(payloadTags(file) == payloadTags(input),"\(status)")
        }
    }
    /// A trusted plain Opus file's own tags go out with the export.
    @Test func aPlainOpusFileKeepsItsTags() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let input = try CassiniReader.read(contentsOf:vector("002-plain-audio"))
        let file = try libraryExport(vector("002-plain-audio"),root)
        for name in ["ARTIST","DATE","DESCRIPTION","ENCODER"] where input.tags?[name] != nil {
            #expect(file.tags?[name] == input.tags?[name],"\(name)")
        }
        #expect(input.tags?["ARTIST"] != nil || input.tags?["DATE"] != nil)
    }
    /// Speakers: carried words keep the original list (nothing appended); after a Write down the
    /// user's name for an original speaker still labels it, Mac's speakers follow, the ids tag
    /// is sorted, and the original provenance (about the old default's words) is gone.
    @Test func speakersAudioAndProvenanceFollowWhatTheFileCarries() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let shaped = try rewritten(vector("016-two-transcripts"),in:root,manifest:{ manifest in
            try manifest.setting("speakers",to:.array([])).setting("audio",to:manifest["audio"]!.setting("bitrateBps",to:.number("32000")))
                .setting("provenance",to:.object([("wordTimings",.object([("endsBoundedByAudio",.bool(true))]))]))
        },comments:{ $0.map { var c = $0; if c.name == "CASSINI_SPEAKER_COUNT" { c.value = "0" }; return c } })
        let carried = try libraryExport(shaped,root)
        #expect(carried.manifest?.raw["speakers"] == .array([]),"no speaker appended to carried words")
        #expect(carried.manifest?.raw["audio"]?["bitrateBps"] == .number("32000"))
        #expect(carried.manifest?.raw["provenance"] != nil)
        let named = try self.root(); defer { try? FileManager.default.removeItem(at:named) }
        let written = try libraryExport(vector("016-two-transcripts"),named) { meeting in
            try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction {
                $0["speakers"] = [["id":"spk_a","name":"Alice","provenance":"user","colourIndex":0]]
            }
            try self.writeDown(meeting,status:"done")
        }
        let speakers = try #require(written.manifest?.raw["speakers"]?.array)
        #expect(speakers.first { $0["id"]?.string == "spk_a" }?["label"]?.string == "Alice")
        #expect(speakers.contains { $0["id"]?.string == "track-original" })
        #expect(written.tags?["CASSINI_TRANSCRIPT_IDS"] == "raw-asr,script,second-pass")
        let provenanced = try self.root(); defer { try? FileManager.default.removeItem(at:provenanced) }
        let shapedAgain = try rewritten(vector("016-two-transcripts"),in:provenanced,manifest:{ try $0.setting("provenance",to:.object([("wordTimings",.object([("endsBoundedByAudio",.bool(true))]))])) })
        let mine = try libraryExport(shapedAgain,provenanced) { try self.writeDown($0,status:"done") }
        #expect(mine.manifest?.raw["provenance"] == nil)
    }
    /// #122 r2: a speaker renamed on Mac in a namespaced file Mac never wrote down: the
    /// manifest label and the namespace name agree, and the transcript payload is unchanged.
    @Test func aRenamedSpeakerAgreesInManifestAndNamespace() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let namespace = try JSONParser.parse(Data(#"{"schema":1,"sessionId":"8B7D3C2E-5f1a-4c9e-9a6b-1d2e3f4a5b6c","origin":"Recording","namePrefix":"2026-09-01--00.00-","revision":7,"meeting":{"version":1,"title":null,"titleSource":"meeting-window","speakers":[{"id":"spk_a","name":"Ada","provenance":"source","colourIndex":0},{"id":"spk_b","name":"Ben","provenance":"source","colourIndex":1}],"transcript":{"status":"done","reference":null}},"automaticTitle":"Conformance vector 001"}"#.utf8))
        let shaped = try rewritten(vector("016-two-transcripts"),in:root,manifest:{ try $0.setting("x",to:.object([("codemyriad.io",namespace)])) })
        let input = try CassiniReader.read(contentsOf:shaped)
        let file = try libraryExport(shaped,root) { meeting in
            try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction {
                $0["speakers"] = [["id":"spk_a","name":"Alice","provenance":"user","colourIndex":0]]
            }
        }
        let x = try #require(file.manifest?.raw["x"]?["codemyriad.io"])
        #expect(x["meeting"]?["speakers"]?.array?.first?["name"]?.string == "Alice" && x["revision"] == .number("8"))
        #expect(file.manifest?.raw["speakers"]?.array?.first { $0["id"]?.string == "spk_a" }?["label"]?.string == "Alice")
        #expect(file.manifest?.raw["speakers"]?.array?.first { $0["id"]?.string == "spk_b" }?["label"]?.string == "Ben")
        #expect(payloadTags(file) == payloadTags(input),"the transcript payloads are the original's")
    }
    /// #122 r3: every speaker edit Mac makes (rename, clear, rename after a clear, clear of another
    /// speaker), in turn, on a file whose namespace also carries edits Mac never makes (merges, a
    /// voice link): after each export the manifest label is what the namespace says (the name, or
    /// the unnamed label), the speakers' other members and the other writer's edits are unchanged,
    /// and the transcript payloads are the originals.
    @Test func everySpeakerEditAgreesInManifestAndNamespace() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let namespace = try JSONParser.parse(Data(#"{"schema":1,"sessionId":"8B7D3C2E-5f1a-4c9e-9a6b-1d2e3f4a5b6c","origin":"Recording","namePrefix":"2026-09-01--00.00-","revision":7,"meeting":{"version":1,"title":null,"titleSource":"meeting-window","speakers":[{"id":"spk_a","name":"Ada","provenance":"source","colourIndex":0,"voiceSource":{"ordinal":1}},{"id":"spk_b","name":"Ben","provenance":"source","colourIndex":1}],"speakerMerges":[{"from":"spk_c","into":"spk_b"}],"transcript":{"status":"done","reference":null}},"automaticTitle":"Conformance vector 001"}"#.utf8))
        let shaped = try rewritten(vector("016-two-transcripts"),in:root,manifest:{ manifest in
            let speakers = try manifest["speakers"]!.array!.map { try $0.setting("pronouns",to:.string("they")) }
            return try manifest.setting("speakers",to:.array(speakers)).setting("x",to:.object([("codemyriad.io",namespace)]))
        })
        let input = try CassiniReader.read(contentsOf:shaped)
        let meeting = try LibraryImport.copy(shaped,into:root.appendingPathComponent("Library"))
        func unnamed(_ position: Int) -> String { LibraryLocalization.shared.text("common.speaker.unnamed",["n":String(position)]) }
        let named: (String,String) -> [String:Any] = { id,name in ["id":id,"name":name,"provenance":"user","colourIndex":id == "spk_a" ? 0 : 1] }
        let clear: (String) -> [String:Any] = { id in ["id":id,"name":NSNull(),"provenance":"unnamed","nameCleared":true,"colourIndex":id == "spk_a" ? 0 : 1] }
        let edits: [(name: String, speakers: [[String:Any]], labels: [String:String])] = [
            ("rename",[named("spk_a","Alice")],["spk_a":"Alice","spk_b":"Ben"]),
            ("clear",[clear("spk_a")],["spk_a":unnamed(1),"spk_b":"Ben"]),
            ("rename after a clear",[named("spk_a","Alma")],["spk_a":"Alma","spk_b":"Ben"]),
            ("clear another speaker",[named("spk_a","Alma"),clear("spk_b")],["spk_a":"Alma","spk_b":unnamed(2)]),
        ]
        var revision = 7
        for edit in edits {
            try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction { $0["speakers"] = edit.speakers }
            let file = try reexportFile(root)
            let x = try #require(file.manifest?.raw["x"]?["codemyriad.io"],"\(edit.name)")
            let manifest = try #require(file.manifest?.raw["speakers"]?.array,"\(edit.name)")
            #expect(x["revision"]?.int ?? 0 > revision,"\(edit.name): a new revision"); revision = x["revision"]?.int ?? revision
            for entry in x["meeting"]?["speakers"]?.array ?? [] {
                let id = try #require(entry["id"]?.string)
                let label = manifest.first { $0["id"]?.string == id }?["label"]?.string
                #expect(label == edit.labels[id],"\(edit.name): \(id) labelled as the namespace says")
                #expect(label == (entry["name"]?.string ?? label),"\(edit.name): \(id) name and label agree")
                #expect(entry["nameCleared"] == (edit.labels[id] == unnamed(id == "spk_a" ? 1 : 2) ? .bool(true) : nil),"\(edit.name): \(id) clear recorded")
            }
            #expect(manifest.allSatisfy { $0["pronouns"]?.string == "they" },"\(edit.name): unknown speaker members kept")
            #expect(x["meeting"]?["speakerMerges"] == namespace["meeting"]?["speakerMerges"],"\(edit.name): merges kept")
            #expect(x["meeting"]?["speakers"]?.array?.first?["voiceSource"] == .object([("ordinal",.number("1"))]),"\(edit.name): voice link kept")
            #expect(payloadTags(file) == payloadTags(input),"\(edit.name): payloads unchanged")
        }
    }
    /// #116 CI: a read-only Library (a screenshot fixture, a read-only volume) is not an app-owned
    /// folder fault: its export goes out without a namespace of ours. Only a writable Library whose
    /// meeting folder can't be written refuses (D65).
    @Test func aReadOnlyLibraryExportsWithoutOurNamespace() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let fixture = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        let library = root.appendingPathComponent("Library")
        let meeting = try LibraryImport.copy(fixture,into:library)
        func lock(_ url: URL, _ mode: Int) throws { try FileManager.default.setAttributes([.posixPermissions:mode],ofItemAtPath:url.path) }
        defer { try? lock(meeting.folder,0o755); try? lock(library,0o755) }
        try lock(meeting.folder,0o555); try lock(library,0o555)
        let file = try reexportFile(root)
        #expect(file.state == .ok && file.manifest?.raw["x"]?["codemyriad.io"] == nil)
        // A writable Library with an unwritable meeting folder is a fault: refused.
        try lock(library,0o755)
        #expect(throws:MeetingExportError.libraryFolderNotWritable) { _ = try reexportFile(root) }
    }
    /// D65: a received file without a manifest or DATE is dated by its import, not its export.
    @Test func anUndatedReceivedFileIsDatedByItsImport() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let fixture = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        let input = try CassiniReader.read(contentsOf:fixture)
        let meeting = try LibraryImport.copy(fixture,into:root.appendingPathComponent("Library"))
        let imported = try #require(meeting.received?.importedAtMs)
        let file = try reexportFile(root)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        if input.tags?["DATE"] == nil {
            #expect(file.manifest?.meeting.createdAtUtc == iso.string(from:Date(timeIntervalSince1970:Double(imported) / 1000)))
            #expect(file.tags?["DATE"] == nil,"no DATE is made up")
        }
    }
    /// #133 review: a DATE whose offset is unknown (-00:00) or out of range names no instant
    /// under the shared rules (LibraryNames): the file is dated by its import, keeps its tag as it
    /// was, and its name doesn't come from it.
    @Test(arguments:["2026-03-04T09:15:00-00:00","2026-03-04T09:15:00+15:30"]) func anInvalidDateTagDoesNotDateTheFile(tag: String) throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let fixture = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        var tags = Data("OpusTags".utf8)
        func number(_ value: Int) { var little = UInt32(value).littleEndian; withUnsafeBytes(of:&little) { tags.append(contentsOf:$0) } }
        func text(_ value: String) { number(value.utf8.count); tags.append(Data(value.utf8)) }
        text("other encoder"); number(1); text("DATE=" + tag)
        let input = root.appendingPathComponent("odd-date.opus")
        _ = try OpusStreamFile.rewrite(Data(contentsOf:fixture),tags:tags,to:input)
        let meeting = try LibraryImport.copy(input,into:root.appendingPathComponent("Library"))
        let imported = try #require(meeting.received?.importedAtMs)
        let file = try reexportFile(root)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        #expect(file.manifest?.meeting.createdAtUtc == iso.string(from:Date(timeIntervalSince1970:Double(imported) / 1000)))
        #expect(file.tags?["DATE"] == tag,"the original tag is kept")
        #expect(file.manifest?.raw["x"]?["codemyriad.io"]?["namePrefixSource"]?.string == "import-time")
    }
    /// #133 review: an export from before D65 (its revision chosen without the creation time and
    /// DATE) is re-exported after the upgrade at a higher revision, then stays there unchanged.
    @Test func anEarlierExportIsReExportedAtAHigherRevision() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let fixture = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        let meeting = try LibraryImport.copy(fixture,into:root.appendingPathComponent("Library"))
        let first = try reexportFile(root)
        // What an earlier build stored for that same content: the digest it computed, of the
        // manifest without its creation time (and no DATE), then the transcripts' digest.
        let manifest = try #require(first.manifest?.raw)
        var content = try manifest.setting("transcripts",to:nil)
        content = try content.setting("meeting",to:content["meeting"]!.setting("createdAtUtc",to:nil))
        let x = try #require(content["x"])
        content = try content.setting("x",to:x.setting("codemyriad.io",to:x["codemyriad.io"]!.setting("revision",to:nil)))
        var transcripts = CryptoKit.SHA256()
        transcripts.update(data:try (manifest["transcripts"] ?? .array([])).encoded())
        let prefixes = (manifest["transcripts"]?.array ?? []).compactMap { $0["payloadRef"]?["prefix"]?.string }
        for comment in (first.tags?.comments ?? []) where prefixes.contains(where:{ PortableMeetingTags.isChunk(comment.name,of:$0) }) {
            transcripts.update(data:Data((comment.name + "=" + comment.value + "\n").utf8))
        }
        var data = try content.encoded(); data.append(0)
        data.append(Data(transcripts.finalize().map { String(format:"%02x",$0) }.joined().utf8))
        let earlierDigest = SHA256Hex(data)
        let url = meeting.folder.appendingPathComponent("meeting.json")
        let current = try #require(try raw(url)["revision"]?.int)
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction {
            $0[CodemyriadNamespace.baselineMember] = ["own":["revision":current + 1,"sha256":earlierDigest]]
        }
        let earlier = current + 1
        let upgraded = try reexport(root)
        #expect(upgraded["revision"]?.int ?? 0 > earlier,"a higher revision than the earlier export's")
        #expect(try reexport(root)["revision"] == upgraded["revision"],"then stable while nothing changes")
    }
    /// D65: a Mac recording's creation time and DATE are its recording start, never the export
    /// time. (Assets: the export CI job.)
    @Test(.enabled(if:ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"] != nil))
    func aRecordingIsDatedByItsStart() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (_,meeting) = try recording(root)
        let start = try #require(meeting.start)
        let path = try #require(ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"])
        let directory = URL(fileURLWithPath:path)
        let hashes = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:directory.appendingPathComponent("unsigned-sha256.json")))
        let assets = try OpusAssets.builtForTests(directory:directory,expectedBinarySHA256:#require(hashes["libopus.0.dylib"]))
        let rome = try #require(TimeZone(identifier:"Europe/Rome"))
        let exported = try MeetingFileExporter.cassini(meeting,assets:assets,temporaryRoot:root,timeZone:rome)
        let file = try CassiniReader.read(contentsOf:exported.url)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        #expect(file.manifest?.meeting.createdAtUtc == iso.string(from:start))
        #expect(file.tags?["DATE"] == MeetingFileExporter.dateTag(start,zone:rome))
    }
    /// #116 r4: our own namespace never describes two contents at one revision: words that
    /// become unreadable (damaged) take a new revision, and so do the same words restored;
    /// an unchanged re-export keeps it.
    @Test func ourOwnNamespaceAdvancesWhenItsContentChangesAtOneRevision() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let fixture = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        let meeting = try LibraryImport.copy(fixture,into:root.appendingPathComponent("Library"))
        try writeDown(meeting,status:"done")
        func export() throws -> (file: CassiniFile, revision: JSON?) {
            let file = try reexportFile(root)
            return (file,file.manifest?.raw["x"]?["codemyriad.io"]?["revision"])
        }
        let done = try export()
        #expect(done.file.defaultTranscript?.load.transcript?.items.count == 1)
        #expect(try export().revision == done.revision,"unchanged re-export")
        let sidecar = meeting.folder.appendingPathComponent("transcript.json")
        let words = try Data(contentsOf:sidecar)
        try FileManager.default.removeItem(at:sidecar)
        let damaged = try export()
        #expect(damaged.file.manifest?.raw["x"]?["codemyriad.io"]?["meeting"]?["transcript"]?["status"]?.string == "damaged")
        #expect(damaged.revision != done.revision && damaged.revision?.int ?? 0 > done.revision?.int ?? 0)
        try words.write(to:sidecar)
        let restored = try export()
        #expect(restored.file.defaultTranscript?.load.transcript?.items.count == 1)
        #expect(restored.revision?.int ?? 0 > damaged.revision?.int ?? 0)
        // meeting.json carries every revision it exported.
        #expect(try raw(meeting.folder.appendingPathComponent("meeting.json"))["revision"] == restored.revision)
    }
    /// r4 follow-up review: a recording whose meeting.json Mac may not rewrite (invalid here) can
    /// keep no baseline, so its export carries no namespace of ours: its words, read from
    /// transcript.json, could change under one revision. (Assets: the export CI job.)
    @Test(.enabled(if:ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"] != nil))
    func invalidMetadataGetsNoNamespaceOfOurs() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (session,_) = try recording(root)
        let url = session.directory.appendingPathComponent("meeting.json")
        var stored = try #require(try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        stored["title"] = ""; stored["titleSource"] = "user"   // breaks the metadata rules
        try JSONSerialization.data(withJSONObject:stored).write(to:url)
        let meeting = try #require(LibraryScanner(root:root).scan().meetings.first)
        #expect(meeting.issues.contains(.invalidMetadata))
        let path = try #require(ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"])
        let directory = URL(fileURLWithPath:path)
        let hashes = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:directory.appendingPathComponent("unsigned-sha256.json")))
        let assets = try OpusAssets.builtForTests(directory:directory,expectedBinarySHA256:#require(hashes["libopus.0.dylib"]))
        let exported = try MeetingFileExporter.cassini(meeting,assets:assets,temporaryRoot:root)
        let file = try CassiniReader.read(contentsOf:exported.url)
        #expect(file.state == .ok && file.manifest?.raw["x"]?["codemyriad.io"] == nil)
    }
    /// A trusted file opened from outside the Library with our namespace in `namespace`,
    /// built from conformance vector 016 (two transcripts) when `twoTranscripts`.
    private func externalFile(_ root: URL, namespace: String, twoTranscripts: Bool = false) throws -> URL {
        let url: URL
        if twoTranscripts {
            url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("CassiniKitTests/Conformance/opus/016-two-transcripts.opus")
        } else {
            url = try foreignFileURL(root)
        }
        let data = try Data(contentsOf:url)
        let file = try CassiniReader.read(data)
        var manifest = try #require(file.manifest?.raw)
        manifest = try manifest.setting("x",to:.object([("codemyriad.io",JSONParser.parse(Data(namespace.utf8)))]))
        // Replace only the manifest chunk set; every transcript keeps its own tags.
        let raw = try manifest.encoded(), compressed = try PortableMeetingTags.gzip(raw)
        let base64 = compressed.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        let bytes = Array(base64.utf8)
        let chunks = stride(from:0,to:bytes.count,by:4096).map { String(decoding:bytes[$0..<min($0 + 4096,bytes.count)],as:UTF8.self) }
        // Only the manifest chunk set (its descriptors and numbered chunks), not CASSINI_PAYLOAD_SCHEMA.
        let chunkSet = Set(["MIME","ENCODING","CHUNK_COUNT","SHA256","RAW_BYTES","GZIP_BYTES"])
        var comments = (file.tags?.comments ?? []).filter { comment in
            let name = comment.name.uppercased()
            guard name.hasPrefix("CASSINI_PAYLOAD_") else { return true }
            let suffix = String(name.dropFirst("CASSINI_PAYLOAD_".count))
            return !(chunkSet.contains(suffix) || suffix.allSatisfy(\.isNumber))
        }
        let sha = SHA256Hex(raw)
        for (suffix,value) in [("MIME","application/vnd.cassini.portable-meeting+json"),("ENCODING",CassiniReader.encoding),("CHUNK_COUNT",String(chunks.count)),
                               ("SHA256",sha),("RAW_BYTES",String(raw.count)),("GZIP_BYTES",String(compressed.count))] {
            comments.append(.init(name:"CASSINI_PAYLOAD_" + suffix,value:value))
        }
        for (index,chunk) in chunks.enumerated() { comments.append(.init(name:"CASSINI_PAYLOAD_" + String(format:"%03d",index),value:chunk)) }
        let output = root.appendingPathComponent("External-\(UUID().uuidString).opus")
        _ = try OpusStreamFile.rewrite(data,tags:PortableMeetingTags.packet(comments:comments),to:output)
        return output
    }
    private func foreignFileURL(_ root: URL) throws -> URL {
        let fixture = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        let plain = try LibraryImport.copy(fixture,into:root.appendingPathComponent("Seed-\(UUID().uuidString)"))
        let seed = try MeetingFileExporter.cassini(plain,assets:nil,temporaryRoot:root)
        let url = root.appendingPathComponent("seed-\(UUID().uuidString).opus")
        try FileManager.default.copyItem(at:seed.url,to:url)
        return url
    }
    private let validNamespace = #"{"schema":1,"sessionId":"s","origin":"Recording","namePrefix":"2026-10-30--18.02-","revision":REV,"meeting":{"version":1,"title":null}}"#
    /// #116 r4: an external file's namespace is checked before anything else (D65): a malformed
    /// or out-of-range revision is refused like an unknown schema.
    @Test(arguments:["-1","1.5","\"7\"","9007199254740992"]) func anExternalFileWithAnInvalidRevisionIsRefused(revision: String) throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let url = try externalFile(root,namespace:validNamespace.replacingOccurrences(of:"REV",with:revision))
        let external = MeetingPresentation.external(try CassiniReader.read(contentsOf:url),url:url)
        #expect(throws:MeetingExportError.newerFormat) { _ = try MeetingFileExporter.cassini(external,assets:nil,temporaryRoot:root) }
    }
    /// #116 r4: a valid one, even at the ceiling and with two transcripts, goes out
    /// byte-for-byte: no transcript is dropped under its revision.
    @Test(arguments:[false,true]) func anExternalFileWithOurNamespaceGoesOutByteForByte(twoTranscripts: Bool) throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let url = try externalFile(root,namespace:validNamespace.replacingOccurrences(of:"REV",with:"9007199254740991"),twoTranscripts:twoTranscripts)
        let input = try CassiniReader.read(contentsOf:url)
        #expect(input.state == .ok && input.transcripts.count == (twoTranscripts ? 2 : 1))
        let artifact = try MeetingFileExporter.cassini(MeetingPresentation.external(input,url:url),assets:nil,temporaryRoot:root)
        #expect(try Data(contentsOf:artifact.url) == Data(contentsOf:url))
    }
    /// D65 (Q6b): a recording without a title saves the untitled fallback, in the language of
    /// its first export, and keeps it: a later export in another language changes nothing.
    @Test func theUntitledFallbackIsSavedOnFirstExportAndKept() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"",source:"macos")
        try session.addTrack(id:"mic",label:"Me",kind:"microphone",sampleRate:16000,channels:1)
        try session.appendNative(id:"mic",pcm:Data(repeating:1,count:32000),offsetMs:0)
        try session.finish()
        var meeting = try #require(LibraryScanner(root:root).scan().meetings.first)
        #expect(meeting.titleIsUntitled)
        try CodemyriadNamespace.persistNamePrefix(meeting,dateTag:nil,now:Date(),zone:.current)
        let url = session.directory.appendingPathComponent("meeting.json")
        let first = try raw(url)
        #expect(CodemyriadNamespace.untitled(first) == meeting.title && first["title"] == .null)
        // The app's language changes: the saved fallback stays.
        meeting.title = "Senza titolo"
        try CodemyriadNamespace.persistNamePrefix(meeting,dateTag:nil,now:Date(),zone:.current)
        #expect(CodemyriadNamespace.untitled(try raw(url)) == CodemyriadNamespace.untitled(first))
        // Never exported, and the namespace's own title stays null.
        let x = try #require(try CodemyriadNamespace.make(meeting,stored:raw(url),dateTag:nil,originalTitle:nil,now:Date(),zone:.current))
        #expect(x["meeting"]?["title"] == .null && x["passthrough"]?[CodemyriadNamespace.baselineMember] == nil)
    }
    /// The same through the real Opus export (assets supplied by the export CI job): TITLE and
    /// the manifest title are the saved fallback, not the current language's.
    @Test(.enabled(if:ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"] != nil))
    func anExportedUntitledRecordingKeepsItsFirstTitle() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"",source:"macos")
        try session.addTrack(id:"mic",label:"Me",kind:"microphone",sampleRate:16000,channels:1)
        try session.appendNative(id:"mic",pcm:Data(repeating:1,count:32000),offsetMs:0)
        try session.finish()
        // As if the first export ran in Italian.
        try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id).transaction {
            $0[CodemyriadNamespace.baselineMember] = ["untitledTitle":"Senza titolo"]
        }
        let path = try #require(ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"])
        let directory = URL(fileURLWithPath:path)
        let hashes = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:directory.appendingPathComponent("unsigned-sha256.json")))
        let assets = try OpusAssets.builtForTests(directory:directory,expectedBinarySHA256:#require(hashes["libopus.0.dylib"]))
        let meeting = try #require(LibraryScanner(root:root).scan().meetings.first)
        let exported = try MeetingFileExporter.cassini(meeting,assets:assets,temporaryRoot:root)
        let file = try CassiniReader.read(contentsOf:exported.url)
        #expect(file.manifest?.meeting.title == "Senza titolo" && file.tags?["TITLE"] == "Senza titolo")
        #expect(file.manifest?.raw["x"]?["codemyriad.io"]?["meeting"]?["title"] == .null)
    }
    /// A plain Opus file's DATE and TITLE tags name and title its first export (#116 review).
    @Test func aTaggedPlainOpusFileKeepsItsDateAndTitle() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let fixture = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        // A plain OpusTags packet: vendor, then two comments (little-endian lengths).
        var tags = Data("OpusTags".utf8)
        func number(_ value: Int) { var little = UInt32(value).littleEndian; withUnsafeBytes(of:&little) { tags.append(contentsOf:$0) } }
        func text(_ value: String) { number(value.utf8.count); tags.append(Data(value.utf8)) }
        text("other encoder"); number(2); text("DATE=2026-03-04T09:15:00+01:00"); text("TITLE=  Board review \n")
        let input = root.appendingPathComponent("tagged.opus")
        _ = try OpusStreamFile.rewrite(Data(contentsOf:fixture),tags:tags,to:input)
        #expect(try CassiniReader.read(contentsOf:input).state == .plainAudio)
        let imported = try LibraryImport.copy(input,into:root.appendingPathComponent("Library"))
        let exported = try MeetingFileExporter.cassini(imported,assets:nil,temporaryRoot:root,timeZone:try #require(TimeZone(identifier:"Pacific/Kiritimati")))
        let x = try #require(CassiniReader.read(contentsOf:exported.url).manifest?.raw["x"]?["codemyriad.io"])
        #expect(x["namePrefix"]?.string == "2026-03-04--09.15-" && x["namePrefixSource"]?.string == "date-tag")
        #expect(x["automaticTitle"]?.string == "Board review")
        // D65: its DATE stays, and its creation time is that DATE, not the export time.
        let file = try CassiniReader.read(contentsOf:exported.url)
        #expect(file.tags?["DATE"] == "2026-03-04T09:15:00+01:00")
        #expect(file.manifest?.meeting.createdAtUtc == "2026-03-04T08:15:00.000Z")
        #expect(try raw(imported.folder.appendingPathComponent("meeting.json"))["namePrefix"]?.string == "2026-03-04--09.15-")
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
        #expect(try CodemyriadNamespace.make(meeting,stored:CodemyriadNamespace.current(meeting) ?? .null,dateTag:nil,originalTitle:nil,now:Date(),zone:.current) != nil)
    }
    private func refused(_ root: URL) -> Bool {
        do { _ = try reexportFile(root); return false } catch MeetingExportError.newerFormat { return true } catch { return false }
    }
    /// D65: a namespace schema this app doesn't know is refused (newerFormat), changed or not:
    /// its revision can't be known to describe what Mac would write.
    @Test func aFutureSchemaIsRefused() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (_,meeting) = try foreignFile(root,schema:2)
        #expect(refused(root))
        try MeetingRename.apply("Renamed on Mac",to:meeting)
        #expect(refused(root))
        // Also opened from outside the Library.
        let input = root.appendingPathComponent("gnome.opus")
        let external = MeetingPresentation.external(try CassiniReader.read(contentsOf:input),url:input)
        #expect(throws:MeetingExportError.newerFormat) { _ = try MeetingFileExporter.cassini(external,assets:nil,temporaryRoot:root) }
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
private func SHA256Hex(_ data: Data) -> String {
    var hasher = CryptoKit.SHA256(); hasher.update(data:data)
    return hasher.finalize().map { String(format:"%02x",$0) }.joined()
}
