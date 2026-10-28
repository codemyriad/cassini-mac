// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import CassiniRecording
import CassiniLibrary
import CassiniParakeet
import CassiniWhistle
import Darwin

/// Private generated-file proof over the actual queue and signed helpers. Model
/// bytes arrive through stdin, not a sandbox exemption or a network download.
@MainActor enum ParakeetSelfTest {
    static func run() async {
        let env = ProcessInfo.processInfo.environment
        guard SettingsFixture.id != nil,
              env["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1" || env["GITHUB_ACTIONS"] == "true" && env["RUNNER_ENVIRONMENT"] == "github-hosted" else { exit(78) }
        let dataRoot = SpeechModelController.appData
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniParakeetProbe-" + UUID().uuidString)
        let backup = dataRoot.appendingPathComponent("private-input")
        let models = SpeechModelController.shared, queue = TranscriptionQueue.shared
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            defer {
                try? FileManager.default.removeItem(at:root); try? FileManager.default.removeItem(at:dataRoot)
                if let id = SettingsFixture.id { SettingsFixture.defaults?.removePersistentDomain(forName:"com.codemyriad.cassini-mac.settings-fixture." + id.uuidString) }
            }
            try await Task.detached(priority:.utility) {
                try FileManager.default.createDirectory(at:backup,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                for (name,pin) in ParakeetPin.files.sorted(by:{ $0.key < $1.key }) {
                    let file = backup.appendingPathComponent(name)
                    guard FileManager.default.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw POSIXError(.EIO) }
                    let stream = try FileHandle(forWritingTo:file); defer { try? stream.close() }
                    var remaining = pin.bytes
                    while remaining > 0 {
                        let bytes = try FileHandle.standardInput.read(upToCount:Int(min(remaining,1 << 20))) ?? Data()
                        guard !bytes.isEmpty else { throw POSIXError(.EIO) }
                        try stream.write(contentsOf:bytes); remaining -= UInt64(bytes.count)
                    }
                }
                guard try FileHandle.standardInput.read(upToCount:1)?.isEmpty != false else { throw POSIXError(.EINVAL) }
            }.value
            try install(backup)
            models.chooseParakeet(false); await models.refresh()
            guard models.downloaded, !models.usesParakeet else { throw POSIXError(.EINVAL) }
            models.chooseParakeet(true)
            let first = try meeting(root:root,title:"Parakeet active")
            let second = try meeting(root:root,title:"Whistle queued")
            queue.enqueue(first)
            try await wait { queue.activeModel == "parakeet" }
            // This is after the production queue accepts and retains the lease,
            // before this worker necessarily finishes hashing/loading the model.
            models.remove(); await models.waitForOperation()
            guard !models.usesParakeet, !models.downloaded,
                  !FileManager.default.fileExists(atPath:SpeechModelController.modelDirectory.path),
                  models.message == UXText.text("models.parakeetUltra.removedFallback") else { throw POSIXError(.EINVAL) }
            queue.enqueue(second)
            try await wait { !queue.isBusy }
            let firstDone = try checked(first,model:ParakeetPin.transcriptModel,language:"und")
            _ = try checked(second,model:"whistle",language:nil)
            // Same-size corrupt tokens pass inventory, then fail the worker's
            // pinned hash check. The real queue must retry in Whistle unchanged.
            try install(backup)
            let tokens = SpeechModelController.modelDirectory.appendingPathComponent("tokens.txt")
            try FileManager.default.removeItem(at:tokens)
            try Data(repeating:0,count:Int(ParakeetPin.files["tokens.txt"]!.bytes)).write(to:tokens)
            await models.reloadInventory(); models.chooseParakeet(true)
            guard models.usesParakeet else { throw POSIXError(.EINVAL) }
            let third = try meeting(root:root,title:"Invalid model fallback")
            queue.enqueue(third); try await wait { !queue.isBusy }
            _ = try checked(third,model:"whistle",language:nil)
            guard !models.usesParakeet, !models.downloaded,
                  models.message == UXText.text("models.parakeetUltra.invalidFallback"),
                  RecordingPreferences.defaults.string(forKey:"CassiniSpeechModel") == "whistle",
                  !FileManager.default.fileExists(atPath:SpeechModelController.modelDirectory.path) else { throw POSIXError(.EINVAL) }
            let report: [String:Any] = ["sandboxedBundledParakeet":true,"parakeetWords":firstDone.transcriptItems.count,
                "installedModelDoesNotSelect":true,"removePreservesAcceptedJob":true,"queuedJobUsesWhistle":true,
                "invalidModelRetriesWhistle":true,"invalidModelDeleted":true,"choicePersisted":true,
                "metadataAndAudioPreserved":true,"audioDevicesOpened":false]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) + Data([10])); exit(0)
        } catch {
            queue.beginShutdown(); await queue.waitForShutdown()
            FileHandle.standardError.write(Data("Parakeet app proof failed: \(error)\n".utf8)); exit(1)
        }
    }
    private static func install(_ input: URL) throws {
        let target = SpeechModelController.modelDirectory
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        for name in ParakeetPin.files.keys {
            guard link(input.appendingPathComponent(name).path,target.appendingPathComponent(name).path) == 0 else { throw POSIXError(.EIO) }
        }
    }
    private static func meeting(root: URL,title: String) throws -> LibraryMeeting {
        let session = try RecordingSession(parent:root,title:title,source:"macos")
        try session.addTrack(id:"microphone",label:"Microphone",kind:"microphone",sampleRate:16000,channels:1)
        let pcm = try Data(contentsOf:Bundle.main.resourceURL!.appendingPathComponent("Whistle/jfk.wav")).dropFirst(44)
        for at in stride(from:0,to:pcm.count,by:64000) {
            let start = pcm.startIndex + at, end = min(pcm.endIndex,start + 64000)
            try session.append(id:"microphone",pcm:Data(pcm[start..<end]),offsetMs:Double(at)/32)
        }
        try session.finish()
        let writer = try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id)
        try writer.transaction {
            $0["title"] = title; $0["titleSource"] = "user"
            $0["notes"] = [["atMs":0,"text":"Keep this note"]]
        }
        guard let meeting = try LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == session.manifest.id }) else { throw POSIXError(.EINVAL) }
        return meeting
    }
    private static func checked(_ original: LibraryMeeting,model: String,language: String?) throws -> LibraryMeeting {
        guard let found = try LibraryScanner(root:original.folder.deletingLastPathComponent()).scan().meetings.first(where:{ $0.id == original.id }),
              found.state.transcript == .done, found.transcriptModel == model, !found.transcriptItems.isEmpty,
              found.title == original.title, found.notes == original.notes else { throw POSIXError(.EINVAL) }
        let body = try JSONSerialization.jsonObject(with:Data(contentsOf:original.folder.appendingPathComponent("transcript.json"))) as! [String:Any]
        if let language { guard body["language"] as? String == language else { throw POSIXError(.EINVAL) } }
        let pcm = try Data(contentsOf:Bundle.main.resourceURL!.appendingPathComponent("Whistle/jfk.wav")).dropFirst(44)
        guard let audio = original.audioFiles.first, try Data(contentsOf:audio).dropFirst(44) == pcm,
              found.transcriptItems.allSatisfy({ $0.speaker == "me" }) else { throw POSIXError(.EINVAL) }
        return found
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<4800 { if condition() { return }; try await Task.sleep(for:.milliseconds(25)) }
        throw POSIXError(.ETIMEDOUT)
    }
}
#endif
