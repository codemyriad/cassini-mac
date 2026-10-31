// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import CassiniLibrary
import CassiniRecording

/// Real app/controller/metadata/power/registration proof with RAM inputs only.
/// This complements XCTest; it does not claim to test Finder keystroke delivery.
@MainActor enum RecordingComfortSelfTest {
    private enum Failure: Error { case check(String) }
    private static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure.check(message) }
    }
    static func run() async {
        let environment = ProcessInfo.processInfo.environment
        let hosted = environment["GITHUB_ACTIONS"] == "true" && environment["RUNNER_ENVIRONMENT"] == "github-hosted"
        guard hosted || environment["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1",
              RecordingFixture.enabled, let root = RecordingFixture.root,
              LibraryLaunchContext.argument("-CassiniSilentMicrophone") == "YES" else { exit(78) }
        let recorder = RecordingController.shared, runtime = RecordingRuntime.shared
        do {
            runtime.start()
            try require(runtime.shortcut.registered,"global shortcut registration")
            await recorder.start(parent:root)
            try await Task.sleep(for:.milliseconds(500))
            try require(recorder.isRecording && runtime.power.held,"recording and real power assertion")
            let folder = try recorder.directory.unwrap("capture directory")
            let id = try UUID(uuidString:String(folder.lastPathComponent.dropFirst("Recording-".count))).unwrap("capture identity")
            let scanner = LibraryScanner(root:root,activity:CaptureActivitySnapshot([id:.recording]))
            let meeting = try scanner.scan().meetings.first.unwrap("live Library meeting")
            let model = RecordingPageModel.editor(for:meeting)
            model.title = "Temporary title"; model.changeTitle(); await RecordingPageModel.flushAll()
            model.title = ""; model.changeTitle(); await RecordingPageModel.flushAll()
            let cleared = try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("meeting.json"))) as! [String:Any]
            try require(cleared["title"] is NSNull && cleared["titleSource"] as? String == "meeting-window","clearing the title removes the user override")
            model.title = "Comfort probe title"; model.changeTitle()
            // A prior version's notes are data, not an editable live draft.
            let existingNotes: [[String:Any]] = [["atMs":12,"text":"Keep this note\nexactly"],["atMs":3,"text":" Earlier note "]]
            try MeetingMetadataWriter(directory:folder,id:id).transaction { $0["notes"] = existingNotes }
            await RecordingPageModel.flushAll()
            let updated = try scanner.scan().meetings.first.unwrap("updated Library meeting")
            let afterTitle = try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("meeting.json"))) as! [String:Any]
            try require(try JSONSerialization.data(withJSONObject:afterTitle["notes"]!,options:.sortedKeys) == JSONSerialization.data(withJSONObject:existingNotes,options:.sortedKeys),"title edit preserves existing notes exactly")
            try require(updated.title == model.title && recorder.title == model.title,"title persisted and published")
            try require(RecordingPageModel.editor(for:updated) === model,"Back/Open retains editor")
            for window in NSApp.windows { window.orderOut(nil) }
            // Real elapsed time and real sink peaks, without a clock shortcut.
            try await Task.sleep(for:.seconds(20))
            try require(recorder.microphoneSilent && recorder.elapsedMs >= 20000,"20-second silent-microphone rule (phase=\(recorder.phase), elapsed=\(recorder.elapsedMs), levels=\(recorder.levels))")
            // A moved/imported duplicate can share the basename while referring
            // to another folder. It must not control this native capture.
            let activeFolder = try recorder.directory.unwrap("active native folder")
            let duplicateRoot = root.deletingLastPathComponent().appendingPathComponent("same-name-other-root")
            try FileManager.default.createDirectory(at:duplicateRoot,withIntermediateDirectories:false)
            let duplicateFolder = duplicateRoot.appendingPathComponent(activeFolder.lastPathComponent)
            try FileManager.default.createDirectory(at:duplicateFolder,withIntermediateDirectories:false)
            // Copy a published manifest and only its persistent tracks. A live
            // writer can rename/remove .session-*.tmp between enumeration and
            // a recursive copy; those staging files are not fixture input.
            let metadata = try Data(contentsOf:activeFolder.appendingPathComponent("session.json"))
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(RecordingManifest.self,from:metadata)
            try metadata.write(to:duplicateFolder.appendingPathComponent("session.json"))
            for track in snapshot.tracks {
                try FileManager.default.copyItem(at:activeFolder.appendingPathComponent(track.file),to:duplicateFolder.appendingPathComponent(track.file))
            }
            let duplicate = try LibraryScanner(root:duplicateRoot).scan().meetings.first.unwrap("same-name duplicate")
            let otherEditor = RecordingPageModel.editor(for:duplicate)
            try require(duplicate.libraryKey == model.meeting.libraryKey && model.native && !otherEditor.native,"native capture identity includes its folder, not only its basename")
            let payload = RecordingMenuPayload(recorder:recorder,runtime:runtime)
            try require(payload.assertionHeld && payload.levels[0].silent && payload.levels[1].value > 0,"hidden menu runtime state (power=\(payload.assertionHeld), levels=\(payload.levels), recorder=\(recorder.levels))")
            try require(payload.actions.map(\.id) == ["stop","open","settings","quit"] && payload.actions.first?.shortcut == "⌥⌘R","menu actions")
            let total: UInt64 = 100 << 30, reserve = total / 50
            FileHandle.standardError.write(Data("Private disk probe: checking native warning presentation\n".utf8))
            recorder.applyDiskBudgetForTesting(DiskBudget(total:total,free:reserve + 300_000_000,bytesPerSecond:1_000_000))
            try require(RecordingDiskWatch.warningTitle == UXText.text("errors.diskLow.line",["n":"5"]),"low-disk warning appears")
            recorder.applyDiskBudgetForTesting(DiskBudget(total:total,free:reserve + 240_000_000,bytesPerSecond:1_000_000))
            try require(RecordingDiskWatch.warningTitle == UXText.text("errors.diskLow.line",["n":"4"]),"low-disk warning updates")
            recorder.applyDiskBudgetForTesting(DiskBudget(total:total,free:20 << 30,bytesPerSecond:1_000_000))
            try require(RecordingDiskWatch.warningTitle == nil,"recovered disk space clears the warning")
            recorder.applyDiskBudgetForTesting(DiskBudget(total:total,free:reserve,bytesPerSecond:1_000_000))
            try require(RecordingDiskWatch.warningTitle == nil && recorder.diskStopped,"reserve stops without recreating a status item")
            FileHandle.standardError.write(Data("Private disk probe: warning lifecycle completed\n".utf8))
            try require(recorder.isSaving,"Saving visible while finalizing")
            await recorder.finishTask?.value
            try await Task.sleep(for:.milliseconds(100))
            try require(!runtime.power.held && recorder.canStart,"power released after Stop")
            try require(RecordingDiskWatch.warningTitle == nil,"no late disk sample recreates the warning")
            let saved = try LibraryScanner(root:root).scan().meetings.first.unwrap("saved meeting")
            try require(saved.state.lifecycle == .saved && saved.canPlaySession && saved.title == model.title && saved.notes == updated.notes,"saved title, notes and playable audio")
            runtime.stop()
            // Independent synthetic browser source: no browser, device or live
            // desktop is involved. A quiet source must still advance its clock.
            let browser = try RecordingSession(parent:root,title:"Private browser",source:"chromium")
            try browser.addTrack(id:"a",label:"A",kind:"remote",sampleRate:16000,channels:1)
            try browser.appendNative(id:"a",pcm:Data(repeating:0,count:3200),offsetMs:0)
            let browserScanner = LibraryScanner(root:root,activity:CaptureActivitySnapshot([browser.manifest.id:.recording]))
            let browserMeeting = try browserScanner.scan().meetings.first(where:{ $0.id == browser.manifest.id }).unwrap("private browser meeting")
            let editor = RecordingPageModel.editor(for:browserMeeting), elapsed = editor.elapsedMs
            try await Task.sleep(for:.milliseconds(1100))
            try require(!editor.native && editor.elapsedMs >= elapsed + 1000 && editor.voiceCount == 1,"browser clock advances without a manifest write")
            try browser.addTrack(id:"b",label:"B",kind:"remote",sampleRate:16000,channels:1)
            try browser.appendNative(id:"b",pcm:Data(repeating:0,count:3200),offsetMs:0)
            let newer = try browserScanner.scan().meetings.first(where:{ $0.id == browser.manifest.id }).unwrap("changed browser source list")
            try require(RecordingPageModel.editor(for:newer) === editor,"browser updates keep unsaved editor state")
            editor.update(newer)
            for _ in 0..<80 { if editor.voiceCount == 2 { break }; try await Task.sleep(for:.milliseconds(25)) }
            try require(editor.voiceCount == 2,"browser source count updates")
            let saving = try LibraryScanner(root:root,activity:CaptureActivitySnapshot([browser.manifest.id:.saving]))
                .scan().meetings.first(where:{ $0.id == browser.manifest.id }).unwrap("saving browser meeting")
            editor.update(saving)
            let savingTime = editor.elapsedMs
            try await Task.sleep(for:.milliseconds(60))
            try require(savingTime == saving.durationMs && editor.elapsedMs == savingTime,"browser Saving uses the producer end instead of the hidden wall-clock interval")
            var noStart = saving; noStart.start = nil; noStart.state.liveMs = nil
            editor.update(noStart)
            try await Task.sleep(for:.milliseconds(60))
            try require(editor.elapsedMs == savingTime,"lifecycle-only Saving holds the producer end with no start timestamp")
            try browser.finish()
            try? FileManager.default.removeItem(at:root.deletingLastPathComponent())
            let menu = try JSONSerialization.jsonObject(with:JSONEncoder().encode(payload))
            let report: [String:Any] = ["recordingComfort":true,"sameNameCaptureIsolation":true,"shortcutRegistered":true,"existingNotesPreserved":true,"titleReset":true,"browserClockAndSources":true,"savingUsesProducerEnd":true,"diskWarningLifecycle":true,"silentMicAfter20Seconds":true,"assertionReleasedAfterStop":true,"menu":menu]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) + Data([10]))
            exit(0)
        } catch {
            await recorder.stopAndWait(); runtime.stop()
            try? FileManager.default.removeItem(at:root.deletingLastPathComponent())
            FileHandle.standardError.write(Data("Recording comfort probe failed: \(error)\n".utf8)); exit(1)
        }
    }
}
@MainActor enum RecordingSavingSelfTest {
    static func run() async {
        let env = ProcessInfo.processInfo.environment
        guard env["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1" || env["GITHUB_ACTIONS"] == "true" && env["RUNNER_ENVIRONMENT"] == "github-hosted" else { exit(78) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniSavingProbe-" + UUID().uuidString)
        do {
            let session = try RecordingSession(parent:root,title:"Private browser",source:"chromium")
            defer { try? FileManager.default.removeItem(at:root) }
            try session.addTrack(id:"a",label:"A",kind:"remote",sampleRate:16000,channels:1)
            try session.appendNative(id:"a",pcm:Data(repeating:0,count:3200),offsetMs:0)
            let recording = try LibraryScanner(root:root,activity:CaptureActivitySnapshot([session.manifest.id:.recording]))
                .scan().meetings.first.unwrap("recording fixture")
            let editor = RecordingPageModel.editor(for:recording), initial = editor.elapsedMs
            try await Task.sleep(for:.milliseconds(1100))
            guard editor.elapsedMs >= initial + 1000 else { throw POSIXError(.EINVAL) }
            // The cached editor is reopened after the source stopped. Its known
            // physical end is only 100 ms; the hidden wall clock must not win.
            let saving = try LibraryScanner(root:root,activity:CaptureActivitySnapshot([session.manifest.id:.saving]))
                .scan().meetings.first.unwrap("saving fixture")
            editor.update(saving)
            guard editor.elapsedMs == 100 else { throw POSIXError(.EINVAL) }
            try await Task.sleep(for:.milliseconds(100))
            guard editor.elapsedMs == 100 else { throw POSIXError(.EINVAL) }
            var noStart = saving; noStart.start = nil; noStart.state.liveMs = nil
            editor.update(noStart)
            editor.title = "Title while saving"; editor.changeTitle()
            await RecordingPageModel.flushAll()
            guard editor.elapsedMs == 100 else { throw POSIXError(.EINVAL) }
            try session.finish()
            let visible = NSApp.windows.filter { $0.isVisible && !(String(describing:type(of:$0)) == "NSStatusBarWindow" && $0.level == .statusBar) }
            guard visible.isEmpty else { throw NSError(domain:"SavingProbeVisibleWindow",code:1,userInfo:[NSLocalizedDescriptionKey:visible.map { $0.title + " class=" + String(describing:type(of:$0)) + " level=" + String($0.level.rawValue) }.joined(separator:", ")]) }
            let report: [String:Any] = ["recordingClockAdvances":true,"savingUsesProducerEnd":true,"lifecycleOnlySavingHolds":true,"audioDevicesOpened":false,"documentWindowsOpened":false]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) + Data([10])); exit(0)
        } catch { FileHandle.standardError.write(Data("Saving clock probe failed: \(error)\n".utf8)); exit(1) }
    }
}
private extension Optional {
    func unwrap(_ description: String) throws -> Wrapped {
        guard let value = self else { throw NSError(domain:"CassiniRecordingComfort",code:1,userInfo:[NSLocalizedDescriptionKey:description]) }
        return value
    }
}
#endif
