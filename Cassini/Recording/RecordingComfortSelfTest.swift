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
            model.notesText = "First note"; model.changeNotes()
            await RecordingPageModel.flushAll()
            let firstMeeting = try scanner.scan().meetings.first.unwrap("meeting with a saved note")
            let first = try firstMeeting.notes.first.unwrap("saved first note")
            try await Task.sleep(for:.milliseconds(300))
            model.notesText = "First note edited\nSecond note"; model.changeNotes()
            await RecordingPageModel.flushAll()
            let updated = try scanner.scan().meetings.first.unwrap("updated Library meeting")
            try require(updated.notes.count == 2 && updated.notes[0].atMs == first.atMs && updated.notes[1].atMs > updated.notes[0].atMs,"note times retained")
            try require(updated.title == model.title && recorder.title == model.title,"title persisted and published")
            try require(RecordingPageModel.editor(for:updated) === model,"Back/Open retains editor")
            for window in NSApp.windows { window.orderOut(nil) }
            // Real elapsed time and real sink peaks, without a clock shortcut.
            try await Task.sleep(for:.seconds(20))
            try require(recorder.microphoneSilent && recorder.elapsedMs >= 20000,"20-second silent-microphone rule (phase=\(recorder.phase), elapsed=\(recorder.elapsedMs), levels=\(recorder.levels))")
            let payload = RecordingMenuPayload(recorder:recorder,runtime:runtime)
            try require(payload.assertionHeld && payload.levels[0].silent && payload.levels[1].value > 0,"hidden menu runtime state")
            try require(payload.actions.map(\.id) == ["stop","note","open"] && payload.actions.first?.shortcut == "⌥⌘R","menu actions")
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
            editor.notesText = "Browser note"; editor.changeNotes(); await RecordingPageModel.flushAll()
            let noted = try browserScanner.scan().meetings.first(where:{ $0.id == browser.manifest.id }).unwrap("browser note")
            try require((noted.notes.first?.atMs ?? 0) >= elapsed + 1000,"browser notes use advancing time")
            let saving = try LibraryScanner(root:root,activity:CaptureActivitySnapshot([browser.manifest.id:.saving]))
                .scan().meetings.first(where:{ $0.id == browser.manifest.id }).unwrap("saving browser meeting")
            editor.update(saving)
            let savingTime = editor.elapsedMs
            try await Task.sleep(for:.milliseconds(60))
            try require(savingTime >= elapsed + 1000 && editor.elapsedMs == savingTime,"browser Saving holds the last recording time")
            try browser.finish()
            try? FileManager.default.removeItem(at:root.deletingLastPathComponent())
            let menu = try JSONSerialization.jsonObject(with:JSONEncoder().encode(payload))
            let report: [String:Any] = ["recordingComfort":true,"shortcutRegistered":true,"noteTimesPreserved":true,"titleReset":true,"browserClockAndSources":true,"diskWarningLifecycle":true,"silentMicAfter20Seconds":true,"assertionReleasedAfterStop":true,"menu":menu]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) + Data([10]))
            exit(0)
        } catch {
            await recorder.stopAndWait(); runtime.stop()
            try? FileManager.default.removeItem(at:root.deletingLastPathComponent())
            FileHandle.standardError.write(Data("Recording comfort probe failed: \(error)\n".utf8)); exit(1)
        }
    }
}
private extension Optional {
    func unwrap(_ description: String) throws -> Wrapped {
        guard let value = self else { throw NSError(domain:"CassiniRecordingComfort",code:1,userInfo:[NSLocalizedDescriptionKey:description]) }
        return value
    }
}
#endif
