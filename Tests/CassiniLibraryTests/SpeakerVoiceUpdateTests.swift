// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniLibrary

@MainActor struct SpeakerVoiceUpdateTests {
    @Test(arguments:["preparing", "setting-off", "model-missing", "preparation-failed"])
    func renameWithoutPreparationPreservesContribution(_ reason:String) async throws {
        let (root,meeting)=try SpeakerEditsTests().fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let store=SavedVoicesStore(directory:root.appendingPathComponent("voices"))
        let id=try await store.enroll(name:"Alice",embedding:[Float](repeating:1,count:512),seconds:5,generation:0,
                                      clip:.init(meeting:"meeting",speaker:"a",startMs:0,endMs:5000))
        let snapshot=try await store.snapshot()
        let choice=SpeakerVoiceChoice(existing:snapshot.voiceID(meeting:"meeting",speaker:"a") != nil,enabled:false)
        #expect(choice.remember)
        var committed=false, retry=true
        let failed=try await SpeakerEditTransaction.run(library:{ try SpeakerEdits.apply(.name(speaker:"a",value:"Alice corrected"),to:meeting,roots:[root]) },committed:{ _ in committed=true;retry=false },readOnly:{false},voices:{
            if choice.update(prepared:false) == .forget { try await store.unenroll(meeting:"meeting",speakers:["a"]) }
        })
        #expect(committed && !retry && !failed)
        #expect(LibraryScanner(root:root).meeting(at:meeting.folder)?.speaker(for:"a")?.name == "Alice corrected")
        #expect(try await store.snapshot().voiceID(meeting:"meeting",speaker:"a") == id)
    }
    @Test func forgettingRequiresAnExplicitChoice() {
        var choice=SpeakerVoiceChoice(existing:false)
        #expect(choice.update(prepared:false) == .preserve)
        choice.choose(true)
        #expect(choice.update(prepared:false) == .preserve)
        #expect(choice.update(prepared:true) == .enroll)
        choice.choose(false)
        #expect(choice.update(prepared:true) == .forget)
    }
    @Test func voiceFailureCannotRetryTheLibraryCommit() async throws {
        var merges=["first", "second"], retry=true, voiceCalls=0
        let failed=try await SpeakerEditTransaction.run(library:{ merges.removeLast() },committed:{ _ in retry=false },readOnly:{false},voices:{
            #expect(!retry && merges == ["first"])
            voiceCalls += 1
            throw SavedVoicesError.unsafeStorage
        })
        #expect(failed && !retry && merges == ["first"] && voiceCalls == 1)
    }
    @Test func undoMergeWithReadOnlyStoreSkipsVoiceWrites() async throws {
        let (root,meeting)=try SpeakerEditsTests().fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        try SpeakerEdits.apply(.merge(from:"a",into:"b"),to:meeting,roots:[root])
        let first=try #require(LibraryScanner(root:root).meeting(at:meeting.folder))
        try SpeakerEdits.apply(.merge(from:"c",into:"b"),to:first,roots:[root])
        let second=try #require(LibraryScanner(root:root).meeting(at:meeting.folder))
        #expect(second.speakerMergeCount == 2)
        let store=SavedVoicesStore(directory:root.appendingPathComponent("voices"))
        _=try await store.snapshot()
        let file=root.appendingPathComponent("voices/people.json")
        let newer=Data("{\"version\":99,\"unknown\":true}".utf8)
        try newer.write(to:file)
        let snapshot=try await store.snapshot()
        var retry=true,voiceCalls=0
        let failed=try await SpeakerEditTransaction.run(library:{
            try SpeakerEdits.apply(.undoMerge,to:second,roots:[root])
        },committed:{ _ in retry=false },readOnly:{snapshot.readOnly},voices:{
            voiceCalls += 1
            try await store.unenroll(meeting:meeting.folder.lastPathComponent,speakers:["a","b","c"])
        })
        let updated=try #require(LibraryScanner(root:root).meeting(at:meeting.folder))
        #expect(!failed && !retry && voiceCalls == 0 && updated.speakerMergeCount == 1)
        #expect(try Data(contentsOf:file) == newer)
    }
    @Test func failedLibraryWriteNeverTouchesVoices() async {
        var committed=false, voiceCalls=0
        do {
            _=try await SpeakerEditTransaction.run(library:{ throw SavedVoicesError.unavailable },committed:{ _ in committed=true },readOnly:{false},voices:{voiceCalls += 1})
            Issue.record("Expected Library failure")
        } catch {}
        #expect(!committed && voiceCalls == 0)
    }
}

