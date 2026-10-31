// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import Observation
import CassiniLibrary
import CassiniRecording
import CassiniBrowserControl
import CassiniKit

private struct BrowserSourceObservation: Equatable {
    let page: BrowserCallLifecycle.Page?
    let observedAt: TimeInterval?
    let active: Bool
}

struct LiveCapture {
    let owner: OwnedBrowserCapture
    let input: CaptureInputLifecycle
    let captureID: String
    let originUptime: TimeInterval
    let spectrogram: RecordingSpectrogram?
    var snapshot: OwnedCaptureSnapshot
    var key: BrowserMeetingKey?
    var levels: [CaptureSide:Float] = [:]
    var sourceProblem = false
    var displayTitle: String?
    var lastMicSound: TimeInterval = ProcessInfo.processInfo.systemUptime
    var diskMinutes: Int?
    var fallbackAnnounced = false
    var lifetime = BrowserCallLifetime()
    var callLifecycle = BrowserCallLifecycle()
    var modernLifecycle: Bool?
    var changingSource = false
    fileprivate var sourceObservation: BrowserSourceObservation?
    var lastNavigationAt: TimeInterval?
    var savingSinceMs: Int64?
    @MainActor var microphoneSilent: Bool {
        snapshot.me && !input.failedSides.contains(.me) && ProcessInfo.processInfo.systemUptime-lastMicSound >= 20
    }
    var elapsedMs: Int64 {
        if let savingSinceMs { return savingSinceMs }
        return Int64(max(0,ProcessInfo.processInfo.systemUptime-originUptime)*1000)
    }
}
private final class CaptureFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var moving = false
    let locationFile: URL, defaultRoot: URL
    init(file: URL, root: URL) { locationFile = file; defaultRoot = root }
    func close() { lock.lock(); closed = true; lock.unlock() }
    func setMoving(_ moving: Bool) { lock.withLock { self.moving = moving } }
    func canStart() -> Bool {
        guard lock.withLock({ !closed && !moving }) else { return false }
        return (try? LibraryRouting.withRecordingAccess(file:locationFile,defaultRoot:defaultRoot) { _,_ in true }) == true
    }
    func create(title: String, microphone: Bool, browser: Bool = true, changed: @escaping @Sendable (OwnedCaptureSnapshot) -> Void) throws -> OwnedBrowserCapture {
        guard lock.withLock({ !closed && !moving }) else { throw BrowserIPCError.closed }
        return try LibraryRouting.withRecordingAccess(file:locationFile,defaultRoot:defaultRoot) { destination,access in
            guard lock.withLock({ !closed && !moving }) else { throw BrowserIPCError.closed }
            let id = UUID()
            CaptureActivityStore.shared.set(id,.preparing)
            do {
                let owner = try OwnedBrowserCapture(parent:destination,title:title,microphone:microphone,browser:browser,id:id,managedBrowser:browser,changed:{ [access] snapshot in
                    withExtendedLifetime(access) { changed(snapshot) }
                })
                do { try MeetingMetadataWriter(directory:owner.snapshot.directory,id:id).createIfNeeded() }
                catch { try? FileManager.default.removeItem(at:owner.snapshot.directory); throw error }
                return owner
            } catch { CaptureActivityStore.shared.set(id,nil); throw error }
        }
    }
}

