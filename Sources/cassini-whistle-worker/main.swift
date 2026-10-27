import CassiniWhistle
import Foundation
import Darwin

// One model per child process; sequential line requests reuse it. The app's
// future transcription queue owns a single child, never an in-process engine.
struct Request: Decodable { let id: String; let wav: String }
struct Response: Encodable { let id: String?; var transcript: WhistleTranscript?; var error: String? }
func emit(_ response: Response) throws {
    try WhistleIO.write(JSONEncoder().encode(response) + Data([10]), to: STDOUT_FILENO)
}
func argument(_ key: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: key), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}
do {
    // Fail closed before even considering the library path, not after loading it.
    try WhistleEnvironment.validate(ProcessInfo.processInfo.environment)
    guard let library = argument("--library"), let model = argument("--model") else {
        throw WhistleFailure.library("--library and --model are required")
    }
    let engine = try WhistleEngine(library: URL(fileURLWithPath: library), model: URL(fileURLWithPath: model))
    let lines = WhistleLineReader(fd: STDIN_FILENO)
    while let line = try lines.next() {
        var id: String?
        let response: Response
        do {
            let request = try JSONDecoder().decode(Request.self, from: line); id = request.id
            response = Response(id: id, transcript: try engine.transcribe(wav: URL(fileURLWithPath: request.wav)))
        } catch { response = Response(id: id, error: String(describing: error)) }
        try emit(response)
    }
} catch {
    try? emit(Response(id: nil, error: String(describing: error)))
    exit(78)
}
