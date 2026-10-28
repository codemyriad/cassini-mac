// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import CassiniKit
import CassiniLibrary
import CassiniRecording
import CassiniExport
import Darwin

/// Packaging proof using generated RAM audio and this app's private temporary
/// directory. No device, user Library or Documents access is involved.
@MainActor enum ExportSelfTest {
    static func run() async {
        let env = ProcessInfo.processInfo.environment
        guard env["CASSINI_HOSTED_EXPORT"] == "1",
              (env["GITHUB_ACTIONS"] == "true" && env["RUNNER_ENVIRONMENT"] == "github-hosted") || env["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1" else { exit(78) }
        do {
            let bundle = Bundle.main.bundleURL
            let report = try await Task.detached {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniExportProbe-" + UUID().uuidString)
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                defer { try? FileManager.default.removeItem(at:root) }
                let session = try RecordingSession(parent:root.appendingPathComponent("Library"),title:"Offline tone",source:"macos")
                try session.addTrack(id:"mic",label:"Microphone",kind:"microphone",sampleRate:16000,channels:1)
                var pcm = Data()
                for n in 0..<16000 {
                    var value = Int16(6000 * sin(Double(n) * 2 * .pi * 440 / 16000)).littleEndian
                    withUnsafeBytes(of:&value) { pcm.append(contentsOf:$0) }
                }
                try session.appendNative(id:"mic",pcm:pcm,offsetMs:0); try session.finish()
                let writer = try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id)
                try writer.transaction { $0["notes"] = [["atMs":200,"text":"Generated tone"]] }
                guard let meeting = try LibraryScanner(root:root.appendingPathComponent("Library")).scan().meetings.first else { throw MeetingExportError.invalidSource }
                let artifact = try MeetingFileExporter.cassini(meeting,assets:OpusAssets.bundled(app:bundle))
                let output = root.appendingPathComponent("Output")
                try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false)
                let saved = try ExportDestination.folder(artifact,directory:output,title:"Offline tone",extension:"opus")
                let imported = try LibraryImport.copy(saved,into:root.appendingPathComponent("Received"))
                guard imported.state.transcript == .none, imported.canWriteDown, imported.notes.first?.text == "Generated tone" else { throw MeetingExportError.invalidSource }
                let again = try MeetingFileExporter.cassini(imported,assets:nil)
                let first = try CassiniReader.read(contentsOf:saved), second = try CassiniReader.read(contentsOf:again.url)
                guard first.state == .ok, second.state == .ok, try first.audioDigest?.get() == second.audioDigest?.get(), first.manifest?.audio.sampleCount == 48000 else { throw MeetingExportError.invalidSource }
                return ["sealedBundledOpus":true,"sandboxExport":true,"emptyWordsReadyToWriteDown":true,"notesRoundTrip":true,"opusDigestPreserved":true]
            }.value
            let data = try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys])
            FileHandle.standardOutput.write(data + Data([10])); exit(0)
        } catch {
            FileHandle.standardError.write(Data("Export packaging self-test failed: \(error)\n".utf8)); exit(1)
        }
    }
}
#endif
