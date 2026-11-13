// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import CassiniLibrary
import CassiniRecording
import CassiniSpectrogram
import Observation
import SwiftUI

/// Real app/controller/metadata/power/registration proof with RAM inputs only.
/// This complements XCTest; it does not claim to test Finder keystroke delivery.
@MainActor enum RecordingComfortSelfTest {
    private enum Failure: Error { case check(String) }
    private static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure.check(message) }
    }
    private static func waitForPower(_ runtime: RecordingRuntime, held expected: Bool) async throws {
        let values = AsyncStream<Bool> { continuation in
            let current = withObservationTracking { runtime.power.held } onChange: {
                Task { @MainActor in continuation.yield(runtime.power.held); continuation.finish() }
            }
            continuation.yield(current)
            if current == expected { continuation.finish() }
        }
        for await held in values where held == expected { return }
        throw Failure.check("expected power assertion state \(expected)")
    }
    private static func waitForVoiceCount(_ editor: RecordingPageModel, _ expected: Int) async throws {
        while editor.voiceCount != expected {
            let (changes, continuation) = AsyncStream<Void>.makeStream()
            let current = withObservationTracking { editor.voiceCount } onChange: {
                Task { @MainActor in continuation.yield(()); continuation.finish() }
            }
            if current == expected { continuation.finish(); return }
            for await _ in changes { break }
            try Task.checkCancellation()
        }
    }
    static func run() async {
        let environment = ProcessInfo.processInfo.environment
        let hosted = environment["GITHUB_ACTIONS"] == "true" && environment["RUNNER_ENVIRONMENT"] == "github-hosted"
        guard hosted || environment["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1",
              RecordingFixture.enabled, let root = RecordingFixture.root,
              LibraryLaunchContext.argument("-CassiniSilentMicrophone") == "YES" else { exit(78) }
        let recorder = RecordingController.shared, runtime = RecordingRuntime.shared
        do {
            let surface = try SpectrogramSurface(style:.row)
            let strip = RecordingSpectrogramView(style:.row)
            strip.frame = NSRect(x:0,y:0,width:96,height:32)
            strip.present(bank:surface,revision:1,displayMs:1000,reduced:false)
            let clip = try (strip.layer?.sublayers?.first).unwrap("row clip layer")
            let scrolling = try (clip.sublayers?.first).unwrap("row scrolling layer")
            try require(clip.frame.width == 96 && scrolling.position.x == 46,"96-point viewport anchors the newest audio at its right edge")
            strip.present(bank:surface,revision:1,displayMs:1000,reduced:true)
            try require(scrolling.position.x == 0 && abs(scrolling.transform.m11 - 0.48) < 0.001,"reduced motion fits the entire stationary row inside its viewport")
            runtime.start()
            try require(runtime.shortcut.registered,"global shortcut registration")
            try recorder.useFixtureClock()
            await recorder.start(parent:root)
            try await recorder.advanceFixtureMedia(toMilliseconds:200)
            try await waitForPower(runtime,held:true)
            try require(recorder.isRecording && runtime.power.held,"recording and real power assertion")
            let folder = try recorder.directory.unwrap("capture directory")
            let id = try UUID(uuidString:String(folder.lastPathComponent.dropFirst("Recording-".count))).unwrap("capture identity")
            let scanner = LibraryScanner(root:root,activity:CaptureActivitySnapshot([id:.recording]))
            let meeting = try scanner.scan().meetings.first.unwrap("live Library meeting")
            let model = RecordingPageModel.editor(for:meeting)
            var boundCall = meeting
            boundCall.title = "Browser call title"
            model.update(boundCall)
            try require(model.title == "Browser call title","late browser title updates the untouched editor")
            boundCall.title = "Title arriving during focus"
            model.update(boundCall,isEditing:true)
            try require(model.title == "Browser call title","external titles leave the focused editor alone")
            model.update(boundCall)
            try require(model.title == "Title arriving during focus","blur adopts the latest untouched call title")
            model.title = "Temporary title"; model.changeTitle(); await RecordingPageModel.flushAll()
            model.title = ""; model.changeTitle(); await RecordingPageModel.flushAll()
            let cleared = try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("meeting.json"))) as! [String:Any]
            try require(cleared["title"] is NSNull && cleared["titleSource"] as? String == "meeting-window","clearing the title removes the user override")
            model.title = "Comfort probe title"; model.changeTitle()
            // A prior version's notes are data, not an editable live draft.
            let existingNotes: [[String:Any]] = [["atMs":12,"text":"Keep this note\nexactly"],["atMs":3,"text":" Earlier note "]]
            try MeetingMetadataWriter(directory:folder,id:id).transaction { $0["notes"] = existingNotes }
            await RecordingPageModel.flushAll()
            // A completed write can precede the scanner. Neither that stale
            // snapshot nor opening another capture may replace the user's title.
            model.update(meeting)
            try require(model.title == "Comfort probe title","stale scan cannot undo a completed title write")
            let updated = try scanner.scan().meetings.first.unwrap("updated Library meeting")
            let afterTitle = try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("meeting.json"))) as! [String:Any]
            try require(try JSONSerialization.data(withJSONObject:afterTitle["notes"]!,options:.sortedKeys) == JSONSerialization.data(withJSONObject:existingNotes,options:.sortedKeys),"title edit preserves existing notes exactly")
            try require(updated.title == model.title && recorder.title == model.title,"title persisted and published")
            try require(RecordingPageModel.editor(for:updated) === model,"Back/Open retains editor")
            for window in NSApp.windows { window.orderOut(nil) }
            try await recorder.advanceFixtureMedia(toMilliseconds:19_980)
            try require(!recorder.microphoneSilent,"microphone is not silent before 20 seconds")
            try await recorder.advanceFixtureMedia(toMilliseconds:20_000)
            try require(recorder.microphoneSilent && recorder.elapsedMs == 20_000,"20-second silent-microphone rule (phase=\(recorder.phase), elapsed=\(recorder.elapsedMs), levels=\(recorder.levels))")
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
            try require(RecordingPageModel.editor(for:meeting) === model && model.title == "Comfort probe title","switching captures retains the settled editor before rescan")
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
            try await waitForPower(runtime,held:false)
            try require(!runtime.power.held && recorder.canStart,"power released after Stop")
            try require(RecordingDiskWatch.warningTitle == nil,"no late disk sample recreates the warning")
            let saved = try LibraryScanner(root:root).scan().meetings.first.unwrap("saved meeting")
            try require(saved.state.lifecycle == .saved && saved.canPlaySession && saved.durationMs == 20_000 && saved.title == model.title && saved.notes == updated.notes,"saved title, notes and 20 seconds of playable audio")
            runtime.stop()
            // Independent synthetic browser source: no browser, device or live
            // desktop is involved. A quiet source must still advance its clock.
            let browser = try RecordingSession(parent:root,title:"Private browser",source:"chromium")
            CaptureActivityStore.shared.set(browser.manifest.id,.recording)
            defer { CaptureActivityStore.shared.set(browser.manifest.id,nil) }
            try browser.addTrack(id:"a",label:"A",kind:"remote",sampleRate:16000,channels:1)
            try browser.appendNative(id:"a",pcm:Data(repeating:0,count:3200),offsetMs:0)
            let browserScanner = LibraryScanner(root:root,activity:CaptureActivitySnapshot([browser.manifest.id:.recording]))
            let browserMeeting = try browserScanner.scan().meetings.first(where:{ $0.id == browser.manifest.id }).unwrap("private browser meeting")
            var browserUptime: TimeInterval = 100
            let editor = RecordingPageModel.editor(for:browserMeeting,uptime:{ browserUptime }), elapsed = editor.elapsedMs
            try await waitForVoiceCount(editor,1)
            browserUptime += 2
            try require(!editor.native && editor.elapsedMs == elapsed + 2000 && editor.voiceCount == 1,"browser clock advances without a manifest write")
            try browser.addTrack(id:"b",label:"B",kind:"remote",sampleRate:16000,channels:1)
            try browser.appendNative(id:"b",pcm:Data(repeating:0,count:3200),offsetMs:0)
            let newer = try browserScanner.scan().meetings.first(where:{ $0.id == browser.manifest.id }).unwrap("changed browser source list")
            try require(RecordingPageModel.editor(for:newer) === editor,"browser updates keep unsaved editor state")
            editor.update(newer)
            try await waitForVoiceCount(editor,2)
            try require(editor.voiceCount == 2,"browser source count updates")
            let saving = try LibraryScanner(root:root,activity:CaptureActivitySnapshot([browser.manifest.id:.saving]))
                .scan().meetings.first(where:{ $0.id == browser.manifest.id }).unwrap("saving browser meeting")
            editor.update(saving)
            let savingTime = editor.elapsedMs
            try require(editor.saving,"browser Saving remains explicit after capture ownership ends")
            browserUptime += 1000
            try require(savingTime == saving.durationMs && editor.elapsedMs == savingTime,"browser Saving uses the producer end instead of the hidden wall-clock interval")
            var noStart = saving; noStart.start = nil; noStart.state.liveMs = nil
            editor.update(noStart)
            browserUptime += 1000
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
            var uptime: TimeInterval = 100
            let editor = RecordingPageModel.editor(for:recording,uptime:{ uptime }), initial = editor.elapsedMs
            uptime += 2
            guard editor.elapsedMs == initial + 2000 else { throw POSIXError(.EINVAL) }
            // The cached editor is reopened after the source stopped. Its known
            // physical end is only 100 ms; the hidden wall clock must not win.
            let saving = try LibraryScanner(root:root,activity:CaptureActivitySnapshot([session.manifest.id:.saving]))
                .scan().meetings.first.unwrap("saving fixture")
            guard RecordingPageModel.editor(for:saving) === editor else { throw POSIXError(.EINVAL) }
            editor.update(saving)
            guard editor.elapsedMs == 100 else {
                throw NSError(domain:"SavingProbeProducerEnd",code:1,userInfo:[NSLocalizedDescriptionKey:"Expected 100 ms producer end; got \(editor.elapsedMs)"])
            }
            uptime += 1000
            guard editor.elapsedMs == 100 else { throw POSIXError(.EINVAL) }
            var noStart = saving; noStart.start = nil; noStart.state.liveMs = nil
            editor.update(noStart)
            uptime += 1000
            editor.title = "Title while saving"; editor.changeTitle()
            await RecordingPageModel.flushAll()
            guard editor.elapsedMs == 100 else { throw POSIXError(.EINVAL) }
            try session.finish()
            try await verifyImmediateStopSavingFeedback(parent:root.appendingPathComponent("browser-stop-probe"))
            let visible = NSApp.windows.filter { $0.isVisible && !(String(describing:type(of:$0)) == "NSStatusBarWindow" && $0.level == .statusBar) }
            guard visible.isEmpty else { throw NSError(domain:"SavingProbeVisibleWindow",code:1,userInfo:[NSLocalizedDescriptionKey:visible.map { $0.title + " class=" + String(describing:type(of:$0)) + " level=" + String($0.level.rawValue) }.joined(separator:", ")]) }
            let report: [String:Any] = ["recordingClockAdvances":true,"savingUsesProducerEnd":true,"lifecycleOnlySavingHolds":true,"immediateStopSavingFeedback":true,"audioDevicesOpened":false,"documentWindowsOpened":false]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) + Data([10])); exit(0)
        } catch { FileHandle.standardError.write(Data("Saving clock probe failed: \(error)\n".utf8)); exit(1) }
    }
    private struct SavingSurfaceHarness: View {
        @State private var recorder = RecordingController.shared
        @State private var captures = CaptureCollection.shared
        let onLaidOut: (String) -> Void
        var body: some View {
            let _ = (recorder.isRecording, recorder.isSaving, captures.isRecording, captures.isSaving)
            VStack(alignment:.leading,spacing:8) {
                if RecordingOverview.active {
                    LibraryToolbarAction(title:UXText.text("common.stop"),label:UXText.text("common.stop"),identifier:"meeting-stop",style:.stop,fixtureOnLaidOut:onLaidOut) { RecordingOverview.stop() }
                } else if RecordingOverview.saving {
                    LibraryToolbarAction(title:UXText.text("states.badge.saving"),label:UXText.text("states.badge.saving"),identifier:"meeting-saving",style:.saving,enabled:false,fixtureOnLaidOut:onLaidOut) { }
                } else {
                    LibraryToolbarAction(title:UXText.text("common.record"),label:UXText.text("common.record"),identifier:"toolbar-record",style:.record,enabled:RecordingOverview.canStart,fixtureOnLaidOut:onLaidOut) { }
                }
                IdleStatusMenu()
            }
        }
    }
    private static func findButton(in view: NSView, identifier: String) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityIdentifier() == identifier { return button }
        for child in view.subviews {
            if let found = findButton(in:child,identifier:identifier) { return found }
        }
        return nil
    }
    private static func verifyImmediateStopSavingFeedback(parent: URL) async throws {
        let collection = CaptureCollection.shared
        let probe = try collection.beginBrowserStopProbeForTesting(parent:parent)
        let (laidOutStream, laidOutCont) = AsyncStream<String>.makeStream()
        defer { laidOutCont.finish() }
        let host = NSHostingView(rootView:SavingSurfaceHarness(onLaidOut:{ identifier in
            laidOutCont.yield(identifier)
        }))
        host.frame = NSRect(x:0,y:0,width:360,height:260)
        host.layoutSubtreeIfNeeded()
        var laidOutIter = laidOutStream.makeAsyncIterator()
        func waitForLaidOutButton(identifier: String, absent: [String], code: Int, description: String) async throws -> NSButton {
            func matchingInstalledButton() -> NSButton? {
                host.layoutSubtreeIfNeeded()
                guard let button = findButton(in:host,identifier:identifier),
                      button.superview != nil, button.frame.width > 0,
                      absent.allSatisfy({ findButton(in:host,identifier:$0) == nil }) else { return nil }
                return button
            }
            if let ready = matchingInstalledButton() { return ready }
            let (cancelledStream, cancelledCont) = AsyncStream<Void>.makeStream()
            let timeoutTask = Task { @MainActor in
                defer { cancelledCont.yield(()); cancelledCont.finish() }
                do { try await Task.sleep(for:.seconds(10)) } catch { return }
                laidOutCont.finish()
            }
            while await laidOutIter.next() != nil {
                if let ready = matchingInstalledButton() {
                    timeoutTask.cancel()
                    await timeoutTask.value
                    var cancelledIter = cancelledStream.makeAsyncIterator()
                    _ = await cancelledIter.next()
                    return ready
                }
            }
            timeoutTask.cancel()
            await timeoutTask.value
            throw NSError(domain:"SavingProbeImmediateFeedback",code:code,userInfo:[NSLocalizedDescriptionKey:description])
        }
        let stopButton: NSButton
        do {
            stopButton = try await waitForLaidOutButton(identifier:"meeting-stop",absent:["meeting-saving","toolbar-record"],code:1,description:"Timed out waiting for active Stop button layout")
        } catch {
            try? await probe.finish()
            throw error
        }
        guard RecordingOverview.active, !RecordingOverview.saving,
              RecordingOverview.recordCommandTitle == UXText.text("common.stop"),
              IdleStatusMenu.statusTitle == UXText.text("hidden.status.watching"),
              stopButton.isEnabled else {
            try? await probe.finish()
            throw NSError(domain:"SavingProbeImmediateFeedback",code:1,userInfo:[NSLocalizedDescriptionKey:"Expected active Stop state before stopping"])
        }
        collection.stop(probe.id)
        // Synchronously on Stop, before browser PCM flush finishes:
        guard !RecordingOverview.active, RecordingOverview.saving, !RecordingOverview.canStart,
              RecordingOverview.recordCommandTitle == UXText.text("states.badge.saving"),
              IdleStatusMenu.statusTitle == UXText.text("states.badge.saving") else {
            try? await probe.finish()
            throw NSError(domain:"SavingProbeImmediateFeedback",code:2,userInfo:[NSLocalizedDescriptionKey:"Expected immediate synchronous Saving state on Stop"])
        }
        let savingButton: NSButton
        do {
            savingButton = try await waitForLaidOutButton(identifier:"meeting-saving",absent:["meeting-stop","toolbar-record"],code:3,description:"Timed out waiting for Saving… toolbar control layout")
        } catch {
            try? await probe.finish()
            throw error
        }
        guard collection.captures[probe.id]?.owner.snapshot.phase == .recording,
              !savingButton.isEnabled,
              savingButton.accessibilityLabel() == UXText.text("states.badge.saving") else {
            try? await probe.finish()
            throw NSError(domain:"SavingProbeImmediateFeedback",code:3,userInfo:[NSLocalizedDescriptionKey:"Expected disabled Saving… toolbar control while browser flush is pending"])
        }
        try await probe.finish()
        let recordButton = try await waitForLaidOutButton(identifier:"toolbar-record",absent:["meeting-stop","meeting-saving"],code:4,description:"Timed out waiting for Record toolbar control layout")
        guard !RecordingOverview.active, !RecordingOverview.saving,
              RecordingOverview.recordCommandTitle == UXText.text("common.record"),
              IdleStatusMenu.statusTitle == UXText.text("hidden.status.watching"),
              recordButton.accessibilityLabel() == UXText.text("common.record") else {
            throw NSError(domain:"SavingProbeImmediateFeedback",code:4,userInfo:[NSLocalizedDescriptionKey:"Expected Record toolbar control to recover once Saving settles"])
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
