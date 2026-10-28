// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import Carbon
import CassiniLibrary
import CassiniRecording
import Darwin

/// Real app proof over private generated files/RAM inputs. No picker, desktop
/// automation, user Library or real capture device is involved.
@MainActor enum SettingsSelfTest {
    private enum Failure: Error { case check(String) }
    private static func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.check(message) } }
    static func run() async {
        let env = ProcessInfo.processInfo.environment
        let hosted = env["GITHUB_ACTIONS"] == "true" && env["RUNNER_ENVIRONMENT"] == "github-hosted"
        guard hosted || env["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1", let id = SettingsFixture.id,
              RecordingFixture.enabled, RecordingFixture.transcribes,
              LibraryLaunchContext.argument("-CassiniSlowTranscription") == "YES", let original = RecordingFixture.root else { exit(78) }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniSettingsDestination-" + id.uuidString)
        let config = LibraryLaunchContext.locationFile
        let recorder = RecordingController.shared, runtime = RecordingRuntime.shared, queue = TranscriptionQueue.shared
        var output: Data?, failure: Error?
        var blockedFolder: URL?
        do {
            try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:false)
            let earlier = try RecordingSession(parent:original,title:"Written meeting",source:"macos")
            try earlier.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
            try earlier.appendNative(id:"mic",pcm:Data(repeating:0,count:3200),offsetMs:0); try earlier.finish()
            let writer = try MeetingMetadataWriter(directory:earlier.directory,id:earlier.manifest.id)
            try Data("{\"language\":\"en\",\"items\":[{\"speaker\":\"mic\",\"startMs\":0,\"endMs\":50,\"text\":\"Settings relocation phrase\"}]}".utf8).write(to:earlier.directory.appendingPathComponent("transcript.json"))
            try writer.transaction {
                $0["transcript"] = ["status":"done","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]]
                $0["speakers"] = [["id":"mic","name":"Me","provenance":"source","colourIndex":0]]
            }
            let queued = try RecordingSession(parent:original,title:"Queued meeting",source:"macos")
            try queued.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
            try queued.appendNative(id:"mic",pcm:Data(repeating:0,count:3200),offsetMs:0); try queued.finish()
            try MeetingMetadataWriter(directory:queued.directory,id:queued.manifest.id).createIfNeeded()
            let receivedSource = Bundle.main.resourceURL!.appendingPathComponent("Fixtures/Library/main/root/Received-a0000000-0000-4000-8000-000000000006/original.opus")
            let received = try LibraryImport.copy(receivedSource,into:original)
            blockedFolder = received.folder
            let receivedBytes = try Data(contentsOf:received.folder.appendingPathComponent("original.opus"))
            LibraryStore.shared.reloadLocation()
            try await wait { LibraryStore.shared.loaded && queue.active != nil }
            let flags = UInt32(controlKey | optionKey | shiftKey | cmdKey)
            let privateKey = RecordingHotKey(code:UInt32(kVK_F18),flags:flags,character:"\u{F715}",name:"F18")
            try check(runtime.shortcut.change(to:privateKey) == noErr,"private real hotkey registration")
            try check(RecordingHotKey.saved == privateKey,"shortcut saved")
            let rival = RecordingShortcut()
            let other = RecordingHotKey(code:UInt32(kVK_F19),flags:flags,character:"\u{F716}",name:"F19")
            try check(rival.change(to:other) == noErr,"conflict fixture registration")
            let before = RecordingPreferences.defaults.data(forKey:"CassiniRecordingHotKey")
            try check(runtime.shortcut.change(to:other) != noErr && runtime.shortcut.choice == privateKey && runtime.shortcut.registered,"conflict preserves the old binding")
            try check(RecordingPreferences.defaults.data(forKey:"CassiniRecordingHotKey") == before,"conflict does not overwrite preferences")
            rival.stop()
            let third = RecordingHotKey(code:UInt32(kVK_F20),flags:flags,character:"\u{F717}",name:"F20")
            try check(runtime.shortcut.change(to:third) == noErr && runtime.shortcut.change(to:privateKey) == noErr,"replacement releases old keys")
            RecordingPreferences.defaults.set(true,forKey:"CassiniSkipRecordFirst")
            try check(RecordingPreferences.skipFirst,"shared inverse first-record preference")
            RecordingPreferences.defaults.set(false,forKey:"CassiniSkipRecordFirst")
            runtime.start()
            let search = LibrarySearchModel.shared
            search.query = "relocation"; search.open()
            try await wait { !search.searching && search.hits.count == 1 }; search.close()
            let activeBeforeMove = try require(queue.active)
            let source = LibraryLocationModel.shared.roots[0]
            // The browser may connect before a Move and send start afterwards.
            // Exercise the production host's late-bound routing rule.
            let host = BrowserRecordingHost(makeSession: { title in
                try LibraryRouting.withLock(file:config,exclusive:false) {
                    try RecordingSession(parent:LibraryRouting.recordingDestination(file:config),title:title,source:"chromium")
                }
            })
            await recorder.start(parent:source)
            try await wait { recorder.isRecording && !recorder.waitingForAudio }
            let live = try require(recorder.directory)
            let sessionBytes = try Data(contentsOf:earlier.directory.appendingPathComponent("session.json"))
            try check(chmod(received.folder.path,0) == 0,"private move-failure fixture")
            try await LibraryMoveCoordinator.shared.moveForTesting(to:destination,allowingFailures:true)
            try check(FileManager.default.fileExists(atPath:received.folder.path),"failed original retained")
            // Revoking read permission may let a watcher replace the title
            // with its unknown-title fallback before Move starts. Anchor the
            // failure to the actual folder, not that transient readable title.
            try check(LibraryLocationModel.shared.location.pendingMoves.contains { $0.id == LibraryLocation.canonical(received.folder).path && $0.phase == .failed },"failure line identifies the original folder")
            try check(chmod(received.folder.path,0o700) == 0,"restore fixture permissions")
            try check(try Data(contentsOf:received.folder.appendingPathComponent("original.opus")) == receivedBytes,"failed meeting audio remains unchanged")
            LibraryMoveCoordinator.shared.retry()
            try await wait { !LibraryMoveCoordinator.shared.busy }
            try check(LibraryMoveCoordinator.shared.failures.isEmpty,"failed meeting can be retried")
            let target = LibraryLocationModel.shared.roots[0]
            try check(recorder.isRecording && FileManager.default.fileExists(atPath:live.path),"live capture remains in its old folder")
            try check(LibraryLocationModel.shared.location.previousPaths.contains(source.path),"old reader retained")
            try check(try Data(contentsOf:target.appendingPathComponent(earlier.directory.lastPathComponent + "/session.json")) == sessionBytes,"producer bytes preserved")
            try check(queue.active == activeBeforeMove && FileManager.default.fileExists(atPath:activeBeforeMove.path),"in-flight inference keeps its original path and is not cancelled")
            try check(LibraryLocationModel.shared.location.pendingMoves.filter { $0.phase == .pending }.count == 2,"capture and inference remain pending while busy")
            search.query = "relocation"; search.open()
            try await wait { !search.searching && search.hits.count == 1 }
            try check(search.selected.flatMap { search.meeting($0) }?.folder.deletingLastPathComponent().path == target.path,"search reindexed to destination")
            search.close()
            func send(_ fields: [String:Any]) throws -> [String:String] { try host.receive(JSONSerialization.data(withJSONObject:fields)) }
            let started = try send(["type":"start","version":1,"title":"Synthetic browser"])
            let browserPath = try require(started["path"])
            try check(URL(fileURLWithPath:browserPath).deletingLastPathComponent().path == target.path,"browser host uses the same pointer")
            _ = try send(["type":"track","id":"remote","kind":"remote","sampleRate":48000,"channels":1])
            _ = try send(["type":"audio","id":"remote","sequence":0,"offsetMs":0,"pcm":Data([0,0,64,1]).base64EncodedString()])
            _ = try send(["type":"stop"])
            // Simulate Quit: stop the move scheduler first, then let the jobs
            // finalize at their unchanged paths. A separate app launch resumes.
            LibraryMoveCoordinator.shared.beginShutdown(); await LibraryMoveCoordinator.shared.waitForShutdown()
            queue.beginShutdown(); await queue.waitForShutdown(); await recorder.stopAndWait()
            let persisted = try LibraryLocation.read(file:config)
            try check(persisted.pendingMoves.count == 2 && !persisted.previousPaths.isEmpty,"pending move intent survives Quit")
            let report: [String:Any] = ["settingsPreferences":true,"realShortcutReplacement":true,"shortcutConflictRetainsOld":true,
                                      "closedMeetingMovedAtomically":true,"partialFailureRetainsOriginal":true,"liveFolderDeferred":true,"pendingMovesPersisted":true,
                                      "activeInferencePathPreserved":true,"searchReindexed":true,"hostReadsLocation":true,"producerBytesPreserved":true,"audioDevicesOpened":false]
            output = try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys])
        } catch { failure = error }
        LibraryMoveCoordinator.shared.beginShutdown(); await LibraryMoveCoordinator.shared.waitForShutdown()
        await recorder.stopAndWait(); queue.beginShutdown(); await queue.waitForShutdown()
        runtime.stop(); LibraryStore.shared.stop()
        SettingsFixture.defaults?.removePersistentDomain(forName:"com.codemyriad.cassini-mac.settings-fixture." + id.uuidString)
        if let blockedFolder { _ = chmod(blockedFolder.path,0o700) }
        if failure != nil { for url in [original,destination,config.deletingLastPathComponent()] { try? FileManager.default.removeItem(at:url) } }
        if let failure { FileHandle.standardError.write(Data("Settings proof failed: \(failure)\n".utf8)); exit(1) }
        if let output { FileHandle.standardOutput.write(output + Data([10])); exit(0) }; exit(1)
    }
    static func resume() async {
        guard SettingsFixture.id != nil, RecordingFixture.enabled, !RecordingFixture.transcribes,
              let original = RecordingFixture.root, let id = SettingsFixture.id else { exit(78) }
        let config = LibraryLaunchContext.locationFile
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniSettingsDestination-" + id.uuidString)
        do {
            let location = try LibraryLocation.read(file:config)
            let names = location.pendingMoves.map(\.folderName)
            try check(names.count == 2,"saved pending work is present on a fresh process")
            LibraryStore.shared.reloadLocation(); LibraryMoveCoordinator.shared.start()
            try await wait { !LibraryMoveCoordinator.shared.busy && LibraryLocationModel.shared.location.pendingMoves.isEmpty }
            for name in names { try check(FileManager.default.fileExists(atPath:destination.appendingPathComponent(name + "/session.json").path),"idle folder moved after relaunch") }
            try check(LibraryLocationModel.shared.location.previousPaths.isEmpty,"old readers retired after all moves finish")
            LibraryMoveCoordinator.shared.beginShutdown(); LibraryStore.shared.stop()
            for url in [original,destination,config.deletingLastPathComponent()] { try FileManager.default.removeItem(at:url) }
            let report = ["liveFolderMovedAfterStop":true,"pendingMovesResumedAfterRelaunch":true,"audioDevicesOpened":false]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) + Data([10])); exit(0)
        } catch { FileHandle.standardError.write(Data("Move resume proof failed: \(error)\n".utf8)); exit(1) }
    }
    private static func require<T>(_ value: T?) throws -> T { guard let value else { throw Failure.check("missing value") }; return value }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<600 { if condition() { return }; try await Task.sleep(for:.milliseconds(25)) }
        throw Failure.check("state timed out")
    }
}
#endif
