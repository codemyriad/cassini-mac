// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import CassiniWhistle
import CassiniRecording
import CassiniLibrary
import Darwin

/// Opt-in packaging proof: a real sandboxed app starts its bundled,
/// sandbox-inheriting helper. Never records or opens an audio device.
@MainActor enum WhistleSelfTest {
    static func run() async {
        let environment = ProcessInfo.processInfo.environment
        let hosted = environment["GITHUB_ACTIONS"] == "true" && environment["RUNNER_ENVIRONMENT"] == "github-hosted"
        let local = environment["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1"
        guard hosted || local, environment["CASSINI_HOSTED_WHISTLE"] == "1" else { exit(78) }
        do {
            let bundle = Bundle.main
            let folder = bundle.resourceURL!.appendingPathComponent("Whistle")
            let worker = bundle.executableURL!.deletingLastPathComponent().appendingPathComponent("cassini-whistle-worker")
            var input = Data()
            for id in ["first", "second"] {
                let request = try JSONSerialization.data(withJSONObject: ["id": id, "wav": folder.appendingPathComponent("jfk.wav").path])
                input.append(request + Data([10]))
            }
            let result = try await WhistleSubprocess.run(executable: worker,
                arguments: [],
                environment: WhistleEnvironment.worker(), input: input)
            let data = result.stdout
            guard result.status == 0, result.inputError == nil else {
                throw WhistleFailure.runtime("bundled worker status \(result.status), input \(String(describing: result.inputError)): \(String(decoding: result.stderr, as: UTF8.self)) \(String(decoding: data, as: UTF8.self))")
            }
            struct Response: Decodable { let id: String; let transcript: WhistleTranscript }
            let responses = try data.split(separator: 10).map { try JSONDecoder().decode(Response.self, from: Data($0)) }
            guard responses.count == 2, responses[0].id == "first", responses[1].id == "second",
                  responses[0].transcript.text == responses[1].transcript.text else { throw WhistleFailure.runtime("worker reuse failed") }
            let text = responses[0].transcript.text
            let reference = try String(contentsOf: folder.appendingPathComponent("jfk.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            func words(_ value: String) -> [String] { value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
            guard words(text) == words(reference) else { throw WhistleFailure.runtime("JFK words differ: " + text) }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniPipelineProbe-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temporary) }
            let session = try RecordingSession(parent: temporary, title: "Offline JFK", source: "macos")
            try session.addTrack(id: "microphone", label: "Microphone", kind: "microphone", sampleRate: 16000, channels: 1)
            let pcm = try Data(contentsOf: folder.appendingPathComponent("jfk.wav")).dropFirst(44)
            for at in stride(from: 0, to: pcm.count, by: 64000) {
                let start = pcm.startIndex + at, end = min(pcm.endIndex, start + 64000)
                try session.append(id: "microphone", pcm: Data(pcm[start..<end]), offsetMs: Double(at) / 32)
            }
            try session.finish()
            try MeetingMetadataWriter(directory: session.directory, id: session.manifest.id).createIfNeeded()
            let request = try JSONSerialization.data(withJSONObject: ["id":"pipeline", "meeting":session.directory.path]) + Data([10])
            let pipeline = try await WhistleSubprocess.run(executable: worker, arguments: [], environment: WhistleEnvironment.worker(), input: request, timeout: 60)
            let pipelineResponse = try JSONSerialization.jsonObject(with: pipeline.stdout) as! [String:Any]
            guard pipeline.status == 0, pipeline.inputError == nil, pipelineResponse["error"] == nil,
                  let written = try LibraryScanner(root: temporary).scan().meetings.first,
                  written.state.transcript == .done, !written.transcriptItems.isEmpty, written.speakers.first?.id == "me" else {
                throw WhistleFailure.runtime("sandboxed pipeline failed: " + String(decoding: pipeline.stdout + pipeline.stderr, as: UTF8.self))
            }
            let report: [String: Any] = ["text": text, "wordReferenceMatch": true, "exactReferenceMatch": text == reference,
                                         "bundledSandboxWorker": true, "bundledVADPipeline": true, "twoRequestsIdentical": true]
            try WhistleIO.write(JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data([10]), to: STDOUT_FILENO)
            exit(0)
        } catch {
            try? WhistleIO.write(Data(("Whistle packaging self-test failed: \(error)\n").utf8), to: STDERR_FILENO); exit(1)
        }
    }
}
#endif
