// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import Darwin
@testable import CassiniLibrary

struct SavedVoicesTests {
    private var print: [Float] { [1]+Array(repeating:0,count:511) }
    private func temporary() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return url
    }
    @Test func enrollmentRenameForgetAndGenerationFence() async throws {
        let root=try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let store=SavedVoicesStore(directory:root.appendingPathComponent("voices"))
        let generation=try await store.snapshot().generation
        let id=try await store.enroll(name:"Claire",embedding:print,seconds:4,generation:generation,
            clip:.init(meeting:"Recording-one",speaker:"track-1",startMs:100,endMs:4100))
        try await store.rename(id,to:"Cláire Lee")
        let snapshot=try await store.snapshot()
        #expect(snapshot.voices.first?.name == "Cláire Lee")
        #expect(snapshot.voices.first?.count == 1)
        #expect(snapshot.clips[id]?.meeting == "Recording-one")
        #expect(VoiceSelection.matchingName(" CLAIRE ",voices:snapshot.voices).first?.id == id)
        let permissions=try FileManager.default.attributesOfItem(atPath:root.appendingPathComponent("voices/people.json").path)
        #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try await store.forgetEveryone()
        await #expect(throws:SavedVoicesError.changedGeneration) {
            try await store.enroll(name:"Claire",embedding:print,seconds:4,generation:generation)
        }
        #expect(try await store.snapshot().voices.isEmpty)
    }
    @Test func concurrentStoresDoNotLoseUpdatesAndColoursNeverShift() async throws {
        let root=try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let a=SavedVoicesStore(directory:root), b=SavedVoicesStore(directory:root)
        let g=try await a.snapshot().generation
        async let first=a.enroll(name:"A",embedding:print,seconds:4,generation:g)
        async let second=b.enroll(name:"B",embedding:print,seconds:5,generation:g)
        let ids=try await [first,second]
        #expect(try await a.snapshot().voices.count == 2)
        let before=try await a.snapshot().voices.first { $0.id == ids[1] }!.colourSlot
        try await a.forget(ids[0])
        #expect(try await b.snapshot().voices.first?.colourSlot == before)
    }
    @Test func unknownVersionIsPreservedAndCorruptDataIsQuarantined() async throws {
        let root=try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("people.json"), store=SavedVoicesStore(directory:root)
        let future=Data(#"{"version":99,"future":"keep"}"#.utf8)
        try future.write(to:file)
        #expect(try await store.snapshot().readOnly)
        await #expect(throws:SavedVoicesError.newerVersion) { try await store.forgetEveryone() }
        #expect(try Data(contentsOf:file) == future)
        try Data("bad".utf8).write(to:file)
        #expect(try await store.snapshot().voices.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath:root.path).contains { $0.hasPrefix("people.json.corrupt-") })
    }
    @Test func invalidBiometricsAndShortSpeechAreRejected() async throws {
        let root=try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let store=SavedVoicesStore(directory:root), g=try await store.snapshot().generation
        for values in [[Float](repeating:0,count:512),[Float.nan]+Array(repeating:0,count:511),[Float](repeating:1,count:511)] {
            await #expect(throws:SavedVoicesError.invalidPrint) { try await store.enroll(name:"A",embedding:values,seconds:4,generation:g) }
        }
        await #expect(throws:SavedVoicesError.invalidPrint) { try await store.enroll(name:"A",embedding:print,seconds:3.9,generation:g) }
    }
    @Test func selectionCutsOtherSpeakersTrimsAndCaps() {
        let words: [LibraryTranscriptItem] = [.init(speaker:"a",startMs:0,endMs:15000,text:"A"),.init(speaker:"b",startMs:5000,endMs:9000,text:"B")]
        let windows=VoiceSelection.windows(speaker:"a",words:words,durationMs:15000)
        #expect(windows == [200..<4800,9200..<14800])
        let long=VoiceSelection.windows(speaker:"a",words:[.init(speaker:"a",startMs:0,endMs:100000,text:"A")],durationMs:100000)
        #expect(long.reduce(0) { $0+$1.count } == 45000)
        #expect(long.allSatisfy { $0.count <= 10000 })
        #expect(VoiceSelection.windows(speaker:"a",words:[.init(speaker:"a",startMs:0,endMs:4000,text:"A")],durationMs:4000).isEmpty)
    }
}

