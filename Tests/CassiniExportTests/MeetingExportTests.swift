// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AVFoundation
import Testing
import CassiniKit
import CassiniLibrary
import CassiniRecording
@testable import CassiniExport

struct MeetingExportTests {
    @Test(arguments:[8000,11025,16000,22050,24000,44100,48000,96000])
    func resamplerEOFProducesTheExactTimelineEvenForFractionalAndShortInputs(rate: Int) throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        for count in [1,2,3,17,127,511,512,1023,1024,rate / 5 + 1,rate * 3 + 17] {
            let session = try RecordingSession(parent:root,title:"Fractional tail",source:"macos")
            try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:rate,channels:1)
            for at in stride(from:0,to:count,by:8192) {
                try session.appendNative(id:"mic",pcm:Data(repeating:1,count:min(8192,count - at) * 2),offsetMs:Double(at) * 1000 / Double(rate))
            }
            try session.finish()
            let track = LibraryAudioTrack(url:session.directory.appendingPathComponent(session.manifest.tracks[0].file),startOffsetMs:0,frameCount:UInt64(count))
            let input = try PCMInput(track)
            let expected = Int64(ceil(Double(count) * 48000 / Double(rate)))
            #expect(input.outputFrames == expected)
            var position: Int64 = 0
            while position < expected {
                var block = [Float](repeating:0,count:Int(min(127,expected - position)))
                try input.add(to:&block,position:position)
                #expect(block.allSatisfy { $0.isFinite })
                position += Int64(block.count)
            }
            #expect(position == expected)
        }
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"] != nil))
    func salvagedSessionExportsWithoutInventingADateOrOffset() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Lost manifest",source:"macos")
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
        try session.appendNative(id:"mic",pcm:Data(repeating:0,count:32000),offsetMs:100); try session.finish()
        try FileManager.default.removeItem(at:session.directory.appendingPathComponent("session.json"))
        let recovered = try #require(LibraryScanner(root:root).scan().meetings.first)
        #expect(recovered.start == nil && recovered.audioTracks.first?.startOffsetMs == nil)
        let before = Date().addingTimeInterval(-1)
        let artifact = try MeetingFileExporter.cassini(recovered,assets:assets(),temporaryRoot:root)
        try evidence(artifact,name:"salvaged")
        let file = try CassiniReader.read(contentsOf:artifact.url)
        #expect(file.state == .ok && file.manifest?.audio.sampleCount == 48000)
        #expect(file.manifest?.meeting.recordedAtLocal == nil)
        #expect(file.manifest?.raw["x"]?["gocassini.com"]?["recovery"]?["offsetsAssumedZero"] == .bool(true))
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        let stamp = try #require(file.manifest?.meeting.createdAtUtc)
        let stamped = try #require(iso.date(from:stamp))
        #expect(stamped >= before && stamped <= Date())
    }
    @Test(arguments:[false,true]) func reexportDoesNotAuthenticateUntrustedManifestExtensions(unverified: Bool) throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let source = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        let imported = try LibraryImport.copy(source,into:root.appendingPathComponent("Original"))
        let valid = try MeetingFileExporter.cassini(imported,assets:nil,temporaryRoot:root)
        let bytes = try Data(contentsOf:valid.url), parsed = try CassiniReader.read(bytes)
        var manifest = try #require(parsed.manifest?.raw)
        let integrity = try #require(manifest["integrity"])
        manifest = try manifest.setting("integrity",to:integrity.setting(unverified ? "matchPolicy" : "opusAudioSha256",to:.string(unverified ? "future-policy" : String(repeating:"0",count:64))))
        let info = try #require(manifest["meeting"])
        var untrustedInfo = try info.setting("id",to:.string("untrusted-id"))
        untrustedInfo = try untrustedInfo.setting("title",to:.string("Untrusted title"))
        untrustedInfo = try untrustedInfo.setting("recordedAtLocal",to:.string("2001-02-03T04:05:06+09:00"))
        manifest = try manifest.setting("meeting",to:untrustedInfo)
        manifest = try manifest.setting("x",to:.object([("untrusted.example",.object([("claim",.bool(true))]))]))
        let tags = try PortableMeetingTags.make(manifest:manifest,transcript:Data("{\"items\":[]}".utf8),wordCount:0)
        let damaged = root.appendingPathComponent("Untrusted.opus")
        _ = try OpusStreamFile.rewrite(bytes,tags:tags,to:damaged)
        let suspect = try CassiniReader.read(contentsOf:damaged)
        #expect(suspect.state == (unverified ? .unverified : .staleAudio))
        let importedSuspect = try LibraryImport.copy(damaged,into:root.appendingPathComponent("Imported"))
        try MeetingMetadataWriter(directory:importedSuspect.folder,id:importedSuspect.id).transaction { $0["title"] = NSNull() }
        let received = try #require(LibraryScanner(root:importedSuspect.folder.deletingLastPathComponent()).scan().meetings.first)
        #expect(received.title == "Untrusted title") // R6 display fallback remains.
        let external = MeetingPresentation.external(suspect,url:damaged)
        let direct = try MeetingFileExporter.cassini(external,assets:nil,temporaryRoot:root)
        let directFile = try CassiniReader.read(contentsOf:direct.url)
        #expect(directFile.manifest?.meeting.title == "Untrusted")
        #expect(directFile.manifest?.meeting.recordedAtLocal == nil)
        let result = try MeetingFileExporter.cassini(received,assets:nil,temporaryRoot:root)
        let exported = try CassiniReader.read(contentsOf:result.url)
        #expect(exported.state == .ok && exported.manifest?.meeting.id != "untrusted-id")
        #expect(exported.manifest?.raw["x"]?["untrusted.example"] == nil)
        #expect(exported.manifest?.meeting.title == "original")
        #expect(exported.manifest?.meeting.recordedAtLocal == nil)
        #expect(try exported.audioDigest?.get() == suspect.audioDigest?.get())
    }
    @Test(arguments:[nil,"2001-02-03T04:05:06.125+09:00"] as [String?])
    func receivedExportsPreserveOnlyTheKnownRecordingTime(recorded: String?) throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let source = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        let imported = try LibraryImport.copy(source,into:root.appendingPathComponent("Plain"))
        #expect(imported.start != nil) // Import time is useful for display only.
        let plainExport = try MeetingFileExporter.cassini(imported,assets:nil,temporaryRoot:root)
        let plain = try CassiniReader.read(contentsOf:plainExport.url)
        #expect(plain.manifest?.meeting.recordedAtLocal == nil)
        let manifest = try #require(plain.manifest?.raw)
        var info = try #require(manifest["meeting"])
        info = try info.setting("createdAtUtc",to:.string("2020-01-02T03:04:05Z"))
        info = try info.setting("recordedAtLocal",to:recorded.map(JSON.string))
        let changed = try manifest.setting("meeting",to:info)
        let tagged = root.appendingPathComponent("Known-or-unknown.opus")
        _ = try OpusStreamFile.rewrite(Data(contentsOf:plainExport.url),tags:PortableMeetingTags.make(manifest:changed,transcript:Data("{\"items\":[]}".utf8),wordCount:0),to:tagged)
        let received = try LibraryImport.copy(tagged,into:root.appendingPathComponent("Received"))
        #expect(received.start != nil)
        let exported = try MeetingFileExporter.cassini(received,assets:nil,temporaryRoot:root)
        let result = try CassiniReader.read(contentsOf:exported.url)
        #expect(result.state == .ok)
        #expect(result.manifest?.meeting.recordedAtLocal == recorded)
        #expect(result.manifest?.meeting.createdAtUtc != "2020-01-02T03:04:05Z")
    }
    @Test func ordinaryAudioTitleTagsStillSurviveBothOpenAndImport() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let source = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        var packet = Data("OpusTags".utf8)
        func number(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of:&value) { packet.append(contentsOf:$0) } }
        number(0); number(1)
        let comment = Data("TITLE=Ordinary audio title".utf8); number(UInt32(comment.count)); packet.append(comment)
        let input = root.appendingPathComponent("Ordinary.opus")
        _ = try OpusStreamFile.rewrite(Data(contentsOf:source),tags:packet,to:input)
        let file = try CassiniReader.read(contentsOf:input)
        #expect(file.state == .plainAudio)
        let external = MeetingPresentation.external(file,url:input)
        let imported = try LibraryImport.copy(input,into:root.appendingPathComponent("Library"))
        for meeting in [external,imported] {
            let artifact = try MeetingFileExporter.cassini(meeting,assets:nil,temporaryRoot:root)
            let exported = try CassiniReader.read(contentsOf:artifact.url)
            #expect(exported.manifest?.meeting.title == "Ordinary audio title")
            #expect(exported.manifest?.meeting.recordedAtLocal == nil)
        }
    }
    private func evidence(_ artifact: ExportArtifact, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["CASSINI_EXPORT_REPORT_DIR"] else { return }
        let root = URL(fileURLWithPath:path)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try Data(contentsOf:artifact.url).write(to:root.appendingPathComponent(name + ".opus"),options:.atomic)
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); return root
    }
    private func assets() throws -> OpusAssets {
        let path = try #require(ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"])
        let dir = URL(fileURLWithPath:path)
        let hashes = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:dir.appendingPathComponent("unsigned-sha256.json")))
        return try .builtForTests(directory:dir,expectedBinarySHA256:#require(hashes["libopus.0.dylib"]))
    }
    @Test func existingNotesSurviveTitleAndSpeakerEditsAndStillExport() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let original = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        let first = try LibraryImport.copy(original,into:root.appendingPathComponent("Library"))
        let writer = try MeetingMetadataWriter(directory:first.folder,id:first.id)
        let notes: [[String:Any]] = [["atMs":120,"text":" Keep this note\nwith its whitespace. "],["atMs":10,"text":"Earlier note — café"]]
        let expected = try JSONSerialization.data(withJSONObject:notes,options:.sortedKeys)
        try writer.transaction { $0["notes"] = notes }
        let beforeRename = try #require(LibraryScanner(root:first.folder.deletingLastPathComponent()).scan().meetings.first)
        try MeetingRename.apply("Edited title",to:beforeRename)
        try writer.transaction { $0["speakers"] = [["id":"track-original","name":"Ana","provenance":"user","colourIndex":0]] }
        let metadata = try JSONSerialization.jsonObject(with:Data(contentsOf:first.folder.appendingPathComponent("meeting.json"))) as! [String:Any]
        #expect(try JSONSerialization.data(withJSONObject:metadata["notes"]!,options:.sortedKeys) == expected)
        let edited = try #require(LibraryScanner(root:first.folder.deletingLastPathComponent()).scan().meetings.first)
        let exported = try MeetingFileExporter.cassini(edited,assets:nil,temporaryRoot:root)
        let file = try CassiniReader.read(contentsOf:exported.url)
        #expect(file.state == .ok && file.manifest?.meeting.title == "Edited title")
        let carried = try #require(file.manifest?.raw["x"]?["gocassini.com"]?["notes"])
        #expect(try JSONParser.parse(expected) == carried)
        let imported = try LibraryImport.copy(exported.url,into:root.appendingPathComponent("RoundTrip"))
        #expect(imported.notes == edited.notes && imported.notes.map(\.atMs) == [120,10])
    }
    @Test func stereoOpusRetagKeepsDigestChannelsNotesAndOtherExtensions() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let original = try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        let originalBytes = try Data(contentsOf:original)
        let digest = try #require(try CassiniReader.read(originalBytes).audioDigest?.get())
        #expect(digest.channels == 2)
        let first = try LibraryImport.copy(original,into:root.appendingPathComponent("Library"))
        let metadata = try MeetingMetadataWriter(directory:first.folder,id:first.id)
        try metadata.transaction { $0["notes"] = [["atMs":120,"text":"Later note"],["atMs":10,"text":"Earlier note"]] }
        let meeting = try #require(LibraryScanner(root:first.folder.deletingLastPathComponent()).scan().meetings.first)
        let exported = try MeetingFileExporter.cassini(meeting,assets:nil,temporaryRoot:root)
        try evidence(exported,name:"stereo")
        let file = try CassiniReader.read(contentsOf:exported.url)
        #expect(file.state == .ok && file.manifest?.audio.channels == 2)
        #expect(try file.audioDigest?.get() == digest)
        #expect(file.manifest?.raw["x"]?["gocassini.com"]?["notes"]?.array?.compactMap { $0["atMs"]?.int } == [120,10])
        let imported = try LibraryImport.copy(exported.url,into:root.appendingPathComponent("RoundTrip"))
        #expect(imported.state.transcript == .none && imported.canWriteDown)
        #expect(imported.state.error == nil && imported.state.audioAvailable == true)
        #expect(imported.notes.map(\.atMs) == [120,10])
        let decoder = try AVAudioFile(forReading:exported.url,commonFormat:.pcmFormatFloat32,interleaved:false)
        #expect(decoder.processingFormat.channelCount == 2 && decoder.length > 47000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat:decoder.processingFormat,frameCapacity:48000))
        try decoder.read(into:buffer)
        #expect(buffer.frameLength > 47000)
        // Both channels contain real decoded sound, not only a stereo header.
        let samples = try #require(buffer.floatChannelData)
        for channel in 0..<2 { #expect((0..<Int(buffer.frameLength)).contains { abs(samples[channel][$0]) > 0.05 }) }
        let opaque = try JSONParser.parse(Data("{\"other.example\":{\"integer\":9007199254740993},\"gocassini.com\":{\"future\":true,\"notes\":[]}}".utf8))
        let withX = try #require(file.manifest?.raw).setting("x",to:opaque)
        let tags = try PortableMeetingTags.make(manifest:withX,transcript:Data("{\"items\":[]}".utf8),wordCount:0)
        let inputX = root.appendingPathComponent("extension.opus")
        _ = try OpusStreamFile.rewrite(originalBytes,tags:tags,to:inputX)
        let fromX = try LibraryImport.copy(inputX,into:root.appendingPathComponent("OtherLibrary"))
        let rewritten = try MeetingFileExporter.cassini(fromX,assets:nil,temporaryRoot:root)
        try evidence(rewritten,name:"opaque-x")
        let result = try CassiniReader.read(contentsOf:rewritten.url)
        #expect(result.manifest?.raw["x"]?["other.example"] == opaque["other.example"])
        #expect(result.manifest?.raw["x"]?["gocassini.com"]?["future"] == .bool(true))
        #expect(result.manifest?.raw["x"]?["gocassini.com"]?["notes"] == nil)
        #expect(try Data(contentsOf:original) == originalBytes)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"] != nil), arguments:[8000,16000,48000])
    func pcmFramesOffsetsAndMatchSourceSurviveExport(rate: Int) throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root.appendingPathComponent("Library"),title:"Offset tone",source:"macos")
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:rate,channels:2)
        let count = rate / 2
        var pcm = Data()
        for frame in 0..<count {
            let sample = 0.2 * sin(Double(frame) * 2 * .pi * 440 / Double(rate))
            for gain in [1.0,0.5] {
                var value = Int16(sample * gain * 32767).littleEndian
                withUnsafeBytes(of:&value) { pcm.append(contentsOf:$0) }
            }
        }
        try session.appendNative(id:"mic",pcm:pcm,offsetMs:125); try session.finish()
        let meeting = try #require(LibraryScanner(root:session.directory.deletingLastPathComponent()).scan().meetings.first)
        let artifact = try MeetingFileExporter.cassini(meeting,assets:assets(),temporaryRoot:root)
        try evidence(artifact,name:"pcm-\(rate)")
        let file = try CassiniReader.read(contentsOf:artifact.url)
        let digest = try #require(try file.audioDigest?.get())
        #expect(file.state == .ok && digest.channels == 1 && digest.sampleCount == 30000)
        #expect(file.manifest?.raw["x"]?["gocassini.com"]?["recovery"] == nil)
        #expect(file.manifest?.meeting.recordedAtLocal != nil)
        #expect(file.manifest?.raw["audioEncode"]?["bitrateBps"]?.int == (rate == 48000 ? 64000 : rate == 16000 ? 32000 : 16000))
        let decoder = try AVAudioFile(forReading:artifact.url,commonFormat:.pcmFormatFloat32,interleaved:false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat:decoder.processingFormat,frameCapacity:40000))
        try decoder.read(into:buffer)
        #expect(buffer.frameLength == 30000)
        let data = try #require(buffer.floatChannelData)[0]
        let early = (0..<4500).reduce(0.0) { $0 + Double(data[$1] * data[$1]) }
        let voice = (10000..<20000).reduce(0.0) { $0 + Double(data[$1] * data[$1]) }
        #expect(early < 0.01 && voice > 30)
        let roundTrip = try LibraryImport.copy(artifact.url,into:root.appendingPathComponent("Received"))
        #expect(roundTrip.state.transcript == .none && roundTrip.canWriteDown && roundTrip.state.audioAvailable == true)
        #expect(roundTrip.state.error == nil)
    }
    @Test func peakLimiterIsBoundedAndPreservesQuietSamplesAndFrameCount() throws {
        var limiter = PeakLimiter()
        let input: [Float] = [Float](repeating:0.1,count:1000) + [Float](repeating:1.6,count:500) + [Float](repeating:0.1,count:1000)
        var output = try limiter.feed(Array(input.prefix(1200)))
        output += try limiter.feed(Array(input.dropFirst(1200))); output += try limiter.finish()
        #expect(output.count == input.count)
        #expect(output.allSatisfy { $0.isFinite && abs($0) <= 0.950001 })
        #expect(abs(output[0] - 0.1) < 0.00001)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"] != nil))
    func completeWordsExportButFailedOrRunningPartialWordsDoNot() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root.appendingPathComponent("Library"),title:"Words",source:"macos")
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:48000,channels:1)
        try session.appendNative(id:"mic",pcm:Data(repeating:0,count:96000),offsetMs:0); try session.finish()
        let writer = try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id)
        try Data("{\"language\":\"en\",\"items\":[{\"speaker\":\"mic\",\"startMs\":10,\"endMs\":100,\"text\":\"Only export when complete\"}]}".utf8).write(to:session.directory.appendingPathComponent("transcript.json"))
        for status in ["running","failed","done"] {
            try writer.transaction {
                $0["speakers"] = [["id":"mic","name":"Ana","provenance":"recognised","colourIndex":3]]
                $0["transcript"] = ["status":status,"reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]]
            }
            let meeting = try #require(LibraryScanner(root:session.directory.deletingLastPathComponent()).scan().meetings.first)
            #expect(meeting.transcriptItems.count == 1 && meeting.transcriptLanguage == "en")
            let artifact = try MeetingFileExporter.cassini(meeting,assets:assets(),temporaryRoot:root)
            try evidence(artifact,name:"words-\(status)")
            let file = try CassiniReader.read(contentsOf:artifact.url)
            #expect(file.defaultTranscript?.load.transcript?.items.count == (status == "done" ? 1 : 0))
            #expect(file.manifest?.transcripts.count == 1 && file.manifest?.raw["readableTranscripts"] == nil)
            #expect(file.manifest?.raw["provenance"]?["speechToText"] == nil)
            #expect(file.manifest?.raw["speakers"]?.array?.first?.keys == ["id","label"])
            let markdown = MeetingMarkdown.render(meeting,timeZone:TimeZone(secondsFromGMT:0)!)
            #expect(markdown.contains("Only export when complete") == (status == "done"))
        }
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"] != nil))
    func physicalFramesSurviveStaleCheckpointAndEmptyWideTrackSetsTheBand() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root.appendingPathComponent("Library"),title:"Recovered",source:"macos")
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
        try session.addTrack(id:"wide",label:"Empty",kind:"system",sampleRate:48000,channels:1)
        try session.appendNative(id:"mic",pcm:Data(repeating:0,count:32000),offsetMs:0); try session.finish()
        let wave = session.directory.appendingPathComponent(try #require(session.manifest.tracks.first(where:{ $0.id == "mic" })?.file))
        var bytes = try Data(contentsOf:wave)
        bytes.replaceSubrange(4..<8,with:[UInt8](repeating:0,count:4)); bytes.replaceSubrange(40..<44,with:[UInt8](repeating:0,count:4))
        try bytes.write(to:wave)
        let meeting = try #require(LibraryScanner(root:session.directory.deletingLastPathComponent()).scan().meetings.first)
        let artifact = try MeetingFileExporter.cassini(meeting,assets:assets(),temporaryRoot:root)
        try evidence(artifact,name:"stale-checkpoint")
        let file = try CassiniReader.read(contentsOf:artifact.url)
        #expect(file.manifest?.audio.sampleCount == 48000)
        #expect(!meeting.issues.contains(.unknownStartOffset))
        #expect(file.manifest?.raw["x"]?["gocassini.com"]?["recovery"] == nil)
        #expect(file.manifest?.raw["audioEncode"]?["cutoffHz"]?.int == 20000)
        #expect(file.manifest?.raw["audioEncode"]?["bitrateBps"]?.int == 64000)
        #expect(try Data(contentsOf:wave) == bytes)
    }
}
