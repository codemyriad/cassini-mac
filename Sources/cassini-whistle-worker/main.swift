// SPDX-License-Identifier: GPL-3.0-or-later
import CassiniWhistle
import CassiniTranscription
import Foundation
import Darwin

// One model per child process; sequential line requests reuse it. The app's
// future transcription queue owns a single child, never an in-process engine.
struct Request: Decodable { let id: String; let wav: String?; let meeting: String?; let me: String?; let others: String? }
struct Response: Encodable { let id: String?; var transcript: WhistleTranscript?; var error: String? }
func emit(_ response: Response) throws {
    try WhistleIO.write(JSONEncoder().encode(response) + Data([10]), to: STDOUT_FILENO)
}
do {
    // The exact C environment is checked before asset verification or dlopen.
    try WhistleEnvironment.validateLive()
    // A killed parent cannot cancel its Task. Reparenting must stop this helper
    // even while the recognizer is inside a blocking native call. Do not use
    // stdin EOF as liveness: clients close stdin after their final request.
    let owner = getppid()
    guard owner > 1 else { exit(0) }
    let ownerWatchdog = DispatchSource.makeTimerSource(queue:.global())
    ownerWatchdog.schedule(deadline:.now() + .milliseconds(200),repeating:.milliseconds(200))
    // Top-level Swift code is main-actor isolated. Dispatch's preconcurrency
    // callback must explicitly be Sendable or Swift6.1 checks that isolation
    // on the global queue and traps at the first watchdog tick.
    ownerWatchdog.setEventHandler { @Sendable in if getppid() != owner { exit(0) } }
    ownerWatchdog.resume()
    defer { ownerWatchdog.cancel() }
    SegmentedAudio.removeAbandonedScratch()
    let assets = try WhistleAssets.forWorker(arguments: Array(CommandLine.arguments.dropFirst()))
    let engine = try WhistleEngine(assets: assets)
    var vadAssets: VADAssets?
    let lines = WhistleLineReader(fd: STDIN_FILENO)
    while let line = try lines.next() {
        var id: String?
        let response: Response
        do {
            let request = try JSONDecoder().decode(Request.self, from: line); id = request.id
            if let meeting = request.meeting, request.wav == nil {
                let vad = try vadAssets ?? VADAssets.verified(for:assets)
                vadAssets = vad
                let detector = try SpeechDetector(assets: vad)
                try MeetingTranscriber.run(directory: URL(fileURLWithPath: meeting), engine: engine, detector: detector, me: request.me ?? "Me", others: request.others ?? "The others")
                response = Response(id: id)
            } else if let wav = request.wav, request.meeting == nil {
                response = Response(id: id, transcript: try engine.transcribe(wav: URL(fileURLWithPath: wav)))
            } else { throw TranscriptionFailure.invalidMeeting }
        } catch { response = Response(id: id, error: String(describing: error)) }
        try emit(response)
    }
} catch {
    try? emit(Response(id: nil, error: String(describing: error)))
    exit(78)
}
