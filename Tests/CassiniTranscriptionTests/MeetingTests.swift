// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CryptoKit
import CassiniLibrary
import CassiniRecording
import CassiniWhistle
@testable import CassiniTranscription

final class TranscriptionMeetingTests: XCTestCase {
    func testSafeScannerSourcesSurviveBadTracksAndUnsupportedManifests() throws {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline assets supplied by pipeline CI") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:root) }
        let engine = try WhistleEngine(assets:WhistleAssets.pinned(directory:URL(fileURLWithPath:assets)))
        let detector = try SpeechDetector(assets:VADAssets.forWorker(arguments:["--assets",assets]))
        let pcm = try Data(contentsOf:Bundle.module.url(forResource:"jfk",withExtension:"wav",subdirectory:"Goldens")!).dropFirst(44)
        for salvage in [false,true] {
            let session = try RecordingSession(parent:root,title:"Safe sources",source:"macos")
            try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
            for at in stride(from:0,to:pcm.count,by:64000) {
                let start = pcm.startIndex + at, end = min(pcm.endIndex,start + 64000)
                try session.append(id:"mic",pcm:Data(pcm[start..<end]),offsetMs:Double(at)/32)
            }
            try session.finish()
            let valid = session.directory.appendingPathComponent(session.manifest.tracks[0].file)
            let before = try Data(contentsOf:valid)
            let alias = session.directory.appendingPathComponent("track-alias.wav")
            try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:valid)
            let fifo = session.directory.appendingPathComponent("track-pipe.wav")
            XCTAssertEqual(mkfifo(fifo.path,0o600),0)
            try Data(repeating:0,count:10).write(to:session.directory.appendingPathComponent("track-broken.wav"))
            let manifestURL = session.directory.appendingPathComponent("session.json")
            var manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as! [String:Any]
            if salvage { manifest["version"] = 2 }
            else {
                var tracks = manifest["tracks"] as! [[String:Any]]
                for name in ["track-alias.wav","track-pipe.wav","track-broken.wav"] {
                    tracks.append(["id":name,"kind":"system","file":name,"sampleRate":16000,"channels":1,"startOffsetMs":0])
                }
                manifest["tracks"] = tracks
            }
            try JSONSerialization.data(withJSONObject:manifest).write(to:manifestURL)
            let selected = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == session.manifest.id }))
            XCTAssertEqual(selected.audioTracks.count,1)
            try MeetingTranscriber.run(directory:session.directory,engine:engine,detector:detector)
            let done = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == session.manifest.id }))
            XCTAssertEqual(done.state.transcript,.done)
            XCTAssertFalse(done.transcriptItems.isEmpty)
            XCTAssertEqual(done.speakers.map(\.id),[salvage ? valid.deletingPathExtension().lastPathComponent : "me"])
            XCTAssertEqual(try Data(contentsOf:valid),before)
        }
    }
    func testSourceNamesAndPlainOpusIdentity() {
        XCTAssertEqual(TranscriptSpeaker.fromTrack(id: "original", kind: "system", received: true).id, "track-original")
        XCTAssertNil(TranscriptSpeaker.fromTrack(id: "original", kind: "system", received: true).name)
        XCTAssertEqual(TranscriptSpeaker.fromTrack(id: "microphone", kind: "microphone").name, "Me")
        XCTAssertEqual(TranscriptSpeaker.fromTrack(id: "system", kind: "system").name, "The others")
        XCTAssertEqual(TranscriptSpeaker.fromTrack(id: "42", kind: "remote").id, "track-42")
        XCTAssertNil(TranscriptSpeaker.fromTrack(id: "42", kind: "remote").name)
    }
    func testOpaqueBrowserIdentityGroupsSpansAndNeverUsesTheirLabels() {
        let first = TranscriptSpeaker.fromTrack(id:"span-one",kind:"remote",sourceTrackID:"remote-wire-1")
        let second = TranscriptSpeaker.fromTrack(id:"span-two",kind:"remote",sourceTrackID:"remote-wire-1")
        XCTAssertEqual(first.id,"track-remote-wire-1"); XCTAssertEqual(first.id,second.id)
        XCTAssertNil(first.name)
        let opaque = String(repeating:"é",count:100) // Exactly 200 UTF-8 bytes.
        let escaped = TranscriptSpeaker.fromTrack(id:"span-three",kind:"remote",sourceTrackID:opaque)
        XCTAssertEqual(escaped.id,TranscriptSpeaker.fromTrack(id:"span-four",kind:"remote",sourceTrackID:opaque).id)
        XCTAssertLessThanOrEqual(escaped.id.utf8.count,200)
        XCTAssertNotEqual(escaped.id,first.id)
    }
    func testTwoBrowserSpansWriteDownAsOneSpeakerThroughTheRealScanner() throws {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline assets supplied by pipeline CI") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Off and on",source:"chromium")
        let input = try Data(contentsOf:XCTUnwrap(Bundle.module.url(forResource:"jfk",withExtension:"wav",subdirectory:"Goldens"))).dropFirst(44)
        for (index,id) in ["before","after"].enumerated() {
            try session.transition(starting:[.init(id:id,label:index == 0 ? "First label" : "Changed label",kind:"remote",sampleRate:16000,channels:1,sourceTrackId:"remote-wire-1")])
            for start in stride(from:0,to:input.count,by:160000) {
                let first = input.startIndex + start, last = min(input.endIndex,first + 160000)
                try session.appendNative(id:id,pcm:Data(input[first..<last]),offsetMs:Double(index*30000) + Double(start)/32)
            }
            try session.transition(ending:[id])
        }
        try session.finish()
        let detector = try SpeechDetector(assets:VADAssets.forWorker(arguments:["--assets",assets]))
        // The recognizer is deterministic here: this test isolates source to
        // speaker routing; existing hosted goldens verify both real engines.
        try MeetingTranscriber.run(directory:session.directory,detector:detector,model:"whistle",initialETA:0.15,uiLanguage:.fr,recognize:{ _ in
            .init(text:"Word",language:"en",words:[.init(word:"Word",start:0,end:0.1,probability:1)])
        })
        let meeting = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        XCTAssertEqual(meeting.speakers.map(\.id),["track-remote-wire-1"])
        XCTAssertEqual(meeting.speakers.first?.displayName,"Intervenant 1")
        XCTAssertEqual(meeting.speakers.first?.label,"Intervenant 1")
        XCTAssertTrue(meeting.transcriptItems.contains { $0.startMs < 30000 })
        XCTAssertTrue(meeting.transcriptItems.contains { $0.startMs >= 30000 })
        XCTAssertEqual(Set(meeting.transcriptItems.map(\.speaker)),["track-remote-wire-1"])
    }
    func testProducedLabelsFollowFirstAppearanceWhenTheEarlierTrackFinishesLast() throws {
        guard let assets=ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else {throw XCTSkip("Pinned offline VAD supplied by pipeline CI")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let session=try RecordingSession(parent:root,title:"Ordering",source:"chromium")
        let input=try Data(contentsOf:XCTUnwrap(Bundle.module.url(forResource:"jfk",withExtension:"wav",subdirectory:"Goldens"))).dropFirst(44)
        for (id,offset) in [("later",30000),("earlier",0)] {
            try session.transition(starting:[.init(id:id,label:id,kind:"remote",sampleRate:16000,channels:1,sourceTrackId:id)])
            for start in stride(from:0,to:input.count,by:160000) {
                let first=input.startIndex+start,last=min(input.endIndex,first+160000)
                try session.appendNative(id:id,pcm:Data(input[first..<last]),offsetMs:Double(offset)+Double(start)/32)
            }
            try session.transition(ending:[id])
        }
        try session.finish()
        let detector=try SpeechDetector(assets:VADAssets.forWorker(arguments:["--assets",assets]))
        try MeetingTranscriber.run(directory:session.directory,detector:detector,model:"whistle",initialETA:0.15,uiLanguage:.fr,recognize:{_ in
            .init(text:"Word",language:"en",words:[.init(word:"Word",start:0,end:0.1,probability:1)])
        })
        let meeting=try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        XCTAssertEqual(meeting.speakers.map(\.id),["track-earlier","track-later"])
        XCTAssertEqual(meeting.speakers.map(\.displayName),["Intervenant 1","Intervenant 2"])
        let writer=try MeetingMetadataWriter(directory:session.directory,id:meeting.id)
        // Resume a partial that only contained the later voice. Its original
        // number must change when the previously unseen earlier voice arrives.
        let saved=try XCTUnwrap(meeting.transcriptItems.first(where:{$0.speaker=="track-later"}))
        try JSONSerialization.data(withJSONObject:["language":"en","items":[["speaker":saved.speaker,"startMs":saved.startMs,"endMs":saved.endMs,"text":saved.text]]]).write(to:session.directory.appendingPathComponent("transcript.json"))
        try writer.transaction {metadata in
            var speakers=metadata["speakers"] as! [[String:Any]]
            for index in speakers.indices {
                if speakers[index]["id"] as? String == "track-later" {speakers[index]["label"]="Intervenant 1"}
                else {speakers[index].removeValue(forKey:"label")}
            }
            metadata["speakers"]=speakers
            var transcript=metadata["transcript"] as! [String:Any];transcript["status"]="queued";metadata["transcript"]=transcript
        }
        try MeetingTranscriber.run(directory:session.directory,detector:detector,model:"whistle",initialETA:0.15,uiLanguage:.fr,recognize:{_ in
            .init(text:"Word",language:"en",words:[.init(word:"Word",start:0,end:0.1,probability:1)])
        })
        XCTAssertEqual(try LibraryScanner(root:root).scan().meetings.first?.speakers.map(\.displayName),["Intervenant 1","Intervenant 2"])
        try writer.transaction {$0["title"]="Edited later"}
        XCTAssertEqual(try LibraryScanner(root:root).scan().meetings.first?.speakers.map(\.displayName),["Intervenant 1","Intervenant 2"])
    }
    /// D52 M1: two physically overlapping spans of one source are never summed
    /// into one speaker; the separation is stored as a write-down fact.
    func testOverlappingSpansOfOneSourceBecomeSeparateSpeakers() throws {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline assets supplied by pipeline CI") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Overlap",source:"chromium")
        let input = try Data(contentsOf:XCTUnwrap(Bundle.module.url(forResource:"jfk",withExtension:"wav",subdirectory:"Goldens"))).dropFirst(44)
        try session.transition(starting:["a","b"].map { .init(id:$0,label:"Guest",kind:"remote",sampleRate:16000,channels:1,sourceTrackId:"receiver-1") })
        for (index,id) in ["a","b"].enumerated() {
            for start in stride(from:0,to:input.count,by:160000) {
                let first = input.startIndex + start, last = min(input.endIndex,first + 160000)
                try session.appendNative(id:id,pcm:Data(input[first..<last]),offsetMs:Double(index*2000) + Double(start)/32)
            }
        }
        try session.finish()
        let detector = try SpeechDetector(assets:VADAssets.forWorker(arguments:["--assets",assets]))
        try MeetingTranscriber.run(directory:session.directory,detector:detector,model:"whistle",initialETA:0.15,recognize:{ _ in
            .init(text:"Word",language:"en",words:[.init(word:"Word",start:0,end:0.1,probability:1)])
        })
        let meeting = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        XCTAssertEqual(Set(meeting.transcriptItems.map(\.speaker)),["track-receiver-1","track-receiver-1:overlap:1"])
        let stored = try JSONSerialization.jsonObject(with:Data(contentsOf:session.directory.appendingPathComponent("meeting.json"))) as? [String:Any]
        let details = stored?["recordingDetails"] as? [String:Any]
        XCTAssertEqual((details?["writingDown"] as? [String:Any])?["sourceSpansSeparated"] as? Bool,true)
    }
    func testReceivedPlainOpusBecomesOneUnnamedSpeaker() throws {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline assets supplied by pipeline CI") }
        let original = Bundle.module.url(forResource: "jfk-received", withExtension: "opus", subdirectory: "Fixtures")!
        let before = SHA256.hash(data: try Data(contentsOf: original))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let imported = try ReceivedAudioImport.copy(original, into: root)
        XCTAssertEqual(imported.state.origin,.received); XCTAssertTrue(imported.canWriteDown)
        XCTAssertFalse(imported.canQueueAutomatically)
        let vad = try VADAssets.forWorker(arguments: ["--assets",assets])
        let detector = try SpeechDetector(assets: vad)
        let engine = try WhistleEngine(assets: WhistleAssets.pinned(directory: URL(fileURLWithPath: assets)))
        try MeetingTranscriber.run(directory: imported.folder, engine: engine, detector: detector)
        let written = try XCTUnwrap(LibraryScanner(root: root).scan().meetings.first)
        XCTAssertEqual(written.state.transcript,.done); XCTAssertFalse(written.transcriptItems.isEmpty)
        XCTAssertEqual(written.speakers.count,1)
        XCTAssertEqual(written.speakers.first?.id,"track-original")
        XCTAssertEqual(written.speakers.first?.displayName,"Speaker 1")
        XCTAssertEqual(written.speakers.first?.provenance,.unnamed)
        XCTAssertNil(written.speakers.first?.name)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: original)),before)
    }
    /// D53.2: a write-down that never learned its language stores "und".
    func testSilentMeetingWritesUndAsItsLanguage() throws {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline assets supplied by pipeline CI") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Silent",source:"macos")
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
        try session.append(id:"mic",pcm:Data(repeating:0,count:64000),offsetMs:0); try session.finish()
        let detector = try SpeechDetector(assets:VADAssets.forWorker(arguments:["--assets",assets]))
        try MeetingTranscriber.run(directory:session.directory,detector:detector,model:"whistle",initialETA:0.15,recognize:{ _ in
            .init(text:"",language:"en",words:[])
        })
        let body = try JSONSerialization.jsonObject(with:Data(contentsOf:session.directory.appendingPathComponent("transcript.json"))) as? [String:Any]
        XCTAssertEqual(body?["language"] as? String,"und")
    }
    func testPausePreservesPartialWordsAndExistingMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Pause",source:"macos")
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
        try session.append(id:"mic",pcm:Data(repeating:0,count:32000),offsetMs:0); try session.finish()
        let words: [String:Any] = ["language":"en","items":[["speaker":"me","startMs":0,"endMs":160,"text":"Partial words"]]]
        let bytes = try JSONSerialization.data(withJSONObject:words)
        let sidecar = session.directory.appendingPathComponent("transcript.json"); try bytes.write(to:sidecar)
        let writer = try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id)
        try writer.transaction { meta in
            meta["title"] = "Keep the title"; meta["notes"] = [["atMs":12,"text":"Keep the note"]]
            meta["speakers"] = [["id":"me","name":"Renamed","provenance":"user","colourIndex":0]]
            meta["transcript"] = ["status":"running","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]]
            meta["etaMinutes"] = 3
        }
        try MeetingTranscriber.pauseForResume(directory:session.directory,id:session.manifest.id)
        let meeting = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        XCTAssertEqual(meeting.state.transcript,.queued); XCTAssertNil(meeting.state.error); XCTAssertNil(meeting.state.etaMinutes)
        XCTAssertEqual(meeting.transcriptItems.count,1); XCTAssertEqual(meeting.title,"Keep the title")
        XCTAssertEqual(meeting.notes.first?.text,"Keep the note"); XCTAssertEqual(meeting.speakers.first?.displayName,"Renamed")
        XCTAssertEqual(try Data(contentsOf:sidecar),bytes)
        try MeetingTranscriber.setStatus(directory:session.directory,id:session.manifest.id,status:"done")
        try MeetingTranscriber.pauseForResume(directory:session.directory,id:session.manifest.id)
        XCTAssertEqual(try LibraryScanner(root:root).scan().meetings.first?.state.transcript,.done)
    }
    func testResumeKeepsTheSavedTailUntilRecognitionCatchesUp() throws {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline assets supplied by pipeline CI") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Resume",source:"macos")
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:48000,channels:1)
        let url = Bundle.module.url(forResource:"pipeline-input-48k",withExtension:"wav",subdirectory:"Goldens")!
        let input = try Data(contentsOf:url).dropFirst(44)
        for at in stride(from:0,to:input.count,by:160000) {
            let first = input.startIndex + at, last = min(input.endIndex,first + 160000)
            try session.appendNative(id:"mic",pcm:Data(input[first..<last]),offsetMs:Double(at) / 96)
        }
        try session.finish()
        let sidecar = session.directory.appendingPathComponent("transcript.json")
        try JSONSerialization.data(withJSONObject:["language":"en","items":[["speaker":"me","startMs":30000,"endMs":30160,"text":"Retained old partial"]]]).write(to:sidecar)
        try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id).transaction { meta in
            meta["transcript"] = ["status":"queued","model":"whistle","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]]
        }
        final class Outcome: @unchecked Sendable {
            let lock = NSLock(); private var result: Result<Void,Error>?
            func finish(_ result: Result<Void,Error>) { lock.lock(); self.result = result; lock.unlock() }
            func snapshot() -> Result<Void,Error>? { lock.lock(); defer { lock.unlock() }; return result }
        }
        let outcome = Outcome(), folder = session.directory
        Thread.detachNewThread {
            outcome.finish(Result {
                let vad = try VADAssets.forWorker(arguments:["--assets",assets])
                let detector = try SpeechDetector(assets:vad)
                let engine = try WhistleEngine(assets:WhistleAssets.pinned(directory:URL(fileURLWithPath:assets)))
                try MeetingTranscriber.run(directory:folder,engine:engine,detector:detector)
            })
        }
        // Hosted Intel must finish real FIR/VAD/recognition, not a timer stub.
        let deadline = Date().addingTimeInterval(120); var sawMixedProgress = false
        while outcome.snapshot() == nil, Date() < deadline {
            if let data = try? Data(contentsOf:sidecar), let body = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
               let words = body["items"] as? [[String:Any]], words.count > 1,
               words.contains(where: { ($0["text"] as? String) == "Retained old partial" }),
               words.contains(where: { ($0["startMs"] as? Int ?? Int.max) < 10000 }) { sawMixedProgress = true }
            Thread.sleep(forTimeInterval:0.01)
        }
        let result = try XCTUnwrap(outcome.snapshot()); try result.get()
        XCTAssertTrue(sawMixedProgress,"Saved later words must remain while the beginning is re-recognized")
        let meeting = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        XCTAssertEqual(meeting.state.transcript,.done)
        XCTAssertFalse(meeting.transcriptItems.contains { $0.text == "Retained old partial" })
        XCTAssertEqual(meeting.transcriptItems.count,68)
    }
    func testRetryDiscardsFailedWordsWithoutChangingNotesOrSpeakers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Retry",source:"macos")
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
        try session.append(id:"mic",pcm:Data(repeating:0,count:32000),offsetMs:0); try session.finish()
        try JSONSerialization.data(withJSONObject:["language":"en","items":[["speaker":"me","startMs":0,"endMs":160,"text":"Failed words"]]]).write(to:session.directory.appendingPathComponent("transcript.json"))
        try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id).transaction {
            $0["notes"] = [["atMs":0,"text":"Keep"]]
            $0["speakers"] = [["id":"me","name":"Me","provenance":"source","colourIndex":0]]
            $0["transcript"] = ["status":"failed","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]]
        }
        try MeetingTranscriber.setStatus(directory:session.directory,id:session.manifest.id,status:"queued")
        let queued = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        XCTAssertEqual(queued.state.transcript,.queued); XCTAssertTrue(queued.transcriptItems.isEmpty)
        XCTAssertEqual(queued.notes.first?.text,"Keep")
        let metadata = try JSONSerialization.jsonObject(with:Data(contentsOf:session.directory.appendingPathComponent("meeting.json"))) as! [String:Any]
        XCTAssertEqual((metadata["speakers"] as? [[String:Any]])?.first?["name"] as? String,"Me")
    }
    func testProductionWriterPipelineOffsetsAndReadOnlyAudio() throws {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline assets supplied by pipeline CI") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(parent: root, title: "Offline speech", source: "macos")
        try session.addTrack(id: "mic", label: "Microphone", kind: "microphone", sampleRate: 16000, channels: 1)
        try session.addTrack(id: "other", label: "System", kind: "system", sampleRate: 16000, channels: 1)
        let source = Bundle.module.url(forResource: "segmentation-input", withExtension: "wav", subdirectory: "Goldens")!
        let bytes = try Data(contentsOf: source).dropFirst(44)
        // A single utterance is enough for real VAD + recognition + source metadata.
        let speech = Data(bytes.prefix(16000 * 4 * 2))
        try session.append(id: "mic", pcm: speech, offsetMs: 125)
        try session.append(id: "other", pcm: speech, offsetMs: 0)
        let stillGrowing = try XCTUnwrap(LibraryScanner(root: root).scan().meetings.first)
        XCTAssertEqual(stillGrowing.state.lifecycle,.saved) // no live adapter connected
        XCTAssertFalse(stillGrowing.canQueueAutomatically)
        try session.finish()
        let finished = try XCTUnwrap(LibraryScanner(root: root).scan().meetings.first)
        XCTAssertTrue(finished.canQueueAutomatically)
        let manifestURL = session.directory.appendingPathComponent("session.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String:Any]
        var tracks = manifest["tracks"] as! [[String:Any]]; tracks[1]["startOffsetMs"] = NSNull(); manifest["tracks"] = tracks
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let writer = try MeetingMetadataWriter(directory: session.directory, id: session.manifest.id)
        try writer.transaction { $0["title"] = "Kept title"; $0["notes"] = [["atMs":0,"text":"Kept note"]] }
        let protected = [manifestURL] + session.manifest.tracks.map { session.directory.appendingPathComponent($0.file) }
        let before = try protected.map { SHA256.hash(data: try Data(contentsOf: $0)) }
        let vad = try VADAssets.forWorker(arguments: ["--assets",assets])
        let detector = try SpeechDetector(assets: vad)
        let engine = try WhistleEngine(assets: WhistleAssets.pinned(directory: URL(fileURLWithPath: assets)))
        let beforeMeeting = try XCTUnwrap(LibraryScanner(root: root).scan().meetings.first)
        XCTAssertEqual(beforeMeeting.state.lifecycle, .saved, String(describing: beforeMeeting))
        XCTAssertFalse(beforeMeeting.audioFiles.isEmpty, String(describing: beforeMeeting))
        try MeetingTranscriber.run(directory: session.directory, engine: engine, detector: detector)
        let meeting = try XCTUnwrap(LibraryScanner(root: root).scan().meetings.first)
        XCTAssertEqual(meeting.state.transcript, .done); XCTAssertEqual(meeting.title, "Kept title")
        XCTAssertEqual(meeting.notes.first?.text, "Kept note"); XCTAssertFalse(meeting.canPlaySession)
        XCTAssertEqual(Set(meeting.speakers.map(\.id)), ["me","others"])
        XCTAssertEqual(Set(meeting.speakers.compactMap(\.provenance)), [.source])
        let mic = meeting.transcriptItems.filter { $0.speaker == "me" }, other = meeting.transcriptItems.filter { $0.speaker == "others" }
        XCTAssertEqual(mic.count, other.count); XCTAssertFalse(mic.isEmpty)
        for (a,b) in zip(mic,other) { XCTAssertEqual(a.startMs - b.startMs,125); XCTAssertEqual(a.endMs - b.endMs,125); XCTAssertEqual(a.text,b.text) }
        XCTAssertEqual(try protected.map { SHA256.hash(data: try Data(contentsOf: $0)) }, before)
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: session.directory.appendingPathComponent("meeting.json"))) as! [String:Any]
        XCTAssertTrue(metadata["etaMinutes"] is NSNull)
    }
}
