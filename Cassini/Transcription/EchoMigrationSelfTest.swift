// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import Foundation
import AppKit
import CassiniLibrary
import CassiniRecording
import CassiniTranscription
import Darwin

/// Disposable hosted app proof: no model, browser, microphone or output device.
@MainActor enum EchoMigrationSelfTest {
    static var enabled: Bool { RecordingFixture.enabled && CommandLine.arguments.contains("--existing-echo-self-test") }
    private final class Hold: @unchecked Sendable {
        private let lock = NSLock(); private var held = true
        func release() { lock.withLock { held = false } }
        func checkpoint() throws {
            while lock.withLock({ held }) { try Task.checkCancellation(); usleep(1000) }
        }
    }
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain:"EchoMigrationSelfTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    }
    private static func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime+8
        while !condition(), ProcessInfo.processInfo.systemUptime<deadline { try await Task.sleep(for:.milliseconds(10)) }
        try require(condition(),"Echo migration did not settle")
    }
    static func run() async {
        guard enabled, CaptureFixture.enabled, let root = RecordingFixture.root else { exit(78) }
        let queue = TranscriptionQueue.shared, hold = Hold(), captures = CaptureCollection.shared
        var stage = "create old transcript"
        do {
            let admission = UUID(); var publishedDuringCapture = false
            CaptureActivityStore.shared.set(admission,.preparing)
            do { try CaptureActivityStore.shared.commitWhileIdle { publishedDuringCapture = true } }
            catch is CancellationError { /* expected */ }
            CaptureActivityStore.shared.set(admission,nil)
            try require(!publishedDuringCapture,"Capture admission excludes an idle maintenance commit")
            let old = try RecordingSession(parent:root,title:"Old echo",source:"macos")
            for (id,kind,amplitude) in [("mic","microphone",0.02),("other","system",0.2)] {
                try old.addTrack(id:id,label:id,kind:kind,sampleRate:16000,channels:1)
                let samples = (0..<16000).map { Int16((sin(Double($0)*2*Double.pi*440/16000)*amplitude*32767).rounded()).littleEndian }
                try samples.withUnsafeBytes { try old.appendNative(id:id,pcm:Data($0),offsetMs:0) }
            }
            try old.finish()
            let words: [[String:Any]] = [
                ["speaker":"others","startMs":0,"endMs":100,"text":"same"],
                ["speaker":"me","startMs":300,"endMs":400,"text":"same"],
                ["speaker":"me","startMs":700,"endMs":800,"text":"mine"]
            ]
            let transcript = old.directory.appendingPathComponent("transcript.json")
            try JSONSerialization.data(withJSONObject:["language":"en","items":words]).write(to:transcript)
            let metadata = try MeetingMetadataWriter(directory:old.directory,id:old.manifest.id)
            try metadata.transaction { $0["transcript"] = ["status":"done","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]] }
            let preserved = try ["meeting.json","session.json","track-mic.wav","track-other.wav"].map { ($0,try Data(contentsOf:old.directory.appendingPathComponent($0))) }
            let before = try Data(contentsOf:transcript)
            queue.echoCheckpointFixture = hold.checkpoint
            LibraryStore.shared.start()
            stage = "automatic discovery"
            try await wait { queue.classifyingEchoFixture && queue.active.map(LibraryLocation.canonical) == LibraryLocation.canonical(old.directory) }
            try require(queue.activeModel == nil,"Maintenance never selects an inference model")
            stage = "recording preempts maintenance"
            try await captures.record()
            try await wait { captures.isRecording && captures.first?.snapshot.manifest.tracks.contains { $0.frames>0 } == true }
            let marker = old.directory.appendingPathComponent(ExistingTranscriptEcho.markerName)
            try require(!queue.classifyingEchoFixture,"Recording cancels and joins background classification")
            try require(try Data(contentsOf:transcript) == before && !FileManager.default.fileExists(atPath:marker.path),"No partial flags or completion marker during recording")
            hold.release(); queue.echoCheckpointFixture = nil
            LibraryStore.shared.refresh(affected:old.directory)
            try await Task.sleep(for:.milliseconds(50))
            try require(!queue.classifyingEchoFixture && !FileManager.default.fileExists(atPath:marker.path),"Library refresh cannot classify while recording")
            await captures.stopAndWait()
            stage = "idle resume"
            LibraryStore.shared.refresh(affected:old.directory)
            try await wait { FileManager.default.fileExists(atPath:marker.path) && !queue.classifyingEchoFixture }
            let body = try JSONSerialization.jsonObject(with:Data(contentsOf:transcript)) as! [String:Any]
            let actual = body["items"] as! [[String:Any]]
            try require(actual.count == 3 && actual[1]["echo"] as? Bool == true && actual[0]["echo"] == nil && actual[2]["echo"] == nil,"Only the repeated microphone word is flagged")
            for (name,data) in preserved { try require(try Data(contentsOf:old.directory.appendingPathComponent(name)) == data,"Source audio and metadata remain unchanged") }
            let stamp = try Data(contentsOf:marker), finished = try Data(contentsOf:transcript)
            let revision = LibraryStore.shared.revision
            LibraryStore.shared.refresh(affected:old.directory)
            try await wait { LibraryStore.shared.revision > revision && !queue.isBusy }
            try require(try Data(contentsOf:marker) == stamp && Data(contentsOf:transcript) == finished,"Repeated discovery is idempotent")
            queue.beginShutdown(); await queue.waitForShutdown(); LibraryStore.shared.stop()
            await captures.shutdown()
            let result: [String:Any] = ["captureAdmissionGuardsPublication":true,"automaticBackgroundClassification":true,"recordingPreemptsClassification":true,"idleClassificationResumes":true,"metadataAndAudioPreserved":true,"idempotentMarker":true,"noInferenceModel":true,"audioDevicesOpened":false,"cleanupPath":root.path]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])+Data([10])); exit(0)
        } catch {
            hold.release(); queue.beginShutdown(); await queue.waitForShutdown(); await captures.shutdown(); LibraryStore.shared.stop()
            FileHandle.standardError.write(Data("Echo migration failed at \(stage): \(error)\n".utf8)); exit(1)
        }
    }
}
#endif
