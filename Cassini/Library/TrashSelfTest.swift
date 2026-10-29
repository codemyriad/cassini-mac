// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import CassiniLibrary
import CassiniRecording
import CryptoKit
import Darwin

/// Runs only in the signed app on disposable hosted runners. Generated audio
/// files are never played and no capture APIs, personal files or devices open.
@MainActor enum TrashSelfTest {
    private enum Failure: Error { case check(String) }
    private static func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.check(message) } }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for:.milliseconds(25)) }
        throw Failure.check("timeout")
    }
    private static func generate(_ root: URL, title: String) throws -> LibraryMeeting {
        let session = try RecordingSession(parent:root,title:title,source:"macos")
        try session.addTrack(id:"mic",label:"Me",kind:"microphone",sampleRate:16000,channels:1)
        try session.appendNative(id:"mic",pcm:Data(repeating:0,count:3200),offsetMs:0); try session.finish()
        try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id).createIfNeeded()
        guard let value = try LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == session.manifest.id }) else { throw Failure.check("generated meeting") }
        return value
    }
    static func run() async {
        let env = ProcessInfo.processInfo.environment
        guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted",
              RecordingFixture.enabled, let id = SettingsFixture.id,
              let file = LibraryLaunchContext.argument("-CassiniTrashRelocationFile") else { exit(78) }
        let primary = LibraryLocation.userHome.appendingPathComponent("Music/CassiniTrashFixture-" + id.uuidString)
        let queue = TranscriptionQueue.shared, trash = MeetingTrashCoordinator.shared, store = LibraryStore.shared
        var report: [String:Any] = ["audioDevicesOpened":false], phase = "setup"
        do {
            if let reportPath = LibraryLaunchContext.argument("-CassiniTrashPutBackFile") {
                let saved = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:reportPath))) as! [String:Any]
                let relocation = try LibraryLocation.read(file:URL(fileURLWithPath:file))
                for item in saved["sandboxCases"] as! [[String:Any]] {
                    let folder = URL(fileURLWithPath:item["original"] as! String)
                    let location = item["kind"] as? String == "music" ? LibraryLocation(primary:primary) : relocation
                    try location.write(file:LibraryLaunchContext.locationFile); store.reloadLocation()
                    try await wait { store.loaded && store.meetings.contains { $0.folder == folder } }
                    let meeting = store.meetings.first { $0.folder == folder }!
                    let bytes = try Data(contentsOf:folder.appendingPathComponent("session.json"))
                    try check(SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined() == item["sessionSHA256"] as? String,"Put Back byte preservation")
                    try check(meeting.canPlaySession,"Put Back playable again")
                }
                FileHandle.standardOutput.write(Data("{\"finderPutBackRescan\":true,\"audioDevicesOpened\":false}\n".utf8)); exit(0)
            }
            guard RecordingFixture.transcribes else { exit(78) }
            try FileManager.default.createDirectory(at:primary,withIntermediateDirectories:false)
            try LibraryLocation(primary:primary).write(file:LibraryLaunchContext.locationFile)
            store.reloadLocation()
            try await wait { store.loaded }
            let active = try generate(primary,title:"Active transcription")
            store.refresh(); try await wait { queue.active == active.folder }
            let waiting = try generate(primary,title:"Queued transcription")
            queue.enqueue(waiting)
            try await wait { (try? LibraryScanner(root:primary).scan().meetings.first { $0.id == waiting.id }?.state.transcript) == .queued }
            phase = "queued trash with unrelated metadata blocked"
            let blocked = try generate(primary,title:"Unrelated metadata preparation")
            let held = open(blocked.folder.path,O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard held >= 0, flock(held,LOCK_EX | LOCK_NB) == 0 else { throw Failure.check("metadata lock") }
            defer { flock(held,LOCK_UN); close(held) }
            queue.enqueue(blocked)
            try await wait { queue.preparingFixtureFolder == blocked.folder }
            var released = false
            let fallbackRelease = Task {
                try? await Task.sleep(for:.seconds(2))
                if !Task.isCancelled { flock(held,LOCK_UN); released = true }
            }
            let stillActive = queue.active
            trash.move(waiting,undoManager:nil); await trash.waitForShutdown()
            try check(trash.failure == nil && !FileManager.default.fileExists(atPath:waiting.folder.path),"queued meeting trashed")
            try check(queue.active == stillActive,"unrelated transcription still runs")
            let returnedWithoutOtherMetadata = !released
            fallbackRelease.cancel(); flock(held,LOCK_UN)
            try check(returnedWithoutOtherMetadata,"Trash does not wait for another meeting’s metadata lock")
            report["unrelatedMetadataDoesNotDelayTrash"] = true
            report["queuedCancelIsPerMeeting"] = true
            phase = "active trash"
            let editor = RecordingPageModel.editor(for:active)
            editor.title = "Pending hidden title"; editor.changeTitle()
            editor.notesText = "Pending hidden note"; editor.changeNotes()
            MeetingNavigation.shared.open(active)
            MeetingExportCoordinator.shared.show(active)
            trash.move(active,undoManager:nil); await trash.waitForShutdown()
            try check(trash.failure == nil && queue.active != active.folder,"active child ended before trash")
            try check(MeetingNavigation.shared.detail == nil && !MeetingExportCoordinator.shared.showing && MeetingExportCoordinator.shared.meeting == nil,"meeting and export closed")
            await RecordingPageModel.flushAll()
            try check(!FileManager.default.fileExists(atPath:active.folder.path),"hidden edits cannot recreate meeting")
            report["activeCancelWaitsForChild"] = true; report["hiddenEditsDiscarded"] = true; report["meetingAndExportClosed"] = true
            try await wait { queue.active == blocked.folder }
            trash.move(blocked,undoManager:nil); await trash.waitForShutdown()
            try check(trash.failure == nil && queue.active == nil,"another queued job continued and can stop independently")
            phase = "failure"
            let retry = try generate(primary,title:"Trash retry")
            trash.fixtureFailure = CocoaError(.featureUnsupported)
            trash.move(retry,undoManager:nil); await trash.waitForShutdown()
            try check(trash.failure?.id == retry.id && trash.unsupported && store.selectedKey == retry.libraryKey,"unsupported selected error")
            try check(FileManager.default.fileExists(atPath:retry.folder.path),"unsupported preserves source")
            trash.fixtureFailure = nil
            trash.move(retry,undoManager:nil); await trash.waitForShutdown()
            try check(trash.failure == nil && !FileManager.default.fileExists(atPath:retry.folder.path),"retry succeeds")
            report["failurePreservesSourceAndRetry"] = true
            phase = "relocation bookmark"
            let handoff = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:file))) as! [String:Any]
            guard let bytes = (handoff["handoff"] as? String).flatMap({ Data(base64Encoded:$0) }) else { throw Failure.check("implicit bookmark") }
            var stale = false
            let received = try URL(resolvingBookmarkData:bytes,options:[],relativeTo:nil,bookmarkDataIsStale:&stale)
            defer { received.stopAccessingSecurityScopedResource() }
            let persistent = try received.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
            let relocation = LibraryLocation(primary:received,bookmarks:[received.path:persistent])
            try relocation.write(file:URL(fileURLWithPath:file))
            let access = try LibraryAccess(relocation)
            try relocation.write(file:LibraryLaunchContext.locationFile)
            store.reloadLocation(); try await wait { store.loaded && !store.offline }
            phase = "sandbox trash and undo"
            var outcomes: [[String:Any]] = []
            for root in [primary,access.roots[0]] {
                // Reconfigure the primary for each test: one Music entitlement,
                // one actual externally-created security-scoped bookmark.
                let location = root == primary ? LibraryLocation(primary:primary) : relocation
                try location.write(file:LibraryLaunchContext.locationFile); store.reloadLocation()
                try await wait { store.loaded && !store.offline }
                let meeting = try generate(root,title:"Sandbox Trash")
                let before = try Data(contentsOf:meeting.folder.appendingPathComponent("session.json"))
                queue.enqueue(meeting)
                try await wait { queue.active == meeting.folder }
                let undo = UndoManager(); undo.groupsByEvent = false; undo.beginUndoGrouping()
                trash.move(meeting,undoManager:undo); await trash.waitForShutdown(); undo.endUndoGrouping()
                try check(trash.failure == nil && !FileManager.default.fileExists(atPath:meeting.folder.path),"real sandbox trash")
                let offered = undo.canUndo
                try check(offered == trash.lastUndoAvailable,"undo capability matches actual access")
                if offered {
                    undo.undo(); await trash.waitForShutdown()
                    try check(try Data(contentsOf:meeting.folder.appendingPathComponent("session.json")) == before,"undo restores unchanged producer")
                    store.refresh(); try await wait { store.meetings.contains { $0.id == meeting.id } }
                    trash.move(meeting,undoManager:nil); await trash.waitForShutdown()
                }
                outcomes.append(["kind":root == primary ? "music" : "bookmark","undoAvailable":offered,"original":meeting.folder.path,
                                 "trashed":trash.lastTrashURL?.path ?? "","sessionSHA256":SHA256.hash(data:before).map { String(format:"%02x",$0) }.joined()])
                undo.removeAllActions()
            }
            phase = "pending move cleanup"
            let deferred = try generate(primary,title:"Deferred Library move")
            var moving = relocation
            moving.previousPaths = [primary.path]
            moving.pendingMoves = [LibraryPendingMove(source:primary,folderName:deferred.folder.lastPathComponent)]
            try moving.write(file:LibraryLaunchContext.locationFile); store.reloadLocation()
            try await wait { store.loaded }
            trash.move(deferred,undoManager:nil); await trash.waitForShutdown()
            try check(trash.failure == nil && !LibraryLocationModel.shared.location.pendingMoves.contains { $0.id == deferred.folder.path },"pending move discarded")
            try check(LibraryLocationModel.shared.roots.contains { LibraryLocation.canonical($0).path == LibraryLocation.canonical(primary).path },"Put Back previous root retained")
            report["pendingMoveDiscarded"] = true
            report["sandboxCases"] = outcomes; report["primaryAndBookmarkedTrash"] = true
            report["sandboxUndoVerifiedOrAbsent"] = true
            queue.beginShutdown(); await queue.waitForShutdown()
            report["ok"] = true
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) + Data([10])); exit(0)
        } catch {
            queue.beginShutdown(); await queue.waitForShutdown()
            NSLog("Trash fixture failed at %@: %@",phase,String(describing:error)); exit(1)
        }
    }
}
#endif