/// One management service, many independent file/input owners. The service's
/// tab IDs/paths are never accepted as a filesystem destination or identity.
@MainActor @Observable final class CaptureCollection {
    static let shared = CaptureCollection()
    private(set) var peers: [BrowserControlPeerSnapshot] = []
    private(set) var captures: [UUID:LiveCapture] = [:]
    private(set) var activity: [UUID:CaptureActivity] = [:]
    private var requestingRecord = false
    var starting: Bool { requestingRecord || preparingFiles > 0 || activity.values.contains(.preparing) }
    private(set) var available = false
    private(set) var autoRecord = RecordingPreferences.defaults.bool(forKey:"CassiniAutoRecord")
    private(set) var recordFailed = false
    private(set) var diskStopped = false
    private(set) var failedMeetings: [BrowserMeetingKey:String] = [:]
    @ObservationIgnored private var manualIssued = false
    @ObservationIgnored private var browserStopSent: [UUID:BrowserMeetingKey] = [:]
    @ObservationIgnored private var browserStopReasons: [UUID:CaptureEndReason] = [:]
    @ObservationIgnored private var manualPending: Set<BrowserMeetingKey> = []
    @ObservationIgnored private var manualCompleted: Set<BrowserMeetingKey> = []
    @ObservationIgnored private var manualSucceeded: Set<BrowserMeetingKey> = []
    @ObservationIgnored private var microphones: [BrowserMeetingKey:Bool] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var shuttingDown = false
    @ObservationIgnored private var pendingAuto: Set<BrowserMeetingKey> = []
    @ObservationIgnored private var announced: Set<UUID> = []
    @ObservationIgnored private var stopping: [UUID:Task<Void,Never>] = [:]
    @ObservationIgnored private var settling: [UUID:Task<Void,Never>] = [:]
    @ObservationIgnored private let diskWatch = CaptureDiskWatch()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var recordGeneration = 0
    @ObservationIgnored private var autoGeneration = 0
    @ObservationIgnored private var attemptHasAudio = false
    @ObservationIgnored private var settingsRetry: Set<CaptureSide> = []
    private var preparingFiles = 0
    @ObservationIgnored var onAutomaticStart: ((UUID) -> Void)?
    @ObservationIgnored var onFallback: ((UUID) -> Void)?
    @ObservationIgnored private lazy var files = CaptureFiles(file:LibraryLaunchContext.locationFile,root:RecordingFixture.root ?? LibraryLocation.standardRoot)
    @ObservationIgnored private lazy var broker = BrowserAudioBroker(make:{ [weak self,files] title,mic in
        try files.create(title:title,microphone:mic) { [weak self] snapshot in DispatchQueue.main.async { self?.changed(snapshot) } }
    },created:{ [weak self] owner,info in Task { @MainActor in await self?.created(owner,info:info) } },stopNative:{ [weak self] owner,reply in
        Task { @MainActor in
            guard let self, let value = self.captures[owner.snapshot.manifest.id] else { reply(nil); return }
            do { try await value.input.stop(); reply(nil) } catch { reply(error.localizedDescription) }
        }
    })
    @ObservationIgnored private lazy var service = BrowserControlService(changed:{ [weak self] peers in
        DispatchQueue.main.async { self?.replacePeers(peers) }
    },completed:{ [weak self] outcome,automatic in
        DispatchQueue.main.async { self?.completed(outcome,automatic:automatic) }
    },audio:broker,canStart:{ [files] in files.canStart() })
    var connected: Bool { peers.contains { $0.reconciled } }
    var hasCalls: Bool { peers.contains { $0.reconciled && $0.independent && $0.meetings.contains { $0.sourceCount > 0 } } }
    var isRecording: Bool { captures.values.contains { $0.snapshot.phase == .recording && $0.savingSinceMs == nil } }
    var isSaving: Bool { captures.values.contains { $0.snapshot.phase == .saving || $0.savingSinceMs != nil } || !stopping.isEmpty || !settling.isEmpty }
    var first: LiveCapture? { captures.values.filter { $0.snapshot.phase == .recording && $0.savingSinceMs == nil }.min { $0.originUptime < $1.originUptime } }
    func start(root: URL? = nil) async {
        guard !started, !shuttingDown else { return }
        #if DEBUG
        guard !LibraryLaunchContext.current.screenshot, !RecordingFixture.enabled || CaptureFixture.enabled else { return }
        #endif
        started = true
        let service = self.service, root = root ?? BrowserPipeServer.standardRoot
        do { try await Task.detached { try service.start(root:root) }.value; available = true }
        catch { started = false; return }
        guard !shuttingDown else { service.stop(); available = false; return }
        service.setAutoRecord(autoRecord,microphone:true)
        startPolling()
    }
    private func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
    }
    func record() async throws {
        guard !shuttingDown, !starting else { return }
        LibraryLocationModel.shared.reload()
        guard LibraryLocationModel.shared.available,!LibraryMoveCoordinator.shared.busy else { throw BrowserIPCError.unavailable }
        requestingRecord = true
        SessionPlaybackController.stopAll(); PlayerController.pauseActive()
        recordFailed = false
        diskStopped = false; RecordingDiskWatch.clear()
        failedMeetings = [:]; manualIssued = false; manualPending = []; manualCompleted = []; manualSucceeded = []; attemptHasAudio = false
        recordGeneration += 1
        let generation = recordGeneration
        do {
            guard !shuttingDown, generation == recordGeneration else { requestingRecord = false; return }
            if available && hasCalls {
                service.recordAll(microphone:true,choices:microphones) { [weak self] requests in
                    DispatchQueue.main.async {
                        guard let self, self.recordGeneration == generation else { return }
                        self.manualPending = Set(requests.map(\.key)).subtracting(self.manualCompleted)
                        self.manualIssued = true; self.finishAttempt()
                        if requests.isEmpty { self.recordFailed = !self.isRecording }
                    }
                }
            }
            else {
                preparingFiles += 1
                defer { preparingFiles -= 1 }
                let files = self.files, title = UXText.text("library.untitled")
                let origin = Int(Date().timeIntervalSince1970*1000)
                let owner = try await Task.detached { [weak self] in
                    try files.create(title:title,microphone:true,browser:false) { [weak self] snapshot in DispatchQueue.main.async { self?.changed(snapshot) } }
                }.value
                guard !shuttingDown, generation == recordGeneration else { try await owner.finish(); settle(owner.snapshot); requestingRecord = false; return }
                do { try broker.ownNative(owner) }
                catch { try? await owner.finish(); settle(owner.snapshot); throw error }
                await created(owner,info:.init(captureID:"native-" + owner.snapshot.manifest.id.uuidString,timelineOriginMs:origin,microphone:true))
                requestingRecord = false
            }
        } catch { requestingRecord = false; recordFailed = true; throw error }
    }
    func setAutoRecord(_ enabled: Bool) async throws {
        autoGeneration += 1
        let generation = autoGeneration
        autoRecord = enabled; RecordingPreferences.defaults.set(enabled,forKey:"CassiniAutoRecord")
        service.setAutoRecord(enabled,microphone:true)
        if enabled { await CaptureNotifications.shared.authorize() }
        guard !shuttingDown, generation == autoGeneration else { return }
        if enabled { await authorizeMicrophone() }
    }
    func stop(_ id: UUID, reason: CaptureEndReason = .user, userInitiated explicitIntent: Bool? = nil) {
        guard let value = captures[id] else { return }
        let userInitiated = explicitIntent ?? (reason == .user || reason == .appQuit)
        value.owner.requestEnd(reason,atMs:Double(value.elapsedMs))
        value.input.cancelSourceChange()
        // A user's Stop still matters when an automatic Stop is already draining
        // or the control peer has gone away. Preserve the original capture URL.
        if userInitiated { service.rememberUserStop(captureID:value.captureID,key:value.key) }
        guard stopping[id] == nil else { return }
        value.spectrogram?.stop(atMs:Double(value.elapsedMs))
        browserStopReasons[id] = reason
        MeetingNavigation.shared.captureBeganSaving(at:value.snapshot.directory)
        captures[id]?.savingSinceMs = value.elapsedMs
        activity[id] = .saving
        if CaptureActivityStore.shared.snapshot()[id] != .preparing { CaptureActivityStore.shared.set(id,.saving) }
        requestBrowserStop(id)
        let task = Task { [weak self] in
            // Native inputs stop at the user's request, independently of a
            // delayed page flush. Broker finalization reuses this same drain.
            try? await value.input.stop()
            // The browser Stop flushes its pending PCM and normally finalizes
            // this owner itself. Keep admission open until that tail arrives.
            let deadline = ProcessInfo.processInfo.systemUptime + (value.owner.snapshot.transportAlive ? 12 : 0)
            while value.owner.snapshot.phase == .recording && ProcessInfo.processInfo.systemUptime < deadline {
                do { try await Task.sleep(for:.milliseconds(50)) } catch { break }
            }
            if let self, value.owner.snapshot.phase != .saved {
                try? await self.broker.finish(value.owner,problem:value.owner.snapshot.browserAlive ? "browser-tail-not-flushed" : nil)
            }
            self?.stopping.removeValue(forKey:id)
        }
        stopping[id] = task
    }
    private func requestBrowserStop(_ id: UUID) {
        guard let value = captures[id], value.snapshot.manifest.source == "chromium", value.savingSinceMs != nil,
              let key = key(for:value.captureID),
              peers.contains(where:{ $0.id == key.peer && $0.reconciled }),
              browserStopSent[id] != key else { return }
        browserStopSent[id] = key
        service.stopMeeting(key,captureID:value.captureID,userInitiated:false,reason:browserStopReasons[id] ?? .user)
    }
    func stopAll(reason: CaptureEndReason = .user) {
        recordGeneration += 1; requestingRecord = false
        for value in captures.values { value.owner.requestEnd(reason,atMs:Double(value.elapsedMs)) }
        service.stopRecordings(reason:reason)
        for id in Array(captures.keys) { stop(id,reason:reason) }
    }
    func stopAndWait(reason: CaptureEndReason = .user) async {
        stopAll(reason:reason)
        while !stopping.isEmpty { for task in Array(stopping.values) { await task.value } }
        while preparingFiles > 0 { try? await Task.sleep(for:.milliseconds(10)) }
        settleSaved()
        for task in Array(settling.values) { await task.value }
    }
    func beginShutdown() { shuttingDown = true; files.close(); broker.closeAdmission(); service.setAutoRecord(false,microphone:true); stopAll(reason:.appQuit) }
    func shutdown() async {
        beginShutdown(); await stopAndWait(reason:.appQuit)
        let finalized = await broker.finishAll(reason:.appQuit)
        for snapshot in finalized { settle(snapshot) }
        settleSaved()
        for task in Array(settling.values) { await task.value }
        timer?.invalidate(); timer = nil
        diskWatch.stop()
        service.stop(); available = false; started = false
    }
    func select(_ id: UUID, me: Bool, others: Bool) async throws {
        guard let value = captures[id] else { return }
        let resumingMe = me && (!value.snapshot.me || value.input.failedSides.contains(.me))
        try await value.input.select(me:me,others:others,atMs:Double(value.elapsedMs))
        if let key = value.key { microphones[key] = me }
        if resumingMe { captures[id]?.lastMicSound = ProcessInfo.processInfo.systemUptime }
    }
    func setLibraryMoveBlocked(_ blocked: Bool) {
        files.setMoving(blocked)
        // Reconcile auto-record after a move without changing its preference.
        if !blocked, started { service.setAutoRecord(autoRecord,microphone:true) }
    }
    private func created(_ owner: OwnedBrowserCapture, info: BrowserAudioStart) async {
        let snapshot = owner.snapshot, id = snapshot.manifest.id
        guard !shuttingDown, snapshot.phase == .recording else {
            try? await broker.finish(owner); settle(owner.snapshot); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let parent = snapshot.directory.deletingLastPathComponent().standardizedFileURL.path
        let context = LibraryStore.shared.context
        if !([context.root] + context.previousRoots).contains(where:{ $0.standardizedFileURL.path == parent }) { LibraryStore.shared.reloadLocation() }
        startPolling()
        let origin = max(0,min(now,now - max(0,(Date().timeIntervalSince1970*1000 - Double(info.timelineOriginMs))/1000)))
        let input = CaptureInputLifecycle(capture:owner,originHostTime:AVAudioTime.hostTime(forSeconds:origin),microphone:{ Self.nativeInput(.me) },system:{ Self.nativeInput(.others) },failure:{ [weak self] _ in
            Task { @MainActor in
                guard let self, let value = self.captures[id] else { return }
                self.captures[id]?.sourceProblem = true
                if value.input.failedSides.contains(.others) { try? await value.owner.systemUnavailable(atMs:Double(value.elapsedMs)) }
                let source = value.owner.snapshot
                if !source.browserAlive && !value.input.hasRunningInputs && !(source.managedBrowser && source.others) { self.stop(id,reason:.error) }
            }
        })
        let meetingKey = key(for:info.captureID)
        let modern = peers.first { $0.id == meetingKey?.peer }?.supportsPageState
        let spectrogram = RecordingSpectrogram.enabled ? RecordingSpectrogram(originUptime:origin,observers:owner.pcmObservers,me:snapshot.me,others:snapshot.others) : nil
        spectrogram?.update(events:snapshot.manifest.events ?? [])
        captures[id] = .init(owner:owner,input:input,captureID:info.captureID,originUptime:origin,spectrogram:spectrogram,snapshot:snapshot,key:meetingKey,modernLifecycle:modern)
        if let modern { try? await owner.manageBrowserLifecycle(modern) }
        activity[id] = snapshot.manifest.tracks.contains { $0.frames > 0 } ? .recording : .preparing
        CaptureActivityStore.shared.set(id,activity[id])
        diskWatch.start(folders:{ [weak self] in
            self?.captures.mapValues { value in
                (value.snapshot.directory,value.snapshot.manifest.tracks.filter { $0.ended != true }.reduce(0) { $0 + Double($1.sampleRate*$1.channels*2) })
            } ?? [:]
        },update:{ [weak self] ids,budget in self?.applyDiskBudget(ids,budget) })
        LibraryStore.shared.refresh(affected:snapshot.directory)
        announce()
        do { try await input.start() }
        catch { captures[id]?.sourceProblem = true }
        if snapshot.manifest.source == "macos", !input.hasRunningInputs { try? await broker.finish(owner) }
    }
    private func changed(_ snapshot: OwnedCaptureSnapshot) {
        let id = snapshot.manifest.id
        guard captures[id] != nil else { if snapshot.phase == .saved { settle(snapshot) }; return }
        captures[id]?.snapshot = snapshot
        captures[id]?.spectrogram?.update(events:snapshot.manifest.events ?? [])
        if snapshot.phase != .recording, let value = captures[id] { value.spectrogram?.stop(atMs:Double(value.elapsedMs)) }
        if snapshot.phase == .saving { MeetingNavigation.shared.captureBeganSaving(at:snapshot.directory) }
        if snapshot.phase == .saved {
            settle(snapshot)
            return
        }
        if snapshot.manifest.tracks.contains(where:{ $0.frames > 0 }) {
            attemptHasAudio = true; recordFailed = false
            let phase: CaptureActivity = snapshot.phase == .saving || captures[id]?.savingSinceMs != nil ? .saving : .recording
            if activity[id] != phase { activity[id] = phase; CaptureActivityStore.shared.set(id,phase) }
        }
        if !snapshot.managedBrowser, snapshot.needsSystem, captures[id]?.savingSinceMs == nil, !captures[id]!.input.failedSides.contains(.others) {
            let input = captures[id]!.input
            Task { [weak self] in do { try await input.update() } catch { self?.captures[id]?.sourceProblem = true } }
        }
        if snapshot.isSystemFallback, captures[id]?.savingSinceMs == nil, captures[id]?.fallbackAnnounced == false {
            captures[id]?.fallbackAnnounced = true; onFallback?(id)
        }
    }
    private func settle(_ snapshot: OwnedCaptureSnapshot) {
        let id = snapshot.manifest.id
        guard snapshot.phase == .saved, captures[id] != nil || CaptureActivityStore.shared.snapshot()[id] != nil else { return }
        if !snapshot.manifest.tracks.contains(where:{ $0.frames > 0 }), CaptureActivityStore.shared.snapshot()[id] == .preparing {
                guard settling[id] == nil else { return }
                settling[id] = Task { [weak self] in
                    let removed = await Task.detached { Self.discardBlank(snapshot) }.value
                    guard let self else { return }
                    self.retire(snapshot)
                    if removed && !self.isRecording && !self.attemptHasAudio { self.recordFailed = true }
                    self.settling.removeValue(forKey:id)
                }
                return
        }
        retire(snapshot)
    }
    private func retire(_ snapshot: OwnedCaptureSnapshot) {
            let id = snapshot.manifest.id
            if let value = captures[id] { value.spectrogram?.stop(atMs:Double(value.elapsedMs)) }
            captures.removeValue(forKey:id); announced.remove(id); browserStopSent.removeValue(forKey:id); browserStopReasons.removeValue(forKey:id)
            activity.removeValue(forKey:id)
            CaptureActivityStore.shared.set(id,nil)
            LibraryStore.shared.refresh(affected:snapshot.directory)
    }
    private func settleSaved() {
        for value in Array(captures.values) where value.owner.snapshot.phase == .saved { changed(value.owner.snapshot) }
    }
    nonisolated private static func discardBlank(_ snapshot: OwnedCaptureSnapshot) -> Bool {
        let folder = snapshot.directory, fm = FileManager.default
        guard folder.lastPathComponent == "Recording-" + snapshot.manifest.id.uuidString.lowercased(),
              snapshot.manifest.tracks.allSatisfy({ $0.frames == 0 }),
              let names = try? fm.contentsOfDirectory(atPath:folder.path),
              Set(names).isSubset(of:Set(["session.json","meeting.json"] + snapshot.manifest.tracks.map(\.file))),
              let data = try? Data(contentsOf:folder.appendingPathComponent("meeting.json")), data.count <= 1_048_576,
              let metadata = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              (metadata["notes"] as? [Any])?.isEmpty == true, metadata["titleSource"] as? String == "meeting-window",
              snapshot.manifest.tracks.allSatisfy({ (try? fm.attributesOfItem(atPath:folder.appendingPathComponent($0.file).path)[.size] as? NSNumber)?.intValue == 44 }) else { return false }
        do { try fm.removeItem(at:folder); return true } catch { return false }
    }
    private func replacePeers(_ peers: [BrowserControlPeerSnapshot]) {
        self.peers = peers
        if peers.contains(where:{ $0.reconciled }) { CompanionSetup.shared.didConnect() }
        let meetings = Set(peers.flatMap(\.meetings).filter { $0.sourceCount > 0 }.map(\.key))
        failedMeetings = failedMeetings.filter { meetings.contains($0.key) }
        microphones = microphones.filter { meetings.contains($0.key) }
        for id in Array(captures.keys) {
            if let value = captures[id] {
                let key = key(for:value.captureID) ?? value.key; captures[id]?.key = key
                if let key { microphones[key] = value.owner.snapshot.me }
                if value.modernLifecycle == nil, let peer = peers.first(where:{ $0.id == key?.peer }) {
                    captures[id]?.modernLifecycle = peer.supportsPageState
                    Task { try? await value.owner.manageBrowserLifecycle(peer.supportsPageState); try? await value.input.update() }
                }
            }
        }
        for id in captures.keys { requestBrowserStop(id) }
        announce()
        poll() // Invalidate pending source work immediately on control updates.
    }
    private func key(for captureID: String) -> BrowserMeetingKey? {
        peers.flatMap { $0.captures + $0.interrupted }.first { $0.captureID.map { Data($0.utf8) == Data(captureID.utf8) } == true }?.key
    }
    private func completed(_ outcome: BrowserControlOutcome, automatic: Bool) {
        if outcome.action == .start {
            if outcome.ok { failedMeetings.removeValue(forKey:outcome.key) }
            else { failedMeetings[outcome.key] = peers.flatMap(\.meetings).first { $0.key == outcome.key }?.title ?? UXText.text("library.untitled") }
            if !automatic {
                if !manualIssued || manualPending.contains(outcome.key) {
                    manualCompleted.insert(outcome.key); manualPending.remove(outcome.key)
                    if outcome.ok { manualSucceeded.insert(outcome.key) }
                    finishAttempt()
                }
            } else if !outcome.ok { recordFailed = !isRecording }
        }
        if automatic && outcome.action == .start && outcome.ok { pendingAuto.insert(outcome.key); announce() }
    }
    private func finishAttempt() {
        guard manualIssued, manualPending.isEmpty else { return }
        requestingRecord = false
        recordFailed = manualSucceeded.isEmpty && !isRecording && !failedMeetings.isEmpty
    }
    func retry(_ key: BrowserMeetingKey) {
        guard !shuttingDown,!starting,failedMeetings[key] != nil else { return }
        recordFailed = false
        requestingRecord = true; manualIssued = true
        manualPending = [key]; manualCompleted = []; manualSucceeded = []
        attemptHasAudio = isRecording
        service.recordMeeting(key,microphone:microphones[key] ?? true)
    }
    private func announce() {
        for (id,value) in captures {
            if let key = value.key, pendingAuto.contains(key), !announced.contains(id) {
                pendingAuto.remove(key); announced.insert(id); onAutomaticStart?(id)
            }
        }
    }
    private func poll(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        for id in Array(captures.keys) {
            guard let value = captures[id] else { continue }
            let status = value.input.status()
            captures[id]?.levels = status.mapValues { $0.levels.values.max() ?? 0 }
            if value.snapshot.browserAlive && value.snapshot.others {
                captures[id]?.levels[.others] = ProcessInfo.processInfo.systemUptime - value.snapshot.levelTimestamp <= 1 ? value.snapshot.browserLevel : 0
            }
            if (captures[id]?.levels[.me] ?? 0) >= 0.01 { captures[id]?.lastMicSound = ProcessInfo.processInfo.systemUptime }
            if value.snapshot.manifest.source == "chromium", value.savingSinceMs == nil {
                let peer = peers.first { $0.id == value.key?.peer && $0.reconciled }
                let count = peer?.meetings.first { $0.key == value.key }?.sourceCount
                // Native Start can precede the control status that binds this
                // capture to its peer. Absence during that handshake is not loss.
                let initial = value.owner.snapshot
                if value.modernLifecycle == nil && initial.browserAlive && initial.transportAlive { continue }
                if value.modernLifecycle == false {
                    if captures[id]?.lifetime.shouldStop(now:now,browserAlive:value.snapshot.browserAlive,
                        lostAt:value.snapshot.browserLostUptime,reachable:peer != nil,sourceCount:count) == true {
                        stop(id,reason:peer != nil && count == 0 ? .callEnded : .pageGone)
                    }
                    continue
                }
                let reported = (peer?.captures ?? []) + (peer?.interrupted ?? [])
                let status = reported.first { $0.captureID.map { Data($0.utf8) == Data(value.captureID.utf8) } == true }
                let meeting = peer?.meetings.first { $0.key == value.key }
                let pages: [(BrowserCallLifecycle.Page,TimeInterval?)] = [
                    status?.pageState.map { ($0,status?.pageStateAt) },
                    meeting?.pageState.map { ($0,meeting?.pageStateAt) }
                ].compactMap { $0 }
                let page = pages.first { $0.0 == .closed } ?? pages.max { ($0.1 ?? 0) < ($1.1 ?? 0) }
                let source = value.owner.snapshot
                // Fresh PCM on the original owned transport is stronger than
                // a brief gap in management discovery. It never overrides an
                // explicit navigating/closed report or a dead audio transport.
                let fresh = source.browserAlive && source.transportAlive && now-source.levelTimestamp <= 1
                let reportedPage = page?.0 ?? (fresh ? .present : nil)
                // A reconnect's status can precede its first meeting inventory.
                // Present alone does not confirm that the call has zero sources.
                let observedPage = reportedPage == .present && count == nil && !fresh ? nil : reportedPage
                let observation = BrowserSourceObservation(page:observedPage,observedAt:page?.1,active:(count ?? (fresh ? 1 : 0)) > 0)
                if observation != value.sourceObservation {
                    value.input.cancelSourceChange()
                    captures[id]?.sourceObservation = observation
                }
                let returnFloor = page?.1.map { max(0,$0-value.originUptime)*1000 }
                let ready = source.restoreReady && source.browserReturnPCMAt.map { $0 >= (returnFloor ?? 0) } == true
                let action = captures[id]?.callLifecycle.step(now:now,page:observedPage,sourceCount:count ?? (fresh ? 1 : 0),
                    transportAlive:source.transportAlive,usingSystem:source.usingSystem,others:source.others,
                    restoreReady:ready,pageObservedAt:page?.1,lostAt:source.browserLostUptime)
                if case .stop(let reason) = action, let end = CaptureEndReason(rawValue:reason.rawValue) {
                    value.owner.requestEnd(end,atMs:max(0,now-value.originUptime)*1000)
                    stop(id,reason:end); continue
                }
                guard !value.changingSource else { continue }
                let navigation = observedPage == .navigating && page?.1 != value.lastNavigationAt
                let lost = source.browserAlive && observedPage != .present || navigation
                if navigation { captures[id]?.lastNavigationAt = page?.1 }
                let fallback = action == .fallback && !value.input.failedSides.contains(.others)
                let returned = observedPage == .present && (count ?? 0) > 0 && ready && source.others
                guard lost || fallback || returned else { continue }
                captures[id]?.changingSource = true
                let atMs = max(0,now-value.originUptime)*1000
                let revision = value.input.sourceRevision
                Task { [weak self] in
                    do {
                        if lost {
                            let lossAt = max(0,(page?.1 ?? now)-value.originUptime)*1000
                            try await value.input.observeBrowserLoss(atMs:lossAt,transportAlive:source.transportAlive,revision:revision)
                        }
                        if fallback { try await value.input.fallback(revision:revision) }
                        if returned { try await value.input.restoreBrowser(atMs:atMs,notBeforeMs:returnFloor,revision:revision) }
                        if returned { self?.captures[id]?.sourceProblem = false }
                    } catch is CancellationError {
                        // A newer page observation owns the next source decision.
                    } catch {
                        if self?.captures[id]?.savingSinceMs == nil { self?.captures[id]?.sourceProblem = true }
                    }
                    self?.captures[id]?.changingSource = false
                }
            }
        }
    }
    func title(_ id: UUID, _ text: String) { captures[id]?.displayTitle = text }
    private func applyDiskBudget(_ ids: [UUID], _ budget: DiskBudget) {
        for id in ids where captures[id] != nil {
            captures[id]?.diskMinutes = budget.minutesLeft.flatMap { $0 < 30 ? $0 : nil }
            if budget.shouldStop { diskStopped = true; stop(id,reason:.disk) }
        }
        let line = diskStopped ? UXText.text("errors.diskStopped.line") : captures.values.compactMap(\.diskMinutes).min().map { UXText.text("errors.diskLow.line",["n":String($0)]) }
        RecordingDiskWatch.updateWarning(line)
    }
    #if DEBUG
    func pollLifetimeForTesting(at now: TimeInterval) {
        guard CaptureFixture.enabled else { return }; poll(at:now)
    }
    func applyDiskBudgetForTesting(_ budget: DiskBudget) {
        guard CaptureFixture.enabled else { return }; applyDiskBudget(Array(captures.keys),budget)
    }
    #endif
    func settingsWereOpened(_ side: CaptureSide) { settingsRetry.insert(side) }
    func retryFromSettings() {
        let sides = settingsRetry; settingsRetry = []
        for value in captures.values where value.savingSinceMs == nil {
            for side in sides where value.input.failedSides.contains(side) && (side != .me || CaptureSettings.microphoneAllowed) {
                Task { try? await value.input.retry(side) }
            }
        }
    }
    private static func nativeInput(_ side: CaptureSide) -> any CaptureInput {
        #if DEBUG
        if CaptureFixture.enabled { return CaptureFixtureInput(side) }
        #endif
        return side == .me ? MeetingMicrophoneInput() : MeetingSystemInput()
    }
    private func authorizeMicrophone() async {
        #if DEBUG
        if CaptureFixture.enabled { return }
        #endif
        try? await NativeRecordingInputs().authorize()
    }
}
