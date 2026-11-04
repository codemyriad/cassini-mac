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
    private(set) var usesParakeet: Bool
    private(set) var downloaded = false
    private(set) var busy = false
    private(set) var progress: Double?
    private(set) var message: String?
    private(set) var failedDownload = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var refreshed = false
    @ObservationIgnored private var client: ModelDownloadClient?
    @ObservationIgnored private var operation: Task<Void,Never>?
    @ObservationIgnored private var inventory: Task<(valid:Bool,exists:Bool),Never>?
    init() { usesParakeet = RecordingPreferences.defaults.string(forKey:Self.preference) == ParakeetPin.transcriptModel }
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
        guard !refreshed,!busy else { return }
        if inventory == nil {
            let model = Self.modelDirectory, jobs = Self.jobsDirectory, appData = Self.appData
            let manifest = Bundle.main.url(forResource:"model-manifest",withExtension:"json",subdirectory:"Parakeet")!
            inventory = Task.detached(priority:.utility) {
                SpeechScratch.removeAbandoned(in:jobs)
                let plan = try? ModelManifest.plan(Data(contentsOf:manifest),pin:.parakeetUltra)
                let valid = plan.map { ModelStorage.isInstalled($0,in:appData,verifyHashes:false) } ?? false
                return (valid,FileManager.default.fileExists(atPath:model.path))
            }
        }
        let token = generation, status = await inventory!.value
        guard token == generation else { return }
        inventory = nil; refreshed = true; downloaded = status.valid
        if !status.valid && (usesParakeet || status.exists) { await invalidModel(generation:token) }
    }
    func chooseParakeet(_ value: Bool) {
        guard !value || downloaded else { return }
        usesParakeet = value
        RecordingPreferences.defaults.set(value ? ParakeetPin.transcriptModel : "whistle",forKey:Self.preference)
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
            defer { busy = false; progress = nil; self.client = nil; operation = nil }
            do {
                _ = try await client.install(appData:Self.appData)
                downloaded = true; refreshed = true
                // D16: finishing a download does not change the radio choice.
            } catch is CancellationError { }
            catch {
                failedDownload = true
                message = UXText.text("errors.modelDownloadFailed.line",["model":UXText.text("models.parakeetUltra.name")])
            }
        }
    }
    func cancelDownload() { operation?.cancel() }
    func remove() {
        guard !busy else { return }
        invalidateInventory()
        generation = UUID(); busy = true; chooseParakeet(false)
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                try await ModelDownloader(appData:Self.appData,userAgent:ModelUserAgent.app()).remove(.parakeetUltra)
                downloaded = false; refreshed = true; failedDownload = false
                message = UXText.text("models.parakeetUltra.removedFallback")
            } catch { refreshed = false; NSApp.presentError(error) }
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
        guard usesParakeet else { return nil }
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
        let wasSelected = usesParakeet
        generation = UUID(); chooseParakeet(false)
        let cleanupGeneration = generation
        busy = true
        defer { if cleanupGeneration == generation { busy = false } }
        do {
            let manifest = Bundle.main.url(forResource:"model-manifest",withExtension:"json",subdirectory:"Parakeet")!
            let plan = try ModelManifest.plan(Data(contentsOf:manifest),pin:.parakeetUltra)
            let removed = try await ModelDownloader(appData:Self.appData,userAgent:ModelUserAgent.app()).removeInvalid(plan)
            guard cleanupGeneration == generation else { return }
            downloaded = !removed; refreshed = true; failedDownload = false
            if !removed { chooseParakeet(wasSelected) }
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