struct SharedVoiceSelectionTests {
    @Test func sharedAndroidSelectionCases() throws {
        let file=Bundle.module.url(forResource:"vectors",withExtension:"json",subdirectory:"Golden/voices")!
        let root=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        var checked=0
        for test in root["cases"] as! [[String:Any]] {
            for check in test["checks"] as! [[String:Any]] where check["operation"] as? String == "select" {
                let input=check["input"] as! [String:Any], turns=input["turns"] as! [[String:Any]]
                let words=(input["words"] as! [[String:Any]]).map { LibraryTranscriptItem(speaker:$0["speaker"] as! String,startMs:($0["startMs"] as! NSNumber).int64Value,endMs:($0["endMs"] as! NSNumber).int64Value,text:$0["text"] as! String) }
                let duration=(input["totalSamples"] as! Int)*1000/(input["sampleRate"] as! Int)
                var actual:[String:[[Int]]]=[:]
                for speaker in Set(words.map(\.speaker)) {
                    var overlaps:[Int:Int64]=[:]
                    for turn in turns {
                        let id=turn["speaker"] as! Int
                        for word in words where word.speaker == speaker {
                            overlaps[id,default:0] += max(0,min(word.endMs,(turn["endMs"] as! NSNumber).int64Value)-max(word.startMs,(turn["startMs"] as! NSNumber).int64Value))
                        }
                    }
                    let native=overlaps.filter { $0.value > 0 }.max { $0.value < $1.value }?.key
                    let others=turns.filter { $0["speaker"] as? Int != native }.map { ($0["startMs"] as! NSNumber).int64Value..<($0["endMs"] as! NSNumber).int64Value }
                    let ranges=VoiceSelection.windows(speaker:speaker,words:words,durationMs:Int64(duration),otherRanges:others)
                    if !ranges.isEmpty { actual[speaker]=ranges.map { [Int($0.lowerBound)*16,Int($0.upperBound)*16] } }
                }
                let expected=check["expected"] as! [String:[[Int]]]
                #expect(actual == expected, "\(test["id"]!)")
                checked += 1
            }
        }
        #expect(checked == 7)
    }
}

struct DesktopVoiceRulesTests {
    @Test func mergedNativeVoicesKeepTheirOwnSpeechAndOnlyCutOtherVoices() {
        // Shared desktop-vectors: both raw labels resolve to one person.
        let words:[LibraryTranscriptItem] = [.init(speaker:"person",startMs:0,endMs:6000,text:"First"),.init(speaker:"person",startMs:7000,endMs:13000,text:"Second")]
        let ranges=VoiceSelection.windows(speaker:"person",words:words,durationMs:13000,otherRanges:[9000..<10000])
        #expect(ranges == [200..<8800,10200..<12800])
    }
    @Test func matchingUsesBothRivalsAndRejectsStaleVoices() {
        func axis(_ similarity:Float) -> [Float] { [similarity,sqrt(1-similarity*similarity)]+Array(repeating:0,count:510) }
        let first=SavedVoice(id:"one",name:"One",model:Voiceprint.model,dim:512,mean:axis(1),count:1,seconds:4,meetings:[],createdAt:0,updatedAt:0,colourSlot:0)
        var second=first; second.name="Two";second.mean=axis(0.95)
        let exact=VoiceMatcher.Print(speaker:"speaker",embedding:axis(1))
        #expect(VoiceMatcher.assign([exact],voices:[first]).first?.automatic == true)
        // Another speaker rivals the first speaker for the same saved voice.
        let rival=VoiceMatcher.Print(speaker:"rival",embedding:axis(0.95))
        #expect(VoiceMatcher.assign([exact,rival],voices:[first]).first?.automatic == false)
        #expect(VoiceMatcher.assign([exact],voices:[first],rejected:["speaker\u{1f}one"]).isEmpty)
        second.mean=[0]
        #expect(second.stale)
        #expect(VoiceMatcher.ranked(axis(1),voices:[second,first]).first?.voice.id == first.id)
    }
}

struct VoiceContributionTests {
    @Test func retryIsIdempotentAndUnenrollmentPreservesLifetimeSpeech() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=SavedVoicesStore(directory:root), g=try await store.snapshot().generation
        let embedding:[Float]=[1]+Array(repeating:0,count:511)
        let clip=VoiceClip(meeting:"Recording-one",speaker:"person",startMs:0,endMs:5000)
        let id=try await store.enroll(name:"A",embedding:embedding,seconds:5,generation:g,clip:clip)
        let retry=try await store.enroll(name:"A",embedding:embedding,seconds:5,generation:g,clip:clip)
        #expect(retry == id)
        #expect(try await store.snapshot().voices.first?.count == 1)
        _=try await store.enroll(name:"A",embedding:embedding,seconds:5,generation:g,into:id,
            clip:.init(meeting:"Received-one",speaker:"person",startMs:0,endMs:5000))
        try await store.unenroll(meeting:"Recording-one",speakers:["person"])
        let remaining=try await store.snapshot().voices.first
        #expect(remaining?.count == 1)
        #expect(remaining?.seconds == 10)
        #expect(remaining?.meetings == ["Received-one"])
        try await store.unenroll(meeting:"Received-one",speakers:["person"])
        #expect(try await store.snapshot().voices.isEmpty)
    }
}

struct LongVoiceSelectionTests {
    @Test func elevenHourTranscriptKeepsBoundedSpeech() {
        let words:[LibraryTranscriptItem]=(0..<100000).map { index in
            let start=Int64(index)*396
            return .init(speaker:index/40 % 2 == 0 ? "a":"b",startMs:start,endMs:start+350,text:"word")
        }
        let started=clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let windows=VoiceSelection.windows(speaker:"a",words:words,durationMs:39_600_000)
        let cpu=clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)-started
        // Generous Debug CPU budget excludes descheduling and catches a quadratic scan.
        #expect(cpu < 5_000_000_000)
        #expect(windows.reduce(0) { $0+$1.count } <= 45000)
        #expect(!windows.isEmpty)
    }
}
