// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Observation
import CassiniModels
import CassiniParakeet
import CassiniTranscription

/// Persistent model choice and owned downloads survive Settings being closed.
/// Only an explicit Download action constructs a network client.
@MainActor @Observable final class SpeechModelController {
    static let shared = SpeechModelController()
    private static let preference = "CassiniSpeechModel"
    private static let adoptedPreference = "CassiniParakeetAdoptedRevision"
    private static let announcedPreference = "CassiniParakeetAnnouncedRevision"
    private static let pendingAnnouncementPreference = "CassiniParakeetPendingAnnouncement"
    private static let completedWhistlePreference = "CassiniCompletedWhistleTranscription"
    private static let afterFirstPreference = "CassiniParakeetAfterFirstShown"
    private static let dismissedPreference = "CassiniParakeetSuggestionDismissed"
    private var adoption: SpeechModelAdoption
    private var suggestion: SpeechModelSuggestion
    var usesParakeet: Bool { adoption.choice == .parakeet }
    var canAnnounceDefault: Bool { adoption.canAnnounce }
    var hasAnnouncedDefault: Bool { adoption.announcedRevision == ParakeetPin.sourceSHA256 }
    private(set) var recommendationCapable = false
    private(set) var recommendationDiskAvailable = false
    var showsSettingsSuggestion: Bool { showsSuggestion(afterFirst:false) }
    var showsAfterFirstSuggestion: Bool { showsSuggestion(afterFirst:true) }
    var hasCompletedWhistle: Bool { suggestion.completedWhistle }
    var hasPresentedAfterFirst: Bool { suggestion.afterFirstShown }
    func takeAfterFirstSuggestion() -> Bool {
        guard showsAfterFirstSuggestion, suggestion.takeAfterFirst() else { return false }
        RecordingPreferences.defaults.set(true,forKey:Self.afterFirstPreference); return true
    }
    private(set) var downloaded = false
    private(set) var busy = false
    private(set) var progress: Double?
    private(set) var message: String?
    private(set) var failedDownload = false
    @ObservationIgnored private var recommendationSerial: UInt64 = 0
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var refreshed = false
    @ObservationIgnored private var client: ModelDownloadClient?
    @ObservationIgnored private var operation: Task<Void,Never>?
    @ObservationIgnored private var inventory: Task<(valid:Bool,exists:Bool),Never>?
    init() {
        let defaults = RecordingPreferences.defaults
        adoption = .init(choice:defaults.string(forKey:Self.preference) == ParakeetPin.transcriptModel ? .parakeet : .whistle,
            adoptedRevision:defaults.string(forKey:Self.adoptedPreference),announcedRevision:defaults.string(forKey:Self.announcedPreference),
            pendingAnnouncementRevision:defaults.string(forKey:Self.pendingAnnouncementPreference))
        suggestion = .init(completedWhistle:defaults.bool(forKey:Self.completedWhistlePreference),dismissed:defaults.bool(forKey:Self.dismissedPreference),afterFirstShown:defaults.bool(forKey:Self.afterFirstPreference))
    }
    private func showsSuggestion(afterFirst: Bool) -> Bool {
        suggestion.show(capable:recommendationCapable,enoughDisk:recommendationDiskAvailable,installed:downloaded,busy:busy,afterFirst:afterFirst)
    }
    func dismissSuggestion() {
        suggestion.dismiss(); RecordingPreferences.defaults.set(true,forKey:Self.dismissedPreference)
    }
    func transcriptionFinished(engine: String, succeeded: Bool) {
        let wasCompleted = suggestion.completedWhistle
        suggestion.transcriptionFinished(engine:engine,succeeded:succeeded)
        if !wasCompleted, suggestion.completedWhistle {
            RecordingPreferences.defaults.set(true,forKey:Self.completedWhistlePreference)
            Task { await refreshRecommendation() }
        }
    }
    func takeDefaultAnnouncement() -> Bool {
        guard adoption.takeAnnouncement() else { return false }
        persistChoice(); return true
    }
    private func persistChoice() {
        let defaults = RecordingPreferences.defaults
        defaults.set(usesParakeet ? ParakeetPin.transcriptModel : "whistle",forKey:Self.preference)
        defaults.set(adoption.adoptedRevision,forKey:Self.adoptedPreference)
        defaults.set(adoption.announcedRevision,forKey:Self.announcedPreference)
        defaults.set(adoption.pendingAnnouncementRevision,forKey:Self.pendingAnnouncementPreference)
    }
    private func adoptVerifiedInstallation() {
        adoption.verified(ParakeetPin.sourceSHA256); persistChoice()
    }
    func refreshRecommendation() async {
        recommendationSerial &+= 1; let serial = recommendationSerial
        let appData = Self.appData, manifest = Bundle.main.url(forResource:"model-manifest",withExtension:"json",subdirectory:"Parakeet")!
        let app = Bundle.main.bundleURL, memory = ProcessInfo.processInfo.physicalMemory
        #if arch(arm64) || arch(x86_64)
        let architecture = true
        #else
        let architecture = false
        #endif
        let status = await Task.detached(priority:.utility) {
            let files = FileManager.default
            let runtime = ["Contents/MacOS/cassini-parakeet-worker","Contents/Frameworks/libsherpa-onnx-c-api.dylib","Contents/Frameworks/libonnxruntime.dylib"]
                .allSatisfy { files.isReadableFile(atPath:app.appendingPathComponent($0).path) }
            var volume = appData
            while !files.fileExists(atPath:volume.path), volume.path != "/" { volume.deleteLastPathComponent() }
            let values = try? files.attributesOfFileSystem(forPath:volume.path)
            let disk = (values?[.systemFreeSize] as? NSNumber).flatMap { free in
                (values?[.systemSize] as? NSNumber).map { ModelDiskSpace(free:free.uint64Value,total:$0.uint64Value) }
            }
            let plan = try? ModelManifest.plan(Data(contentsOf:manifest),pin:.parakeetUltra)
            return ParakeetSuggestionEligibility(physicalMemory:memory,architectureSupported:architecture,runtimeAvailable:runtime,
                disk:disk,requiredStorage:plan?.spaceRequired ?? UInt64.max)
        }.value
        guard recommendationSerial == serial else { return }
        recommendationCapable = status.capable; recommendationDiskAvailable = status.enoughDisk
    }
    static var appData: URL {
        #if DEBUG
        if let id = SettingsFixture.id {
            return FileManager.default.temporaryDirectory.appendingPathComponent("CassiniSpeechModels-" + id.uuidString)
        }
        #endif
        return ModelStorage.appData
    }
    static var modelDirectory: URL { appData.appendingPathComponent("models/" + ParakeetPin.id + "/" + ParakeetPin.sourceSHA256) }
    static var jobsDirectory: URL { appData.appendingPathComponent("speech-jobs") }
    static var downloadBytes: Int64 {
        // Pinned dist manifest snapshot, included at build time. Opening Settings
        // never fetches metadata or a model.
        let url = Bundle.main.url(forResource:"model-manifest",withExtension:"json",subdirectory:"Parakeet")!
        return Int64(try! ModelManifest.plan(Data(contentsOf:url),pin:.parakeetUltra).compressedBytes)
    }
    func refresh() async {
        await refreshRecommendation()
        guard !refreshed,!busy else { return }
        if inventory == nil {
            let model = Self.modelDirectory, jobs = Self.jobsDirectory, appData = Self.appData
            let manifest = Bundle.main.url(forResource:"model-manifest",withExtension:"json",subdirectory:"Parakeet")!
            let verifyHashes = adoption.adoptedRevision != ParakeetPin.sourceSHA256
            inventory = Task.detached(priority:.utility) {
                SpeechScratch.removeAbandoned(in:jobs)
                let plan = try? ModelManifest.plan(Data(contentsOf:manifest),pin:.parakeetUltra)
                let valid = plan.map { ModelStorage.isInstalled($0,in:appData,verifyHashes:verifyHashes) } ?? false
                return (valid,FileManager.default.fileExists(atPath:model.path))
            }
        }
        let token = generation, status = await inventory!.value
        guard token == generation else { return }
        inventory = nil; refreshed = true; downloaded = status.valid
        if status.valid { adoptVerifiedInstallation() }
        else if usesParakeet || status.exists { await invalidModel(generation:token) }
        else { adoption.unavailable(); persistChoice() }
    }
    func chooseParakeet(_ value: Bool) {
        guard !value || downloaded else { return }
        adoption.choose(value ? .parakeet : .whistle); persistChoice()
    }
    func download() {
        guard !busy else { return }
        invalidateInventory()
        generation = UUID(); let token = generation
        busy = true; progress = 0; message = nil; failedDownload = false
        let client = ModelDownloadClient { [weak self] value in
            Task { @MainActor in guard let self, self.generation == token else { return }; self.progress = value }
        }
        self.client = client
        operation = Task {
            defer {
                if self.client === client { progress = nil; self.client = nil; operation = nil }
                if generation == token { busy = false }
            }
            do {
                _ = try await client.install(appData:Self.appData)
                guard generation == token else { return }
                downloaded = true; refreshed = true
                // D78: installation has verified all pinned files before adoption.
                adoptVerifiedInstallation()
            } catch is CancellationError { }
            catch {
                guard generation == token else { return }
                failedDownload = true
                message = UXText.text("errors.modelDownloadFailed.line",["model":UXText.text("models.parakeetUltra.name")])
            }
        }
    }
    func cancelDownload() { operation?.cancel() }
    func remove() {
        guard !busy else { return }
        invalidateInventory()
        let previousAdoption = adoption
        generation = UUID(); busy = true; adoption.unavailable(); persistChoice(); dismissSuggestion()
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                try await ModelDownloader(appData:Self.appData,userAgent:ModelUserAgent.app()).remove(.parakeetUltra)
                downloaded = false; refreshed = true; failedDownload = false
                message = UXText.text("models.parakeetUltra.removedFallback")
            } catch {
                adoption = previousAdoption; adoption.choose(.whistle); persistChoice()
                refreshed = false; NSApp.presentError(error)
            }
        }
    }
    struct JobModel {
        let lease: ParakeetModelLease
        let generation: UUID
    }
    /// The caller retains this lease until the worker exits. A concurrent Remove
    /// unlinks the installation, while this accepted job keeps its exact files.
    func modelForNewJob() async throws -> JobModel? {
        await refresh()
        guard usesParakeet, downloaded else { return nil }
        let token = generation, model = Self.modelDirectory, jobs = Self.jobsDirectory
        do {
            let lease = try await Task.detached(priority:.userInitiated) {
                try FileManager.default.createDirectory(at:jobs,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                return try ParakeetModelLease(model:model,temporaryRoot:jobs)
            }.value
            return JobModel(lease:lease,generation:token)
        } catch ParakeetFailure.invalidModel {
            await invalidModel(generation:token); return nil
        }
    }
    func invalidModel(generation token: UUID) async {
        // An old worker must not remove a replacement download or overwrite the
        // explicit Remove message after the person has changed the installation.
        guard token == generation else { return }
        invalidateInventory()
        let wasSelected = usesParakeet, previousAdoption = adoption
        generation = UUID(); adoption.unavailable(); persistChoice()
        let cleanupGeneration = generation
        busy = true
        defer { if cleanupGeneration == generation { busy = false } }
        do {
            let manifest = Bundle.main.url(forResource:"model-manifest",withExtension:"json",subdirectory:"Parakeet")!
            let plan = try ModelManifest.plan(Data(contentsOf:manifest),pin:.parakeetUltra)
            let removed = try await ModelDownloader(appData:Self.appData,userAgent:ModelUserAgent.app()).removeInvalid(plan)
            guard cleanupGeneration == generation else { return }
            downloaded = !removed; refreshed = true; failedDownload = false
            if !removed { adoption = previousAdoption; adoptVerifiedInstallation() }
            else if wasSelected { message = UXText.text("models.parakeetUltra.invalidFallback") }
        } catch {
            guard cleanupGeneration == generation else { return }
            refreshed = false; NSApp.presentError(error)
        }
    }
    private func invalidateInventory() { inventory?.cancel(); inventory = nil; refreshed = false }
    #if DEBUG
    func waitForOperation() async { await operation?.value }
    func reloadInventory() async { refreshed = false; await refresh() }
    #endif
}
