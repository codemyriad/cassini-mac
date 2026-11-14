// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import CryptoKit
import Observation
import CassiniLibrary
import CassiniPlayback
import CassiniModels
import CassiniTranscription
import CassiniWhistle

@MainActor @Observable final class SavedVoicesController {
    static let shared=SavedVoicesController()
    let store=SavedVoicesStore(directory:SpeechModelController.appData.appendingPathComponent("voices",isDirectory:true))
    private(set) var snapshot: SavedVoicesSnapshot?
    private(set) var busy=false
    private(set) var modelReady=false
    private(set) var downloading=false
    private(set) var progress: Double=0
    private(set) var message: String?
    private var playingID: String?
    var playing:String? { sample.active ? playingID:nil }
    private(set) var recording=false
    private(set) var sampleReady=false
    private(set) var savingEnrollment=false
    var enrollmentName=""
    var selectedExistingID: String?
    var setupPresented=false
    var enrollmentPresented=false
    @ObservationIgnored private var client: ModelDownloadClient?
    @ObservationIgnored private var downloadTask: Task<Void,Never>?
    @ObservationIgnored private var enrollmentTask: Task<Void,Never>?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private let recorderDelegate=VoiceRecorderDelegate()
    @ObservationIgnored private var recordingFile: URL?
    @ObservationIgnored private var prepared: (embedding:[Float], seconds:Double, generation:Int64)?
    @ObservationIgnored private let playback=SessionPlayback()
    @ObservationIgnored private lazy var sample=SpeakerSample(playback:playback)
    private(set) var enabled=RecordingPreferences.defaults.bool(forKey:"CassiniRememberVoices")
    var readOnly: Bool { snapshot?.readOnly ?? true }
    var voices: [SavedVoice] { snapshot?.voices ?? [] }
    private(set) var meetingCounts:[String:Int]=[:]
    private var meetingsByKey:[String:LibraryMeeting]=[:]
    static var modelDirectory: URL {
        SpeechModelController.appData.appendingPathComponent("models/" + ModelPin.savedVoices.id + "/" + ModelPin.savedVoices.sourceSHA256)
    }
    func refresh() async {
        do { snapshot=try await store.snapshot() }
        catch { message=UXText.text("savedVoices.changeFailed") }
        let meetings=LibraryStore.shared.meetings
        meetingsByKey=Dictionary(meetings.map { ($0.folder.lastPathComponent,$0) },uniquingKeysWith:{ first,_ in first })
        let keys=Set(meetingsByKey.keys), profiles=voices
        meetingCounts=await Task.detached(priority:.utility) {
            Dictionary(uniqueKeysWithValues:profiles.map { ($0.id,$0.meetings.filter { keys.contains($0) }.count) })
        }.value
        let file=Self.modelDirectory.appendingPathComponent("3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx")
        modelReady=await Task.detached(priority:.utility) {
            guard let size=try? file.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey]),
                  size.fileSize == 29_596_978, size.isSymbolicLink != true,
                  let data=try? Data(contentsOf:file,options:.mappedIfSafe) else { return false }
            return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() == Voiceprint.model
        }.value
    }
    func setEnabled(_ value: Bool) {
        enabled=value; RecordingPreferences.defaults.set(value,forKey:"CassiniRememberVoices")
    }
    func open() {
        SettingsNavigation.shared.tab = .transcription
        SettingsNavigation.shared.savedVoices=true
        SettingsNavigation.shared.open?()
    }
    func requestSetup() { setupPresented=true }
    func finishSetup(enable: Bool) {
        setEnabled(enable); setupPresented=false
        RecordingPreferences.defaults.set(true,forKey:"CassiniVoicesSetupSeen")
    }
    func download() {
        guard !downloading else { return }
        message=nil; downloading=true; progress=0
        let client=ModelDownloadClient { value in Task { @MainActor in Self.shared.progress=value } }
        self.client=client
        downloadTask=Task {
            do { _=try await client.install(appData:SpeechModelController.appData,voices:true) }
            catch is CancellationError {}
            catch {
                message=UXText.text("errors.modelDownloadFailed.line",["model":UXText.text("models.recogniseVoices.name")])
            }
            downloading=false; self.client=nil; downloadTask=nil
            await refresh()
        }
    }
    func cancelDownload() { downloadTask?.cancel(); client?.cancel() }
    func removeModel() {
        guard !busy, !downloading, !recording else { return }
        busy=true
        Task {
            do {
                // The installer owns locking and removal of model revisions.
                try await ModelDownloader(appData:SpeechModelController.appData,userAgent:ModelUserAgent.app()).remove(.savedVoices)
                modelReady=false
            } catch { message=UXText.text("savedVoices.changeFailed") }
            busy=false
        }
    }
    func rename(_ voice: SavedVoice, name: String) {
        mutate { try await self.store.rename(voice.id,to:name) }
    }
    func forget(_ voice: SavedVoice) {
        stopSample()
        mutate { try await self.store.forget(voice.id) }
    }
    func forgetEveryone() {
        stopSample()
        mutate { try await self.store.forgetEveryone() }
    }
    private func mutate(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, !readOnly else { return }
        busy=true; message=nil
        Task {
            do { try await operation(); snapshot=try await store.snapshot() }
            catch { message=UXText.text("savedVoices.changeFailed") }
            busy=false
        }
    }
    func playable(_ voice: SavedVoice) -> (LibraryMeeting,VoiceClip)? {
        guard let clip=snapshot?.clips[voice.id], let meeting=meetingsByKey[clip.meeting],
              meeting.canPlaySession, clip.startMs >= 0, clip.endMs > clip.startMs else { return nil }
        return (meeting,clip)
    }
    func play(_ voice: SavedVoice) {
        if playing == voice.id { stopSample(); return }
        guard let (_,clip)=playable(voice), let meeting=LibraryStore.shared.meetings.first(where: { $0.folder.lastPathComponent == clip.meeting }) else { return }
        stopSample()
        if sample.play(meeting,range:clip.startMs..<clip.endMs) { playingID=voice.id }
    }
    func stopSample() { sample.cancel(); playingID=nil }
    func beginEnrollment() {
        guard !readOnly else { return }
        cancelEnrollment(); enrollmentName=""; selectedExistingID=nil; message=nil
        enrollmentPresented=true
    }
    func cancelEnrollment() {
        enrollmentTask?.cancel(); enrollmentTask=nil
        recorder?.stop(); recorder=nil; recording=false; prepared=nil; sampleReady=false
        removeRecording()
    }
    private func removeRecording() {
        if let recordingFile { try? FileManager.default.removeItem(at:recordingFile.deletingLastPathComponent()) }
        recordingFile=nil
    }
    func startRecording() {
        guard !busy, modelReady, !readOnly, !recording,
              !RecordingController.shared.isRecording, !CaptureCollection.shared.isRecording else { return }
        prepared=nil; sampleReady=false; message=nil
        enrollmentTask=Task {
            guard await AVCaptureDevice.requestAccess(for:.audio), !Task.isCancelled, enrollmentPresented else { return }
            do {
                let root=FileManager.default.temporaryDirectory.appendingPathComponent("voice-enrollment-"+UUID().uuidString,isDirectory:true)
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                recordingFile=root.appendingPathComponent("sample.wav")
                let recorder=try AVAudioRecorder(url:recordingFile!,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000,
                    AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false])
                recorder.delegate=recorderDelegate
                self.recorder=recorder
                guard recorder.record(forDuration:45) else { throw SavedVoicesError.invalidPrint }
                recording=true
            } catch { removeRecording(); message=UXText.text("savedVoices.changeFailed") }
        }
    }
    func finishRecording() {
        guard recording, let file=recordingFile else { return }
        recorder?.stop(); recorder=nil; recording=false; busy=true
        enrollmentTask=Task {
            defer { busy=false; removeRecording() }
            do {
                let generation=try await store.snapshot().generation
                let samples=try await Task.detached(priority:.userInitiated) {
                    var output:[Float]=[]
                    try MeetingAudioDecoder.decode(file) { block,rate in
                        guard rate == 16000, output.count+block.count <= 720000 else { throw SavedVoicesError.invalidPrint }
                        output.append(contentsOf:block)
                    }
                    return output
                }.value
                let result=try await Self.embedding(samples,guided:true)
                try Task.checkCancellation()
                prepared=(result.embedding,result.seconds,generation); sampleReady=true
            } catch is CancellationError {}
            catch { message=UXText.text("voices.enroll.tooShort") }
        }
    }
    func saveEnrollment() {
        guard let prepared, SavedVoicesStore.validName(enrollmentName), !busy, !readOnly else { return }
        busy=true; message=nil
        let name=enrollmentName, existing=selectedExistingID
        savingEnrollment=true
        enrollmentTask=Task {
            defer { busy=false; savingEnrollment=false }
            do {
                try Task.checkCancellation()
                _=try await store.enroll(name:name,embedding:prepared.embedding,seconds:prepared.seconds,generation:prepared.generation,into:existing)
                snapshot=try await store.snapshot(); self.prepared=nil; sampleReady=false; enrollmentPresented=false
            } catch { message=UXText.text("savedVoices.changeFailed") }
        }
    }
    struct TranscriptEnrollment: Sendable {
        let embedding:[Float]
        let seconds:Double
        let generation:Int64
        let clip:VoiceClip
    }
    func prepare(_ meeting:LibraryMeeting,speaker:String) async throws -> TranscriptEnrollment? {
        guard modelReady, !readOnly else { return nil }
        let generation=try await store.snapshot().generation
        guard let selection=try await Task.detached(priority:.userInitiated,operation:{
            try VoiceEnrollmentAudio.prepare(meeting,speaker:speaker)
        }).value else { return nil }
        let result=try await Self.embedding(selection.samples)
        return .init(embedding:result.embedding,seconds:result.seconds,generation:generation,clip:selection.clip)
    }
    func enroll(_ prepared:TranscriptEnrollment,name:String,into id:String?) async throws {
        _=try await store.enroll(name:name,embedding:prepared.embedding,seconds:prepared.seconds,generation:prepared.generation,into:id,clip:prepared.clip)
        snapshot=try await store.snapshot()
    }
    struct EmbeddingResult: Decodable, Sendable { let embedding:[Float]; let seconds:Double }
    static func embedding(_ samples:[Float],guided:Bool=false) async throws -> EmbeddingResult {
        guard samples.count >= 64000, samples.count <= 720000 else { throw SavedVoicesError.invalidPrint }
        let data=samples.withUnsafeBytes { Data($0) }
        let worker=Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cassini-parakeet-worker")
        let result=try await WhistleSubprocess.run(executable:worker,arguments:[guided ? "--voice-guided":"--voice","--model",modelDirectory.path],
            environment:WhistleEnvironment.worker(),input:data,timeout:60)
        guard result.status == 0, result.inputError == nil else { throw SavedVoicesError.invalidPrint }
        return try JSONDecoder().decode(EmbeddingResult.self,from:result.stdout)
    }
}

