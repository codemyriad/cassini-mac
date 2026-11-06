// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniKit
import CassiniLibrary
import CassiniRecording
@testable import CassiniExport

/// D70 item 11 with library-v2 MAPPING Q2: an exported meeting with speakerMerges keeps the words'
/// own speaker ids in its transcript body and manifest, labels each id with the name of the
/// speaker it resolves to (so merged ids share a label), and carries the history verbatim in x.
struct D70SpeakerMergesExportTests {
    private func recording(merges: [[String:Any]]?) throws -> (root: URL, meeting: LibraryMeeting) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D70MergeExport-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let session = try RecordingSession(parent:root,title:"Weekly sync",source:"macos")
        try session.addTrack(id:"mic",label:"Me",kind:"microphone",sampleRate:16000,channels:1)
        try session.appendNative(id:"mic",pcm:Data(repeating:1,count:64000),offsetMs:0)
        try session.finish()
        let items: [[String:Any]] = [["speaker":"me","startMs":0,"endMs":400,"text":"Hello"],
            ["speaker":"track-a","startMs":500,"endMs":900,"text":"Hi"],["speaker":"track-c","startMs":1000,"endMs":1400,"text":"there"],
            ["speaker":"track-a","startMs":1500,"endMs":1900,"text":"all"]]
        try JSONSerialization.data(withJSONObject:["language":"en","items":items],options:[.sortedKeys])
            .write(to:session.directory.appendingPathComponent("transcript.json"))
        try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id).transaction { metadata in
            metadata["transcript"] = ["status":"done","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"],"model":"parakeet-tdt-0.6b-v3"]
            metadata["speakers"] = [["id":"me","name":"Me","provenance":"source","colourIndex":0],
                                    ["id":"track-a","name":NSNull(),"provenance":"unnamed","colourIndex":1,"label":"Speaker 1"],
                                    ["id":"track-c","name":"Carla","provenance":"user","colourIndex":2]]
            if let merges { metadata["speakerMerges"] = merges }
        }
        return (root,try #require(LibraryScanner(root:root).scan().meetings.first))
    }
    /// Through the real Opus export (assets supplied by the export CI job, as for R65).
    private func export(_ root: URL, _ meeting: LibraryMeeting) throws -> CassiniFile {
        let directory = URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"]))
        let hashes = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:directory.appendingPathComponent("unsigned-sha256.json")))
        let assets = try OpusAssets.builtForTests(directory:directory,expectedBinarySHA256:#require(hashes["libopus.0.dylib"]))
        let url = try MeetingFileExporter.cassini(meeting,assets:assets,temporaryRoot:root,timeZone:.current,shouldCancel:{ false }).url
        return try CassiniReader.read(contentsOf:url)
    }

    @Test(.enabled(if:ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"] != nil))
    func mergedIdsShareTheirTargetsLabelAndBodiesKeepTheirOwnIds() throws {
        let (root,meeting) = try recording(merges:[["from":"track-a","into":"track-c","by":"gnome"]])
        defer { try? FileManager.default.removeItem(at:root) }
        let file = try export(root,meeting)
        #expect(file.state == .ok)
        let speakers = try #require(file.manifest?.raw["speakers"]?.array)
        #expect(speakers.map { $0["id"]?.string } == ["me","track-a","track-c"],"one entry per original id, in first-speaking order")
        #expect(speakers.map { $0["label"]?.string } == ["Me","Carla","Carla"],"merged ids share the target's name")
        #expect(file.defaultTranscript?.load.transcript?.items.map(\.speaker) == ["me","track-a","track-c","track-a"],"the body is never rewritten for a merge")
        let stored = try JSONParser.parse(Data(contentsOf:meeting.folder.appendingPathComponent("meeting.json")))
        #expect(file.manifest?.raw["x"]?["codemyriad.io"]?["meeting"]?["speakerMerges"] == stored["speakerMerges"],"the history goes out verbatim, in order")
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"] != nil))
    func withoutMergesTheManifestIsAsBefore() throws {
        let (root,meeting) = try recording(merges:nil)
        defer { try? FileManager.default.removeItem(at:root) }
        let file = try export(root,meeting)
        let speakers = try #require(file.manifest?.raw["speakers"]?.array)
        #expect(speakers.map { $0["id"]?.string } == ["me","track-a","track-c"])
        #expect(speakers.map { $0["label"]?.string } == ["Me","Speaker 1","Carla"])
        #expect(file.manifest?.raw["x"]?["codemyriad.io"]?["meeting"]?["speakerMerges"] == nil,"absent stays absent")
    }
}
