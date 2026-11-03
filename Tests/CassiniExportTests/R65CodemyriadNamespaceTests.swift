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
    private func foreignFile(_ root: URL, schema: Int, cleared: Bool = false, revision: String = "7", notes: String? = nil, words: String = #"{"items":[]}"#, wordCount: Int = 0, moreSpeakers: String = "") throws -> (namespace: JSON, meeting: LibraryMeeting) {
        let fixture = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        // A real Cassini file first (the fixture is plain Opus), then the namespace in it.
        let plain = try LibraryImport.copy(fixture,into:root.appendingPathComponent("Seed"))
        let seed = try MeetingFileExporter.cassini(plain,assets:nil,temporaryRoot:root)
        let bytes = try Data(contentsOf:seed.url)
        let manifest = try #require(CassiniReader.read(bytes).manifest?.raw)
        let foreign = try JSONParser.parse(Data("""
        {"schema":\(schema),"sessionId":"8B7D3C2E-5f1a-4c9e-9a6b-1d2e3f4a5b6c","origin":"Recording","namePrefix":"2026-10-30--18.02-","namePrefixSource":"recorded","revision":\(revision),\
        "meeting":{"version":1,"title":null,"titleSource":"meeting-window","speakers":[{"id":"spk-me","name":"Me","provenance":"source","colourIndex":0,"futureSpeakerMember":1},{"id":"spk-1","name":null,"provenance":"unnamed","colourIndex":1\(cleared ? ",\"nameCleared\":true" : "")}\(moreSpeakers)],\
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
        let (_,meeting) = try foreignFile(root,schema:1,moreSpeakers:#",{"id":"track-original","name":null,"provenance":"unnamed","colourIndex":2,"label":"Parlante 1","futureX":1}"#)
        try writeDown(meeting,status:"done")
        let speakers = try #require(reexport(root)["meeting"]?["speakers"]?.array)
        try #require(speakers.count == 3)
        #expect(speakers[2]["label"]?.string == "Speaker 1" && speakers[2]["futureX"] == .number("1") && speakers[2]["colourIndex"] == .number("2"))
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
        let merged = try #require(try CodemyriadNamespace.merged(stripped,with:meeting,originalNotes:nil))
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
        let (foreign,meeting) = try foreignFile(root,schema:1,notes:#"[{"atMs":1500,"text":"hi","id":"n-1"},{"atMs":-4,"text":"bad"}]"#)
        let stored = try raw(meeting.folder.appendingPathComponent("meeting.json"))
        #expect(stored["notes"]?.array?.count == 1,"the import kept the valid note only")
        #expect(try reexport(root).encoded() == foreign.encoded())
        #expect(try raw(meeting.folder.appendingPathComponent("meeting.json"))[CodemyriadNamespace.baselineMember] == nil)
        // A real notes edit after that is a change.
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction { $0["notes"] = [["atMs":1500,"text":"hi, edited"]] }
        #expect(try reexport(root)["revision"] == .number("8"))
    }
    /// A revision at or past the shared ceiling (2^53-1), even Int.max, is never advanced:
    /// the original namespace is kept and the export goes ahead.
    @Test(arguments:["9007199254740991","9223372036854775807"]) func aRevisionAtTheCeilingIsKept(revision: String) throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let (foreign,meeting) = try foreignFile(root,schema:1,revision:revision)
        try MeetingRename.apply("Renamed on Mac",to:meeting)
        #expect(try reexport(root).encoded() == foreign.encoded())
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
