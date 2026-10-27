import CassiniWhistle
import Foundation
import Darwin

// One model per child process; sequential line requests reuse it. The app's
// future transcription queue owns a single child, never an in-process engine.
struct Request: Decodable { let id: String; let wav: String }
struct Response: Encodable { let id: String?; var transcript: WhistleTranscript?; var error: String? }
func emit(_ response: Response) {
    if let data = try? JSONEncoder().encode(response) { FileHandle.standardOutput.write(data + Data([10])) }
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
    while let line = readLine() {
        var id: String?
        do {
            guard line.utf8.count <= 65536 else { throw WhistleFailure.audio }
            let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8)); id = request.id
            emit(Response(id: id, transcript: try engine.transcribe(wav: URL(fileURLWithPath: request.wav))))
        } catch { emit(Response(id: id, error: String(describing: error))) }
    }
} catch {
    emit(Response(id: nil, error: String(describing: error)))
    exit(78)
}
