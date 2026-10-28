// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CassiniWhistle
import CassiniTranscription
import CassiniParakeet

struct Request: Decodable { let id: String; let meeting: String; let me: String?; let others: String? }
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
    watchdog.setEventHandler { @Sendable in if getppid() != owner { exit(0) } }
    watchdog.resume(); defer { watchdog.cancel() }
    SegmentedAudio.removeAbandonedScratch()
    var arguments = Array(CommandLine.arguments.dropFirst()), standaloneVAD: URL?
    if arguments.count == 6, arguments[4] == "--vad" {
        standaloneVAD = URL(fileURLWithPath:arguments[5]); arguments.removeLast(2)
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
        model:ParakeetPin.transcriptModel,initialETA:0.3,initialLanguage:"und",me:request.me ?? "Me",others:request.others ?? "The others",recognize:engine.transcribe)
    try emit(Response(id:request.id,error:nil,code:nil))
    // One recognizer/job/process. Its model memory is released on exit.
} catch {
    let code: String
    if case ParakeetFailure.invalidModel = error { code = "invalid-model" }
    else { code = "transcribe-failed" }
    try? emit(Response(id:requestID,error:String(describing:error),code:code)); exit(78)
}
