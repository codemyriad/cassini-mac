// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import CassiniRecording

/// Hosted-only product proof. Chromium owns the real discovery, page lifecycle,
/// native channels and remote PCM; native sides use the guarded RAM fixture.
@MainActor enum BrowserReturnSelfTest {
    private static func report(_ value: [String:Any]) throws {
        try FileHandle.standardOutput.write(contentsOf:JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) + Data([10]))
    }
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 35
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for:.milliseconds(25)) }
        if !condition() { throw NSError(domain:"BrowserReturnSelfTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    }
    static func run() async {
        guard CaptureFixture.enabled,
              ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted" else { exit(77) }
        let collection = CaptureCollection.shared
        do {
            try await wait("Real browser did not discover the call") { collection.connected && collection.hasCalls && CompanionSetup.shared.prepared }
            try await collection.record()
            try await wait("Real browser capture did not deliver PCM") {
                collection.captures.count == 1 && collection.captures.values.first?.modernLifecycle == true &&
                collection.captures.values.first?.owner.snapshot.manifest.tracks.contains { $0.kind == "remote" && $0.frames > 0 } == true
            }
            guard let capture = collection.first else { throw CocoaError(.fileReadUnknown) }
            let id = capture.snapshot.manifest.id, folder = capture.owner.snapshot.directory
            let before = Set(capture.owner.snapshot.manifest.tracks.filter { $0.kind == "remote" }.map(\.id))
            try report(["phase":"recording","id":id.uuidString])
            try await wait("Navigation did not start computer-sound fallback") { capture.owner.snapshot.usingSystem }
            try report(["phase":"fallback","id":id.uuidString])
            try await wait("Same Chromium transport did not restore after navigation") {
                let source = capture.owner.snapshot
                return source.browserAlive && source.transportAlive && !source.usingSystem &&
                    source.manifest.events?.contains { $0.type == "othersSource" && $0.source == "browser" && $0.reason == "restored" } == true &&
                    source.manifest.tracks.contains { $0.kind == "remote" && !before.contains($0.id) && $0.frames > 0 }
            }
            guard collection.captures[id]?.captureID == capture.captureID,
                  capture.owner.snapshot.directory == folder,
                  CaptureFixture.microphoneStarts == 1, CaptureFixture.systemStarts == 1 else { throw CocoaError(.fileReadCorruptFile) }
            try report(["phase":"restored","id":id.uuidString])
            try await wait("Closed Chromium tab did not stop") { collection.captures.isEmpty }
            let manifest = try await Task.detached { try RecordingLoader.load(directory:folder) }.value
            guard manifest.id == id, manifest.events?.last?.type == "end", manifest.events?.last?.reason == "tabClosed",
                  manifest.tracks.filter({ $0.kind == "microphone" && $0.frames > 0 }).count == 1,
                  manifest.tracks.filter({ $0.kind == "system" && $0.frames > 0 }).count == 1,
                  manifest.tracks.filter({ $0.kind == "remote" && $0.frames > 0 }).count >= 2 else { throw CocoaError(.fileReadCorruptFile) }
            try report(["phase":"complete","sameFolder":true,"originalTransport":true,"realPageLifecycle":true,
                        "systemFallback":true,"freshBrowserSpan":true,"microphoneUninterrupted":true,"endReason":"tabClosed",
                        "nativeInputsGenerated":true,"audioDevicesOpened":false])
            CompanionSetup.shared.stop(); await collection.shutdown()
            if let root = RecordingFixture.root { try? FileManager.default.removeItem(at:root.deletingLastPathComponent()) }
            exit(0)
        } catch {
            try? FileHandle.standardError.write(contentsOf:Data(("Browser return proof failed: \(error)\n").utf8))
            CompanionSetup.shared.stop(); await collection.shutdown(); exit(1)
        }
    }
}
#endif
