#if DEBUG
import AppKit
import CassiniWhistle
import Darwin

/// Hosted-only packaging proof: a real sandboxed app starts its bundled,
/// sandbox-inheriting helper. Never records or opens an audio device.
@MainActor enum WhistleSelfTest {
    static func run() async {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true", environment["RUNNER_ENVIRONMENT"] == "github-hosted",
              environment["CASSINI_HOSTED_WHISTLE"] == "1" else { exit(78) }
        do {
            let bundle = Bundle.main
            let folder = bundle.resourceURL!.appendingPathComponent("Whistle")
            let worker = bundle.executableURL!.deletingLastPathComponent().appendingPathComponent("cassini-whistle-worker")
            let process = Process(); process.executableURL = worker
            process.arguments = ["--library", folder.appendingPathComponent("libneedle3.dylib").path, "--model", folder.appendingPathComponent("whistle.cact").path]
            process.environment = WhistleEnvironment.worker()
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            try process.run()
            let watchdog = Task { try await Task.sleep(for: .seconds(30)); if process.isRunning { process.terminate() } }
            defer { watchdog.cancel(); if process.isRunning { process.terminate() } }
            for id in ["first", "second"] {
                let request = try JSONSerialization.data(withJSONObject: ["id": id, "wav": folder.appendingPathComponent("jfk.wav").path])
                input.fileHandleForWriting.write(request + Data([10]))
            }
            try input.fileHandleForWriting.close()
            let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
            process.waitUntilExit()
            let stderr = errors.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                throw WhistleFailure.runtime("bundled worker status \(process.terminationStatus): \(String(decoding: stderr, as: UTF8.self)) \(String(decoding: data, as: UTF8.self))")
            }
            struct Response: Decodable { let id: String; let transcript: WhistleTranscript }
            let responses = try data.split(separator: 10).map { try JSONDecoder().decode(Response.self, from: Data($0)) }
            guard responses.count == 2, responses[0].id == "first", responses[1].id == "second",
                  responses[0].transcript.text == responses[1].transcript.text else { throw WhistleFailure.runtime("worker reuse failed") }
            let text = responses[0].transcript.text
            let reference = try String(contentsOf: folder.appendingPathComponent("jfk.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            func words(_ value: String) -> [String] { value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
            guard words(text) == words(reference) else { throw WhistleFailure.runtime("JFK words differ: " + text) }
            let report: [String: Any] = ["text": text, "wordReferenceMatch": true, "exactReferenceMatch": text == reference,
                                         "bundledSandboxWorker": true, "twoRequestsIdentical": true]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data([10]))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data(("Whistle packaging self-test failed: \(error)\n").utf8)); exit(1)
        }
    }
}
#endif