actor EnrollmentGate {
    private var continuation:CheckedContinuation<Void,Never>?
    private var open=false
    func wait() async { if !open { await withCheckedContinuation { continuation=$0 } } }
    func release() { open=true;continuation?.resume();continuation=nil }
}
@MainActor struct VoiceEnrollmentOperationTests {
    nonisolated private static func wait(_ semaphore:DispatchSemaphore) { semaphore.wait() }
    nonisolated private static func didSignal(_ semaphore:DispatchSemaphore) -> Bool { semaphore.wait(timeout:.now()) == .success }
    @Test func cancelDuringPermissionNeverStartsRecording() async {
        let operation=VoiceEnrollmentOperation(), entered=EnrollmentGate(), release=EnrollmentGate()
        var recording=false,denied=false,failed=false
        let task=operation.requestPermission(request:{ await entered.release();await release.wait();return true },
            granted:{ recording=true },denied:{denied=true},failed:{_ in failed=true})
        await entered.wait();operation.cancel();await release.release();await task.value
        #expect(!recording && !denied && !failed)
    }
    @Test func deniedPermissionHasItsOwnCallback() async {
        var recording=false,denied=false,failed=false
        let task=VoiceEnrollmentOperation().requestPermission(request:{false},granted:{recording=true},denied:{denied=true},failed:{_ in failed=true})
        await task.value
        #expect(!recording && denied && !failed)
    }
    @Test(arguments:["reading", "inference"])
    func cancellationRejectsLateWorkerResultsAndCleansOnce(_ stage:String) async {
        let operation=VoiceEnrollmentOperation(), entered=EnrollmentGate(), release=EnrollmentGate()
        var prepared=false,cleanups=0,workerCalls=0,failures=0
        let task=operation.infer(read:{
            if stage == "reading" { await entered.release();await release.wait() }
            return [Float](repeating:1,count:64000)
        },worker:{ samples in
            workerCalls += 1
            if stage == "inference" { await entered.release();await release.wait() }
            return samples.count
        },ready:{_ in prepared=true},failed:{_ in failures += 1},cleanup:{ cleanups += 1 })
        await entered.wait();operation.cancel()
        #expect(cleanups == 1)
        let newGate=EnrollmentGate()
        let next=operation.start(cleanup:{cleanups += 1}) { await newGate.wait() }
        await release.release();await task.value
        #expect(!prepared && failures == 0 && cleanups == 1)
        #expect(workerCalls == (stage == "reading" ? 0:1))
        await newGate.release();await next.value
        #expect(cleanups == 2)
    }
    @Test func cancelRecordingCleansOwnedResourcesImmediately() async {
        let operation=VoiceEnrollmentOperation()
        var recording=false,stops=0
        let task=operation.requestPermission(request:{true},granted:{recording=true},denied:{Issue.record("Unexpected denial")},stopRecording:{recording=false;stops += 1},failed:{_ in Issue.record("Unexpected recording failure")})
        await task.value
        #expect(recording)
        operation.cancel()
        #expect(!recording && stops == 1)
        operation.cancel()
        #expect(stops == 1)
    }
    @Test func cancellationReachesDetachedAudioWork() async {
        let entered=DispatchSemaphore(value:0), cancelled=DispatchSemaphore(value:0)
        let task=Task {
            try await VoiceEnrollmentWork.run {
                entered.signal()
                while !Task.isCancelled { sched_yield() }
                cancelled.signal()
                try Task.checkCancellation()
            }
        }
        // Wait off the main actor so the task can start.
        await Task.detached { Self.wait(entered) }.value
        task.cancel()
        do { try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(Self.didSignal(cancelled))
    }
}
