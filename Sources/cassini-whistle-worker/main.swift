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
    SegmentedAudio.removeAbandonedScratch()
    let assets = try WhistleAssets.forWorker(arguments: Array(CommandLine.arguments.dropFirst()))
    let engine = try WhistleEngine(assets: assets)
    let lines = WhistleLineReader(fd: STDIN_FILENO)
    while let line = try lines.next() {
        var id: String?
        let response: Response
        do {
            let request = try JSONDecoder().decode(Request.self, from: line); id = request.id
            if let meeting = request.meeting, request.wav == nil {
                let vad = try VADAssets.forWorker(arguments: Array(CommandLine.arguments.dropFirst()))
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
