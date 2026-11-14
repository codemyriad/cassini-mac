// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import Testing
import CassiniKit
import CassiniRecording
@testable import CassiniLibrary

struct SpeakerEditsTests {
    private func fixture() throws -> (URL,LibraryMeeting) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("SpeakerEdits-"+UUID().uuidString)
        let session=try RecordingSession(parent:root,title:"Call",source:"macos")
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
        try session.append(id:"mic",pcm:Data(repeating:1,count:32000),offsetMs:0);try session.finish()
        try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id).transaction {
            $0["transcript"]=["status":"done","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]]
            $0["speakers"]=[["id":"a","name":"Me","provenance":"source","colourIndex":0,"voiceSource":["inputSHA256":String(repeating:"a",count:64),"turnsSHA256":String(repeating:"b",count:64)]],
                             ["id":"b","name":"Others","provenance":"source","colourIndex":1],
                             ["id":"c","name":NSNull(),"provenance":"unnamed","colourIndex":2]]
            $0["notes"]=[["atMs":0,"text":"Keep this note"]]
            $0["future"]=["keep":true]
        }
        let words=[("a",0,600,"First"),("a",400,800,"overlap"),("b",850,900,"Other"),("c",900,1000,"Third")]
        let items=words.map {["speaker":$0.0,"startMs":$0.1,"endMs":$0.2,"text":$0.3] as [String:Any]}
        try JSONSerialization.data(withJSONObject:["language":"en","items":items]).write(to:session.directory.appendingPathComponent("transcript.json"))
        return (root,try #require(LibraryScanner(root:root).meeting(at:session.directory)))
    }
    private func document(_ meeting:LibraryMeeting) throws -> JSON {
        try JSONParser.parse(Data(contentsOf:meeting.folder.appendingPathComponent("meeting.json")))
    }
    @Test func dialogQuoteUsesAudibleChronologicalTurnsAndBoundsLongText() throws {
        let (root,original)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        var meeting=original
        meeting.transcriptItems=[
            .init(speaker:"b",startMs:500,endMs:700,text:"  Yes.  "),
            .init(speaker:"a",startMs:0,endMs:1000,text:"First"),
            .init(speaker:"a",startMs:2000,endMs:4000,text:"  Longer\n  quote  "),
            .init(speaker:"a",startMs:5000,endMs:5000,text:"Not audible")]
        #expect(SpeakerEdits.quote(meeting,speaker:"a") == "Longer quote")
        #expect(SpeakerEdits.quote(meeting,speaker:"b") == "Yes.")
        #expect(SpeakerEdits.quote(meeting,speaker:"missing") == nil)
        meeting.transcriptItems=[.init(speaker:"a",startMs:0,endMs:1000,text:String(repeating:"é",count:300))]
        #expect(SpeakerEdits.quote(meeting,speaker:"a") == String(repeating:"é",count:240)+"…")
        meeting.transcriptItems=[.init(speaker:"a",startMs:0,endMs:0,text:"Silent")]
        #expect(SpeakerEdits.quote(meeting,speaker:"a") == nil)
    }
    @Test(arguments:["a\nb","a\u{0000}b","a\u{200D}b",String(repeating:"x",count:65)])
    func invalidNamesNeverWrite(_ value:String) throws {
        let (root,m)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let before=try document(m)
        #expect(!SpeakerEdits.validName(value))
        #expect(throws:(any Error).self) {try SpeakerEdits.apply(.name(speaker:"a",value:value),to:m,roots:[root])}
        #expect(try document(m)==before)
    }
    @Test func namesClearAndPreserveUnknownMetadataAndProducerBytes() throws {
        let (root,m)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let transcript=m.folder.appendingPathComponent("transcript.json"),body=try Data(contentsOf:transcript)
        let audio=try m.audioFiles.map {try Data(contentsOf:$0)},before=try document(m)
        try SpeakerEdits.apply(.name(speaker:"a",value:"  Alice  "),to:m,roots:[root])
        let named=try #require(LibraryScanner(root:root).meeting(at:m.folder))
        #expect(named.speakerNames.contains("Alice"))
        let first=try document(m)
        #expect(first["revision"]?.int==before["revision"]!.int!+1)
        #expect(first["speakers"]?.array?.first?["provenance"]?.string=="user")
        #expect(first["speakers"]?.array?.first?["voiceSource"]==before["speakers"]?.array?.first?["voiceSource"])
        #expect(first["notes"]==before["notes"] && first["future"]==before["future"])
        try SpeakerEdits.apply(.name(speaker:"a",value:" \n "),to:m,roots:[root])
        let cleared=try document(m),scan=try #require(LibraryScanner(root:root).meeting(at:m.folder))
        #expect(cleared["speakers"]?.array?.first?["name"] == .null)
        #expect(cleared["speakers"]?.array?.first?["nameCleared"] == .bool(true))
        #expect(scan.speakers.first?.provenance == .unnamed)
        #expect(try Data(contentsOf:transcript)==body)
        #expect(try m.audioFiles.map {try Data(contentsOf:$0)}==audio)
        #expect(SpeakerEdits.validName(String(repeating:"é",count:64)))
        #expect(!SpeakerEdits.validName(String(repeating:"e\u{301}",count:33)))
    }
    @Test func originalProducerLabelSurvivesNameClearAndMergeUndo() throws {
        let (root,m)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        try MeetingMetadataWriter(directory:m.folder,id:m.id).transaction {
            var speakers=$0["speakers"] as! [[String:Any]]
            speakers[0]["label"]="Intervenant 19";$0["speakers"]=speakers
        }
        try SpeakerEdits.apply(.name(speaker:"a",value:"Alice"),to:m,roots:[root])
        #expect(try document(m)["speakers"]?.array?.first?["nameCleared"]==nil)
        try SpeakerEdits.apply(.name(speaker:"a",value:""),to:m,roots:[root])
        #expect(try document(m)["speakers"]?.array?.first?["label"]?.string=="Intervenant 19")
        try SpeakerEdits.apply(.merge(from:"a",into:"b"),to:m,roots:[root])
        try SpeakerEdits.apply(.undoMerge,to:m,roots:[root])
        #expect(LibraryScanner(root:root).meeting(at:m.folder)?.speakers.first?.displayName=="Intervenant 19")
    }
    @Test func explicitClearSuppressesAReceivedEmbeddedName() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("SpeakerReceived-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source=repo.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/001-minimal-v1.opus")
        let m=try LibraryImport.copy(source,into:root),id=try #require(m.speakers.first?.id)
        let before=try Data(contentsOf:m.audioFiles[0])
        try SpeakerEdits.apply(.name(speaker:id,value:"Alice"),to:m,roots:[root])
        #expect(LibraryScanner(root:root).meeting(at:m.folder)?.speakers.first?.name=="Alice")
        try SpeakerEdits.apply(.name(speaker:id,value:""),to:m,roots:[root])
        let cleared=try #require(LibraryScanner(root:root).meeting(at:m.folder)?.speakers.first)
        #expect(cleared.name==nil && cleared.label==nil && cleared.provenance == .unnamed)
        #expect(try Data(contentsOf:m.audioFiles[0])==before)
    }
    @Test func mergeChainsUndoAndStaleIDsUseFreshMetadata() throws {
        let (root,m)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let transcript=m.folder.appendingPathComponent("transcript.json"),body=try Data(contentsOf:transcript)
        try SpeakerEdits.apply(.merge(from:"a",into:"b"),to:m,roots:[root])
        #expect(throws:(any Error).self) {try SpeakerEdits.apply(.merge(from:"a",into:"c"),to:m,roots:[root])}
        #expect(throws:(any Error).self) {try SpeakerEdits.apply(.merge(from:"b",into:"b"),to:m,roots:[root])}
        try SpeakerEdits.apply(.merge(from:"b",into:"c"),to:m,roots:[root])
        let merged=try #require(LibraryScanner(root:root).meeting(at:m.folder))
        #expect(merged.speakers.map(\.id)==["c"] && merged.speakerMergeCount==2)
        #expect(merged.transcriptItems.allSatisfy {$0.speaker=="c"})
        try SpeakerEdits.apply(.undoMerge,to:m,roots:[root])
        let undone=try #require(LibraryScanner(root:root).meeting(at:m.folder))
        #expect(undone.mergedInto==["a":"b"] && undone.speakerMergeCount==1)
        try MeetingMetadataWriter(directory:m.folder,id:m.id).transaction {$0["speakerMerges"]=[["from":"missing","into":"c"]]}
        #expect(LibraryScanner(root:root).meeting(at:m.folder)?.speakerMergeCount==1)
        try SpeakerEdits.apply(.undoMerge,to:m,roots:[root])
        #expect(try document(m)["speakerMerges"]?.array?.isEmpty==true)
        #expect(try Data(contentsOf:transcript)==body)
    }
    @Test func freshQueueStateAndOutsideRootsRefuseEdits() throws {
        let (root,m)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        #expect(throws:(any Error).self) {try SpeakerEdits.apply(.name(speaker:"a",value:"Alice"),to:m,roots:[])}
        try MeetingMetadataWriter(directory:m.folder,id:m.id).transaction {
            var transcript=$0["transcript"] as! [String:Any];transcript["status"]="queued";$0["transcript"]=transcript
        }
        let before=try document(m)
        #expect(throws:(any Error).self) {try SpeakerEdits.apply(.name(speaker:"a",value:"Alice"),to:m,roots:[root])}
        #expect(try document(m)==before)
    }
    @Test func chipOnlySpeakerCanBeNamedAndMerged() throws {
        let (root,m)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let vector=try #require(Bundle.module.url(forResource:"acknowledgment",withExtension:"words.json",subdirectory:"Golden/interjections"))
        var document=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:vector)) as? [String:Any])
        document["items"]=(document["items"] as! [[String:Any]]).map {word in
            var word=word;word["speaker"]=(word["speaker"] as? String)=="ada" ? "a" : "b";return word
        }
        try JSONSerialization.data(withJSONObject:document).write(to:m.folder.appendingPathComponent("transcript.json"))
        let fresh=try #require(LibraryScanner(root:root).meeting(at:m.folder))
        let rendering=TranscriptRendering.render(fresh.transcriptItems.map {.init(speaker:$0.speaker,startMs:$0.startMs,endMs:$0.endMs,text:$0.text)})
        #expect(rendering.runs.contains {$0.speaker=="b" && $0.host != nil})
        try SpeakerEdits.apply(.name(speaker:"b",value:"Bea"),to:m,roots:[root])
        #expect(LibraryScanner(root:root).meeting(at:m.folder)?.speakerNames.contains("Bea")==true)
        try SpeakerEdits.apply(.merge(from:"b",into:"a"),to:m,roots:[root])
        #expect(LibraryScanner(root:root).meeting(at:m.folder)?.speakers.map(\.id)==["a"])
    }
    @Test func elevenHourSpeakerFactsKeepExactTalkTimeAndSample() throws {
        let (root,m)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        var long=m
        let count=122_760
        long.transcriptItems=(0..<count).map {index in
            let start=Int64(index)*323
            return .init(speaker:index.isMultiple(of:2) ? "a" : "b",startMs:start,endMs:start+100,text:"word")
        }
        let started=clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let talk=SpeakerEdits.talkTime(long,speaker:"a"),sample=SpeakerEdits.sample(long,speaker:"a")
        let cpu=clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)-started
        #expect(talk==Int64(count/2)*100 && sample==0..<100)
        // Timing is diagnostic only: shared-runner speed cannot decide correctness.
        print("D24 speaker facts thread CPU ms: \(Double(cpu)/1_000_000)")
    }
    @Test func clearedUnnamedFallbackUsesTheSelectedCatalogAndKeepsProducerLabels() {
        var speaker=MeetingSpeaker(id:"a",name:nil,provenance:.unnamed,colourIndex:0)
        let expected=LibraryLocalization.shared.text("common.speaker.unnamed",["n":"1"],language:.fr,locale:Locale(identifier:"en_US"))
        #expect(speaker.displayName(language:.fr,locale:Locale(identifier:"en_US"))==expected)
        let row=SpeakerRowPresentation(speaker:speaker,turns:[],percent:0,language:.fr,locale:Locale(identifier:"en_US"))
        #expect(row.accessibilityLabel.contains(expected))
        speaker.label="Parlante 19"
        #expect(speaker.displayName(language:.fr)=="Parlante 19","Original writer-language labels remain verbatim")
    }
    @Test func zeroDurationWordsCannotAnchorAnAudibleSample() throws {
        let (root,m)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        var words=m
        words.transcriptItems=[.init(speaker:"a",startMs:0,endMs:0,text:""),.init(speaker:"a",startMs:100_000,endMs:100_100,text:"Voice")]
        #expect(SpeakerEdits.sample(words,speaker:"a")==100_000..<100_100)
        #expect(SpeakerEdits.talkTime(words,speaker:"a")==100)
        words.transcriptItems=[.init(speaker:"a",startMs:0,endMs:0,text:".")]
        #expect(SpeakerEdits.sample(words,speaker:"a")==nil)
    }
    @Test func unionTalkTimeAndLongestCappedSample() throws {
        let (root,m)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        #expect(SpeakerEdits.talkTime(m,speaker:"a")==800)
        var longer=m
        longer.transcriptItems=[.init(speaker:"a",startMs:0,endMs:500,text:"a"),.init(speaker:"b",startMs:600,endMs:700,text:"b"),.init(speaker:"a",startMs:1000,endMs:20_000,text:"c")]
        #expect(SpeakerEdits.sample(longer,speaker:"a")==1000..<11_000)
        #expect(SpeakerEdits.sample(longer,speaker:"missing")==nil)
    }
    @Test func readOnlyDirectoryScansEditableThenFailsSpeakerSaveAndSevenSpeakerAsideRendersInline() throws {
        let (root,m)=try fixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:m.folder.path)
            try? FileManager.default.removeItem(at:root)
        }
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:m.folder.path)
        let scanned=try #require(LibraryScanner(root:root).meeting(at:m.folder))
        #expect(!scanned.metadataReadOnly)
        #expect(scanned.metadataRevision != nil)
        #expect(throws:(any Error).self) {try SpeakerEdits.apply(.name(speaker:"a",value:"Ada"),to:scanned,roots:[root])}

        let turns=MeetingPresentation.turns([
            .init(speaker:"marta",startMs:4000,endMs:4900,text:"Let’s start with the budget,"),
            .init(speaker:"giulia",startMs:4900,endMs:5200,text:"Yes, agreed."),
            .init(speaker:"marta",startMs:5200,endMs:6100,text:"since travel is the one line we need to settle today."),
        ])
        let marta=try #require(turns.first {$0.speaker=="marta" && $0.host==nil})
        #expect(marta.asides.count==1)
        #expect(turns[marta.asides[0].turn].speaker=="giulia")
    }
    @Test func colourIndexRemainsFixedAcrossNamingClearingAndMerges() throws {
        let (root,m)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let scanner=LibraryScanner(root:root)
        #expect(m.speakers.map(\.colourIndex)==[0,1,2])
        #expect(m.speaker(for:"c")?.provenance == .unnamed)

        // Naming speaker c reveals slot 2 without shifting a or b.
        try SpeakerEdits.apply(.name(speaker:"c",value:"Clara"),to:m,roots:[root],scanner:scanner)
        let named=try #require(scanner.meeting(at:m.folder))
        #expect(named.speakers.map {($0.id,$0.colourIndex)}.map {"\($0.0):\($0.1)"} == ["a:0","b:1","c:2"])
        #expect(named.speaker(for:"c")?.provenance == .user)

        // Merging earlier speaker a (slot 0) into c (slot 2) moves a's earliest turn onto c in
        // chronological display order, yet c keeps slot 2 and b keeps slot 1 (HARMONY 10.11 / L-41).
        try SpeakerEdits.apply(.merge(from:"a",into:"c"),to:named,roots:[root],scanner:scanner)
        let merged=try #require(scanner.meeting(at:m.folder))
        #expect(merged.speakers.map(\.id) == ["c","b"])
        #expect(merged.speaker(for:"c")?.colourIndex == 2)
        #expect(merged.speaker(for:"b")?.colourIndex == 1)
        #expect(merged.speaker(for:"a")?.colourIndex == 2)

        // Clearing c's name restores unnamed provenance while keeping colourIndex == 2 in metadata.
        try SpeakerEdits.apply(.name(speaker:"c",value:""),to:merged,roots:[root],scanner:scanner)
        let cleared=try #require(scanner.meeting(at:m.folder))
        #expect(cleared.speaker(for:"c")?.provenance == .unnamed)
        #expect(cleared.speaker(for:"c")?.colourIndex == 2)

        // Undo merge restores a (slot 0), b (slot 1), c (slot 2).
        try SpeakerEdits.apply(.undoMerge,to:cleared,roots:[root],scanner:scanner)
        let undone=try #require(scanner.meeting(at:m.folder))
        #expect(undone.speakers.map {($0.id,$0.colourIndex)}.map {"\($0.0):\($0.1)"} == ["a:0","b:1","c:2"])
    }
}
