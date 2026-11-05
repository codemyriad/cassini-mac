// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import CassiniRecording

/// Shared test 2 (D68): the app side of the protocol live-folder driver's app adapter
/// (scripts/test-live-folder.mjs). Hosted only. Chromium owns the real call, extension and
/// native hosts (registered by the driver's launchers, so companion setup never runs and never
/// rewrites them); native sides use the guarded RAM fixture (a 440 Hz microphone tone).
///
/// One JSON command per stdin line, `{"id":n,"command":…}`, answered by one stdout line
/// `{"id":n,"ok":true,"value":…}` or `{"id":n,"ok":false,"error":…}`. The first stdout line is
/// `{"phase":"ready","libraryRoot":…}`. Commands: record, selectMe {on}, snapshot, meetingRow,
/// stop, saved, quit. Each returns once the app has acted; every wait is the driver's.
@MainActor enum LiveFolderSelfTest {
    static let argument = "--live-folder-self-test"
    /// The hosted control pipe root the driver passes to Chromium and the app.
    static var controlRoot: URL {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted",
              let path = ProcessInfo.processInfo.environment["CASSINI_CONTROL_PIPE_ROOT"], path.contains("/live-folder-") else { exit(77) }
        return URL(fileURLWithPath:path,isDirectory:true)
    }
    private static func emit(_ value: [String:Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) else { return }
        try? FileHandle.standardOutput.write(contentsOf:data + Data([10]))
    }
    private struct Failure: Error, CustomStringConvertible { let description: String }
    static func run() async {
        guard CaptureFixture.enabled,
              ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted",
              let root = RecordingFixture.root else { exit(77) }
        let collection = CaptureCollection.shared
        emit(["phase":"ready","libraryRoot":root.path,"pid":Int(getpid())])
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard let object = try? JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any],
                      let id = object["id"] as? Int, let command = object["command"] as? String else { continue }
                do {
                    let value = try await handle(command,object,collection)
                    emit(["id":id,"ok":true,"value":value])
                    if command == "quit" { await collection.shutdown(); exit(0) }
                } catch {
                    emit(["id":id,"ok":false,"error":String(describing:error)])
                }
            }
        } catch {}
        // The driver closed stdin without quit (it failed or was killed): end, leaving no process.
        await collection.shutdown(); exit(0)
    }
    private static func live(_ collection: CaptureCollection) throws -> LiveCapture {
        let recording = collection.captures.values.filter { $0.snapshot.phase == .recording && $0.savingSinceMs == nil }
        guard recording.count == 1, let capture = recording.first else { throw Failure(description:"\(recording.count) recordings, expected 1") }
        return capture
    }
    private static func handle(_ command: String, _ object: [String:Any], _ collection: CaptureCollection) async throws -> Any {
        switch command {
        case "record":
            // The person's Record, for the one call the browser shows.
            try await collection.record()
            return NSNull()
        case "selectMe":
            guard let on = object["on"] as? Bool else { throw Failure(description:"selectMe needs on") }
            let capture = try live(collection)
            let refused = try await collection.select(capture.snapshot.manifest.id,me:on,others:true)
            guard refused.isEmpty else { throw Failure(description:"refused \(refused.keys.map { "\($0)" }.sorted())") }
            return NSNull()
        case "snapshot":
            guard let capture = collection.captures.values.first(where: { $0.snapshot.phase == .recording }) else { return NSNull() }
            return ["path":capture.owner.snapshot.directory.path,"captureId":capture.captureID]
        case "meetingRow":
            let rows = collection.peers.flatMap(\.meetings).filter { $0.sourceCountKnown }
            guard let row = rows.first else { return NSNull() }
            guard rows.count == 1 else { throw Failure(description:"\(rows.count) call rows, expected 1") }
            return ["sourceCount":row.sourceCount,"heard":row.heard]
        case "stop":
            collection.stop(try live(collection).snapshot.manifest.id)
            return NSNull()
        case "saved":
            // App-owned files after Stop: the capture has finished saving, within 60 s.
            let deadline = ProcessInfo.processInfo.systemUptime + 60
            while !collection.captures.isEmpty {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(description:"still saving after 60 s") }
                try await Task.sleep(for:.milliseconds(50))
            }
            return NSNull()
        case "quit":
            return NSNull()
        default:
            throw Failure(description:"unknown command \(command)")
        }
    }
}
#endif
