// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CassiniWhistle
import CassiniTranscription
import CassiniLibrary
import CassiniParakeet

struct Request: Decodable { let id: String; let meeting: String; let me: String?; let others: String?; let uiLanguage: String? }
struct Response: Encodable { let id: String?; let error: String?; let code: String? }
func emit(_ response: Response) throws { try WhistleIO.write(JSONEncoder().encode(response) + Data([10]),to:STDOUT_FILENO) }
var requestID: String?
do {
    try WhistleEnvironment.validateLive()
    #if DEBUG
    if try SpeechNetworkProbe.run(arguments:Array(CommandLine.arguments.dropFirst())) { exit(0) }
    #endif
    let owner = getppid()
    guard owner > 1 else { exit(0) }
    let watchdog = DispatchSource.makeTimerSource(queue:.global())
    watchdog.schedule(deadline:.now() + .milliseconds(200),repeating:.milliseconds(200))
    #if DEBUG
    // Private inherited-FD acknowledgement for event-driven owner-lifetime tests.
    // No stdout/protocol message or release-worker behavior changes.
    let ownerTickFD = Int32(ProcessInfo.processInfo.environment["CASSINI_TEST_OWNER_TICK_FD"] ?? "")
    #endif
    watchdog.setEventHandler { @Sendable in
        if getppid() != owner { exit(0) }
        #if DEBUG
        if let fd = ownerTickFD, fd >= 3 {
            var tick: UInt8 = 1
            _ = write(fd,&tick,1)
        }
        #endif
    }
    watchdog.resume(); defer { watchdog.cancel() }
    SegmentedAudio.removeAbandonedScratch()
    var arguments = Array(CommandLine.arguments.dropFirst()), standaloneVAD: URL?
    if arguments.count == 6, arguments[4] == "--vad" {
        standaloneVAD = URL(fileURLWithPath:arguments[5]); arguments.removeLast(2)
    }
    if arguments.count == 3, ["--voice","--voice-guided"].contains(arguments[0]), arguments[1] == "--model" {
        let assets=try ParakeetAssets.voiceWorker(model:URL(fileURLWithPath:arguments[2]))
        // Raw little-endian float32 PCM from the parent, bounded to 45 seconds.
        var data=Data()
        while let part=try FileHandle.standardInput.read(upToCount:65536), !part.isEmpty {
            guard data.count + part.count <= 720000 * 4 else { throw ParakeetFailure.invalidAudio }
            data.append(part)
        }
        guard data.count % 4 == 0 else { throw ParakeetFailure.invalidAudio }
        var samples=data.withUnsafeBytes { bytes in stride(from:0,to:data.count,by:4).map { Float(bitPattern:UInt32(littleEndian:bytes.loadUnaligned(fromByteOffset:$0,as:UInt32.self))) } }
        if arguments[0] == "--voice-guided" {
            let detector=try SpeechDetector(assets:VADAssets.bundled(assets.signedBundle!))
            var gate=SpeechGate(), voiced=0
            var segments=try gate.feed(samples) { frame in
                let probability=try detector.probability(frame)
                if probability >= 0.5 { voiced += 512 }
                return probability
            }
            segments += gate.flush()
            guard voiced >= 64000 else { throw ParakeetFailure.invalidAudio }
            var selected:[Float]=[]
            for segment in segments {
                let a=segment.startSample+3200, b=min(samples.count,segment.endSample-3200)
                if b-a >= 24000 { selected.append(contentsOf:samples[a..<b]) }
            }
            samples=Array(selected.prefix(720000))
        }
        let embedding=try VoiceEmbeddingEngine.compute(assets:assets,samples:samples)
        struct VoiceResult: Encodable { let embedding:[Float]; let seconds:Double }
        try WhistleIO.write(JSONEncoder().encode(VoiceResult(embedding:embedding,seconds:Double(samples.count)/16000)),to:STDOUT_FILENO)
        exit(0)
    }
    let assets = try ParakeetAssets.forWorker(arguments:arguments)
    let vad: VADAssets
    if let bundle = assets.signedBundle {
        guard standaloneVAD == nil else { throw ParakeetFailure.invalidRuntime }
        vad = try VADAssets.bundled(bundle)
    } else {
        guard let standaloneVAD else { throw ParakeetFailure.invalidRuntime }
        vad = try VADAssets.pinned(directory:standaloneVAD)
    }
    let engine = try ParakeetEngine(assets:assets)
    let detector = try SpeechDetector(assets:vad)
    guard let line = try WhistleLineReader(fd:STDIN_FILENO).next() else { exit(0) }
    let request = try JSONDecoder().decode(Request.self,from:line); requestID = request.id
    try MeetingTranscriber.run(directory:URL(fileURLWithPath:request.meeting),detector:detector,
        model:ParakeetPin.transcriptModel,initialETA:0.3,initialLanguage:"und",me:request.me ?? "Me",others:request.others ?? "The others",uiLanguage:request.uiLanguage.flatMap(CassiniLanguage.init(rawValue:)) ?? .system,recognize:engine.transcribe)
    try emit(Response(id:request.id,error:nil,code:nil))
    // One recognizer/job/process. Its model memory is released on exit.
} catch {
    let code: String
    if case ParakeetFailure.invalidModel = error { code = "invalid-model" }
    else if case ParakeetFailure.invalidAudio = error, ["--voice","--voice-guided"].contains(CommandLine.arguments.dropFirst().first ?? "") { code = "voice-too-short" }
    else { code = "transcribe-failed" }
    try? emit(Response(id:requestID,error:String(describing:error),code:code)); exit(78)
}