#if DEBUG
@MainActor enum SavedVoicesSelfTest {
    static func run() async {
        guard SettingsFixture.id != nil, ProcessInfo.processInfo.environment["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1" else { exit(78) }
        let root=SpeechModelController.appData
        do {
            try FileManager.default.createDirectory(at:SavedVoicesController.modelDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            defer { try? FileManager.default.removeItem(at:root) }
            let model=SavedVoicesController.modelDirectory.appendingPathComponent("3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx")
            try await Task.detached(priority:.utility) {
                var bytes=Data()
                while bytes.count < 29_596_978 {
                    let part=try FileHandle.standardInput.read(upToCount:min(1 << 20,29_596_978-bytes.count)) ?? Data()
                    guard !part.isEmpty else { throw SavedVoicesError.invalidPrint }
                    bytes.append(part)
                }
                try bytes.write(to:model,options:.atomic)
            }.value
            let samples=(0..<80000).map { Float(sin(Double($0)*0.12)*0.1) }
            let result=try await SavedVoicesController.embedding(samples)
            guard let normalized=Voiceprint.normalized(result.embedding), result.seconds == 5 else { throw SavedVoicesError.invalidPrint }
            let store=SavedVoicesStore(directory:root.appendingPathComponent("voices"))
            let generation=try await store.snapshot().generation
            let id=try await store.enroll(name:"Fixture voice",embedding:normalized,seconds:5,generation:generation)
            guard try await store.snapshot().voices.count == 1 else { throw SavedVoicesError.invalidPrint }
            try await store.forget(id)
            var silenceRejected=false
            do { _=try await SavedVoicesController.embedding([Float](repeating:0,count:80000),guided:true) }
            catch { silenceRejected=true }
            guard silenceRejected else { throw SavedVoicesError.invalidPrint }
            var report:[String:Any] = ["dimension":normalized.count,"selectedSeconds":result.seconds,"guidedSilenceRejected":silenceRejected,
                "signedWorkerInference":true,"privateEnrollmentAndForget":true,"audioDevicesOpened":false]
            var pcm=Data()
            while let part=try FileHandle.standardInput.read(upToCount:65536), !part.isEmpty {
                guard pcm.count+part.count <= 1_303_680 else { throw SavedVoicesError.invalidPrint }
                pcm.append(part)
            }
            if !pcm.isEmpty { report["golden"]=try await golden(pcm) }
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:.sortedKeys)+Data([10]))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Saved voices proof failed: \(error)\n".utf8)); exit(1)
        }
    }
    private static func golden(_ data:Data) async throws -> [String:Any] {
        guard data.count == 651840*2,
              SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined() == "2726c250b0998b9a28c3cf442e34025e41fe2d568fdcbdbdfce2df6a9cff500e",
              let url=Bundle.main.url(forResource:"golden",withExtension:"json",subdirectory:"Fixtures/voices"),
              let spec=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any] else { throw SavedVoicesError.invalidPrint }
        let samples=data.withUnsafeBytes { bytes in stride(from:0,to:data.count,by:2).map { Float(Int16(littleEndian:bytes.loadUnaligned(fromByteOffset:$0,as:Int16.self)))/32768 } }
        var prints:[String:[Float]]=[:]
        for item in spec["prints"] as! [[String:Any]] {
            var selected:[Float]=[]
            for pair in item["windows"] as! [[Int]] { selected.append(contentsOf:samples[pair[0]..<pair[1]]) }
            let hash=selected.withUnsafeBytes { SHA256.hash(data:Data($0)).map {String(format:"%02x",$0)}.joined() }
            guard hash == item["inputSHA256"] as? String else { throw SavedVoicesError.invalidPrint }
            let result=try await SavedVoicesController.embedding(selected)
            guard let normalized=Voiceprint.normalized(result.embedding) else { throw SavedVoicesError.invalidPrint }
            prints[item["id"] as! String]=normalized
        }
        var comparisons:[[String:Any]]=[]
        for pair in spec["comparisons"] as! [[String:Any]] {
            let a=pair["a"] as! String,b=pair["b"] as! String
            guard let score=VoiceMatcher.cosine(prints[a]!,prints[b]!), abs(Double(score)-(pair["cosine"] as! Double)) <= 0.02 else { throw SavedVoicesError.invalidPrint }
            comparisons.append(["a":a,"b":b,"cosine":Double(score)])
        }
        // The full and second-window matches are verified by the production matcher.
        var matchReport:[String:Any]=[:]
        for scenario in spec["matches"] as! [[String:Any]] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("golden-voices-"+UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:root)}
            let store=SavedVoicesStore(directory:root), g=try await store.snapshot().generation
            var aliases:[String:String]=[:]
            for (id,printID) in scenario["voices"] as! [String:String] {
                let actualID=try await store.enroll(name:id,embedding:prints[printID]!,seconds:5,generation:g)
                aliases[actualID]=id
            }
            let speakers=(scenario["speakers"] as! [String:String]).sorted { $0.key < $1.key }.map { VoiceMatcher.Print(speaker:$0.key,embedding:prints[$0.value]!) }
            var actual:[String:[String:String]]=[:]
            for match in VoiceMatcher.assign(speakers,voices:try await store.snapshot().voices) {
                actual[match.speaker]=["voiceId":aliases[match.voiceID]!,"state":match.automatic ? "auto":"suggested"]
            }
            guard actual == scenario["expected"] as! [String:[String:String]] else { throw SavedVoicesError.invalidPrint }
            matchReport[scenario["id"] as! String]=actual
        }
        return ["dimension":512,"prints":prints.count,"comparisons":comparisons,"matches":matchReport]
    }

}
#endif

private final class VoiceRecorderDelegate:NSObject,AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder:AVAudioRecorder,successfully flag:Bool) {
        Task { @MainActor in SavedVoicesController.shared.finishRecording() }
    }
}
