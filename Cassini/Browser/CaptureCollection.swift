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
    /// D52 M3: every browser recording follows its call by this policy (0.2.12+ only, D51).
    var callPolicy = BrowserCallPolicy()
    /// D52.1 R67: this native stand-in already asked one call to join (never retried).
    var standInAttempt = BrowserStandInAttempt()
    var stoppingReason: CaptureEndReason?
    var stoppingUserInitiated = false
    /// D52.5: the call this recording belongs to. After its audio transport closed, the
    /// recording finds that call by (tabId, callGeneration) on any control peer.
    var callGeneration: String?
    /// Its control peer has been seen. Until then a live browser capture is not judged:
    /// a native Start can precede the control status that binds it to its peer.
    var peerKnown = false
    var changingSource = false
    fileprivate var sourceObservation: BrowserSourceObservation?
    var lastNavigationAt: TimeInterval?
    var savingSinceMs: Int64?
    var inputsAdmitted = false
    var signalReservation: UUID? = nil
    var admissionCancelled = false
    #if DEBUG
    var fixtureMicrophoneUptime: TimeInterval?
    #endif
    var microphoneUptime: TimeInterval {
        #if DEBUG
        if let fixtureMicrophoneUptime { return fixtureMicrophoneUptime }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }
    @MainActor var microphoneSilent: Bool {
        snapshot.me && !input.failedSides.contains(.me) && microphoneUptime-lastMicSound >= 20
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
    func canStartSignal() -> Bool {
        guard lock.withLock({ !closed && !moving }) else { return false }
        return (try? LibraryRouting.withRecordingAccess(file:locationFile,defaultRoot:defaultRoot) { destination,_ in
            RecordingDiskWatch.inspect(destination,rate:0)?.shouldStop == false
        }) == true
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
    var starting: Bool { requestingRecord || !pendingSignals.isEmpty || preparingFiles > 0 || activity.values.contains(.preparing) }
    private(set) var available = false
    private(set) var autoRecord = RecordingPreferences.defaults.bool(forKey:"CassiniAutoRecord")
    private(set) var recordFailed = false
    private(set) var diskStopped = false
    private(set) var failedMeetings: [BrowserMeetingKey:String] = [:]
    /// D58: the refusals of the current Record attempt when nothing opened (banner only), and
    /// each failed meeting's browser refusal, for the banner captions.
    private(set) var attemptRefusals: [CaptureRefusal] = []
    private(set) var meetingRefusals: [BrowserMeetingKey:CaptureRefusal] = [:]
    @ObservationIgnored private var manualIssued = false
    @ObservationIgnored private var manualPending: Set<BrowserMeetingKey> = []
    @ObservationIgnored private var manualCompleted: Set<BrowserMeetingKey> = []
    @ObservationIgnored private var manualSucceeded: Set<BrowserMeetingKey> = []
    @ObservationIgnored private var microphones: [BrowserMeetingKey:Bool] = [:]
    @ObservationIgnored private var pendingSignals: Set<UUID> = []
    @ObservationIgnored private var signalCaptures: [UUID:UUID] = [:]
    @ObservationIgnored private var signalStartups: [UUID:BrowserSignalStartup] = [:]
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
    /// D52.5: the only lost-call state. This collection feeds each recording's binding; the
    /// broker feeds transport loss and resume; the service reads it before admitting a Start.
    @ObservationIgnored private let ownership = CallOwnershipStore()
    @ObservationIgnored private let automaticAdmission = BrowserAutomaticAdmissionStore(clock:{
        #if DEBUG
        if CaptureFixture.enabled { return CaptureFixtureAdmissionClock.shared.now() }
        #endif
        return ProcessInfo.processInfo.systemUptime
    })
    @ObservationIgnored private lazy var files = CaptureFiles(file:LibraryLaunchContext.locationFile,root:RecordingFixture.root ?? LibraryLocation.standardRoot)
    @ObservationIgnored private lazy var broker = BrowserAudioBroker(make:{ [weak self,files] title,mic in
        try files.create(title:title,microphone:mic) { [weak self] snapshot in DispatchQueue.main.async { self?.changed(snapshot) } }
    },created:{ [weak self] owner,info in Task { @MainActor in await self?.created(owner,info:info) } },stopNative:{ [weak self] owner,reply in
        Task { @MainActor in
            guard let self, let value = self.captures[owner.snapshot.manifest.id] else { reply(nil); return }
            do { try await value.input.stop(); reply(nil) } catch { reply(error.localizedDescription) }
        }
    },ownership:ownership,admission:automaticAdmission)
    @ObservationIgnored private lazy var service = BrowserControlService(changed:{ [weak self] peers in
        DispatchQueue.main.async { self?.replacePeers(peers) }
    },completed:{ [weak self] outcome,automatic in
        DispatchQueue.main.async { self?.completed(outcome,automatic:automatic) }
    },audio:broker,canStart:{ [files] in files.canStart() },ownership:ownership,requireMultiStream:true,requireVerifiedAdmission:true,admission:automaticAdmission,signalAction:{ [weak self] action in
        Task { @MainActor in await self?.signalAction(action) }
    },canSignalStart:{ [files] in files.canStartSignal() })
    private func signalAction(_ action: BrowserSignalAction) async {
        switch action {
        case let .start(token,site,microphone):
            let startup = BrowserSignalStartup(); signalStartups[token] = startup
            pendingSignals.insert(token)
            preparingFiles += 1
            defer { pendingSignals.remove(token); preparingFiles -= 1 }
            let files = self.files, title = UXText.text("library.untitled")
            var made: OwnedBrowserCapture?
            do {
                guard !shuttingDown, service.signalMayOpen(token) else { throw CancellationError() }
                let owner = try await Task.detached { [weak self] in
                    let owner = try files.create(title:title,microphone:microphone,browser:false) { [weak self] snapshot in DispatchQueue.main.async { self?.changed(snapshot) } }
                    do { try CaptureRecordWriter.writeMixedRoute(site:site,directory:owner.snapshot.directory,id:owner.snapshot.manifest.id) }
                    catch { try? FileManager.default.removeItem(at:owner.snapshot.directory); CaptureActivityStore.shared.set(owner.snapshot.manifest.id,nil); throw error }
                    return owner
                }.value
                made = owner
                guard !shuttingDown, service.signalMayOpen(token) else { throw CancellationError() }
                let id = owner.snapshot.manifest.id
                signalCaptures[token] = id
                let origin = Int(Date().timeIntervalSince1970*1000)
                try broker.ownNative(owner)
                await created(owner,info:.init(captureID:"signal-"+id.uuidString,timelineOriginMs:origin,microphone:microphone),signal:token)
                let cancelled = startup.isCancelled(mayOpen:service.signalMayOpen(token),ending:service.signalEndReason(token) != nil,shuttingDown:shuttingDown)
                if !cancelled, owner.snapshot.phase == .recording, captures[id]?.savingSinceMs == nil,
                   captures[id]?.input.hasRunningInputs == true {
                    service.signalStarted(token)
                    onAutomaticStart?(id)
                } else if let value = captures[id], stopping[id] == nil, value.savingSinceMs == nil {
                    stop(id,reason:cancelled || value.admissionCancelled ? service.signalEndReason(token) ?? .pageGone : .error,userInitiated:false)
                } else if stopping[id] == nil {
                    releaseSignal(token,failed:!cancelled)
                }
            } catch {
                if error is CancellationError { startup.cancel() }
                if let made { try? await made.finish(); settle(made.snapshot) }
                if made.map({ stopping[$0.snapshot.manifest.id] == nil }) ?? true {
                    releaseSignal(token,failed:!(error is CancellationError))
                }
            }
        case let .stop(token,reason):
            signalStartups[token]?.cancel()
            if let id = signalCaptures[token], captures[id] != nil {
                captures[id]?.admissionCancelled = true
                stop(id,reason:reason,userInitiated:false)
            }
            // A pending file/permission completion revalidates the reservation itself.
        }
    }
    private func releaseSignal(_ token: UUID, failed: Bool = false) {
        guard let startup = signalStartups[token],
              let failure = startup.releaseFailure(failed:failed,mayOpen:service.signalMayOpen(token),
                    ending:service.signalEndReason(token) != nil,shuttingDown:shuttingDown) else { return }
        signalStartups.removeValue(forKey:token); signalCaptures.removeValue(forKey:token)
        service.signalReleased(token,failed:failure)
    }
    private init() {
        #if DEBUG
        // Synthetic UI snapshots use the existing private fixture launch only;
        // no control service, capture owner, or production path is opened.
        if let kind = BrowserCompanionFixture.kind {
            peers = BrowserCompanionFixture.peers(kind)
        }
        #endif
    }
    /// D51: only a companion that speaks multi-stream-v1 (extension 0.2.12+) records browser calls.
    /// An older one is never asked to start: its calls record like a meeting without the companion
    /// (microphone and computer sound), and the companion state says it needs an update.
    var companionHealth: BrowserCompanionSetupHealth { .init(peers:peers) }
    var setupComplete: Bool { companionHealth.complete }
    private var reloadInFlight: Set<BrowserMeetingKey> = []
    private var reloadBaseline: [BrowserMeetingKey:UInt64] = [:]
    var reloadingTabs: Set<BrowserMeetingKey> { reloadInFlight.union(reloadBaseline.keys) }
    private(set) var reloadErrors: [BrowserMeetingKey:String] = [:]
    func reloadMeetingTab(_ key: BrowserMeetingKey) {
        #if DEBUG
        guard BrowserCompanionFixture.kind == nil else { return }
        #endif
        guard !reloadingTabs.contains(key), peers.contains(where:{ $0.id == key.peer && $0.supportsTabReadiness && $0.browserHealth?.reloadTabs.contains(where:{ $0.key == key && $0.canReload }) == true }) else { return }
        guard let peer = peers.first(where:{ $0.id == key.peer }) else { return }
        reloadInFlight.insert(key); reloadBaseline[key] = peer.healthRevision
        reloadErrors.removeValue(forKey:key); service.reloadMeetingTab(key)
    }
    var connected: Bool { peers.contains { $0.reconciled && $0.supportsMultiStream } }
    var needsUpdate: Bool { !connected && peers.contains { $0.reconciled && !$0.supportsMultiStream } }
    var hasCalls: Bool { peers.contains { $0.reconciled && $0.independent && $0.supportsMultiStream && $0.browserRecordableMeetings.contains { $0.sourceCount > 0 } } }
    var isRecording: Bool { captures.values.contains { $0.snapshot.phase == .recording && $0.savingSinceMs == nil } }
    var isSaving: Bool { captures.values.contains { $0.snapshot.phase == .saving || $0.savingSinceMs != nil } || !stopping.isEmpty || !settling.isEmpty }
    var first: LiveCapture? { captures.values.filter { $0.snapshot.phase == .recording && $0.savingSinceMs == nil }.min { $0.originUptime < $1.originUptime } }
    func start(root: URL? = nil) async {
        guard !started, !shuttingDown else { return }
        #if DEBUG
        guard BrowserCompanionFixture.kind == nil, !LibraryLaunchContext.current.screenshot, !RecordingFixture.enabled || CaptureFixture.enabled else { return }
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
        guard LibraryLocationModel.shared.available,!LibraryMoveCoordinator.shared.busy else {
            recordFailed = true
            throw BrowserIPCError.unavailable
        }
        requestingRecord = true
        SessionPlaybackController.stopAll(); PlayerController.pauseActive()
        recordFailed = false; attemptRefusals = []; meetingRefusals = [:]
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
                do { try broker.ownNative(owner,timelineOriginMs:origin,standInID:"native-" + owner.snapshot.manifest.id.uuidString) }
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
        if !enabled { service.setAutoRecord(false,microphone:true); return }
        // Microphone consent precedes automatic capture admission. Optional
        // notification consent is requested only after working inputs start.
        await authorizeMicrophone()
        guard !shuttingDown, generation == autoGeneration else { return }
        service.setAutoRecord(true,microphone:true)
    }
    func stop(_ id: UUID, reason: CaptureEndReason = .user, userInitiated explicitIntent: Bool? = nil) {
        guard let value = captures[id] else { return }
        #if DEBUG
        if CaptureFixture.enabled { CaptureFixture.stopRequests += 1 }
        #endif
        automaticAdmission.cancel(value.captureID,reason:reason)
        let userInitiated = explicitIntent ?? (reason == .user || reason == .appQuit)
        if let token = value.signalReservation { service.stopSignal(token,userInitiated:userInitiated,reason:reason) }
        captures[id]?.stoppingReason = value.stoppingReason ?? reason
        captures[id]?.stoppingUserInitiated = value.stoppingUserInitiated || userInitiated
        value.owner.requestEnd(reason,atMs:Double(value.elapsedMs))
        broker.expectResume(value.owner,callGeneration:nil) // Stop fences a pending resume.
        value.input.cancelSourceChange()
        // A user's Stop still matters when an automatic Stop is already draining
        // or the control peer has gone away. Preserve the original capture URL.
        if userInitiated { service.rememberUserStop(captureID:value.captureID,key:value.key) }
        guard stopping[id] == nil else { return }
        value.spectrogram?.stop(atMs:Double(value.elapsedMs))
        MeetingNavigation.shared.captureBeganSaving(at:value.snapshot.directory)
        captures[id]?.savingSinceMs = value.elapsedMs
        activity[id] = .saving
        if CaptureActivityStore.shared.snapshot()[id] != .preparing { CaptureActivityStore.shared.set(id,.saving) }
        if let key = value.key { service.stopMeeting(key,captureID:value.captureID,userInitiated:false,reason:reason) }
        // The release follows the Stop memory and the Stop on the control queue (see feedOwnership).
        feedOwnership(id)
        let task = Task { [weak self] in
            // Native inputs stop at the user's request, independently of a
            // delayed page flush. Broker finalization reuses this same drain.
            try? await value.input.stop()
            // The browser Stop flushes its pending PCM and normally finalizes
            // this owner itself. Keep admission open until that tail arrives.
            let deadline = ProcessInfo.processInfo.systemUptime + (value.owner.snapshot.transportAlive && value.key != nil ? 12 : 0)
            while value.owner.snapshot.phase == .recording && ProcessInfo.processInfo.systemUptime < deadline {
                do { try await Task.sleep(for:.milliseconds(50)) } catch { break }
            }
            if let self, value.owner.snapshot.phase != .saved {
                try? await self.broker.finish(value.owner,problem:value.owner.snapshot.browserAlive ? "browser-tail-not-flushed" : nil)
            }
            if let token = value.signalReservation {
                self?.releaseSignal(token)
            }
            self?.stopping.removeValue(forKey:id)
        }
        stopping[id] = task
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
    /// Returns the sides whose turn-on was refused (D58), with their codes; their selection
    /// is unchanged and each attempt adds its own refusal to the recording.
    @discardableResult
    func select(_ id: UUID, me: Bool, others: Bool) async throws -> [CaptureSide:String] {
        guard let value = captures[id] else { return [:] }
        let resumingMe = me && (!value.snapshot.me || value.input.failedSides.contains(.me))
        let refused = try await value.input.select(me:me,others:others)
        let selectedMe = refused[.me] == nil ? me : value.snapshot.me
        if let key = value.key { microphones[key] = selectedMe }
        if resumingMe, refused[.me] == nil { captures[id]?.lastMicSound = ProcessInfo.processInfo.systemUptime }
        return refused
    }
    func setLibraryMoveBlocked(_ blocked: Bool) {
        files.setMoving(blocked)
        // Reconcile auto-record after a move without changing its preference.
        if !blocked, started { service.setAutoRecord(autoRecord,microphone:true) }
    }
    private func created(_ owner: OwnedBrowserCapture, info: BrowserAudioStart, signal: UUID? = nil) async {
        let snapshot = owner.snapshot, id = snapshot.manifest.id
        #if DEBUG
        defer { if CaptureFixture.enabled { CaptureFixture.createdFinished?(id,captures[id]?.sourceProblem ?? false,captures[id]?.inputsAdmitted ?? false) } }
        #endif
        guard !shuttingDown, snapshot.phase == .recording, info.inputGate?.permits != false else {
            automaticAdmission.retire(info.captureID)
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
        },refused:{ [weak self] _,_ in
            // D58: a native Record where every requested side was refused records nothing:
            // it is finished and its blank folder discarded, and the banner shows the refusals.
            guard let self, let value = self.captures[id], value.owner.snapshot.manifest.source == "macos",
                  !value.input.hasRunningInputs, value.input.openedSides.isEmpty else { return }
            Task { try? await self.broker.finish(value.owner) }
        },admission:{ [weak self] in
            if let gate = info.inputGate { return gate.permits }
            guard let signal else { return true }
            return self?.service.signalMayOpen(signal) == true
        },inputGate:signal.flatMap { service.signalInputGate($0) } ?? info.inputGate)
        let meetingKey = key(for:info.captureID)
        let spectrogram = RecordingSpectrogram.enabled ? RecordingSpectrogram(originUptime:origin,observers:owner.pcmObservers,me:snapshot.me,others:snapshot.others) : nil
        spectrogram?.update(events:snapshot.manifest.events ?? [])
        captures[id] = .init(owner:owner,input:input,captureID:info.captureID,originUptime:origin,spectrogram:spectrogram,snapshot:snapshot,key:meetingKey,
                             peerKnown:peers.contains { $0.id == meetingKey?.peer })
        captures[id]?.signalReservation = signal
        // The call this recording belongs to, as the Start named it (the broker recorded it first).
        if let generation = info.callGeneration ?? ownership.snapshot.binding(id)?.callGeneration {
            captures[id]?.callGeneration = generation; captures[id]?.callPolicy.callGeneration = generation
        }
        feedOwnership(id)
        activity[id] = snapshot.manifest.tracks.contains { $0.frames > 0 } ? .recording : .preparing
        CaptureActivityStore.shared.set(id,activity[id])
        diskWatch.start(folders:{ [weak self] in
            self?.captures.mapValues { value in
                (value.snapshot.directory,value.snapshot.manifest.tracks.filter { $0.ended != true }.reduce(0) { $0 + Double($1.sampleRate*$1.channels*2) })
            } ?? [:]
        },update:{ [weak self] ids,budget in self?.applyDiskBudget(ids,budget) })
        LibraryStore.shared.refresh(affected:snapshot.directory)
        do { try await input.start() }
        catch {
            if let signal, error is CancellationError {
                captures[id]?.admissionCancelled = true
                signalStartups[signal]?.cancel()
                owner.requestEnd(service.signalEndReason(signal) ?? .pageGone,atMs:Double(captures[id]?.elapsedMs ?? 0))
            } else if error is CancellationError, info.inputGate != nil {
                captures[id]?.admissionCancelled = true
                stop(id,reason:automaticAdmission.endReason(info.captureID) ?? .pageGone,userInitiated:false)
                return
            } else { captures[id]?.sourceProblem = true }
        }
        guard info.inputGate?.permits != false else {
            captures[id]?.admissionCancelled = true
            stop(id,reason:automaticAdmission.endReason(info.captureID) ?? .pageGone,userInitiated:false)
            return
        }
        if snapshot.manifest.source == "macos", !input.hasRunningInputs { try? await broker.finish(owner) }
        let current = owner.snapshot
        if current.phase == .recording, captures[id]?.savingSinceMs == nil,
           input.hasRunningInputs || current.browserAlive {
            captures[id]?.inputsAdmitted = true
            CaptureNotifications.shared.authorizeAfterStart()
            announce()
        }
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
                let signalOwned = captures[id]?.signalReservation != nil
                let admissionCancelled = captures[id]?.admissionCancelled == true
                settling[id] = Task { [weak self] in
                    let removed = await Task.detached { Self.discardBlank(snapshot) }.value
                    guard let self else { return }
                    self.retire(snapshot)
                    if removed && !signalOwned && !admissionCancelled && !self.isRecording && !self.attemptHasAudio {
                        self.recordFailed = true
                        for refusal in snapshot.manifest.refusals ?? [] { self.attemptRefusals = CaptureRefusal.appending(refusal,to:self.attemptRefusals) }
                    }
                    self.settling.removeValue(forKey:id)
                }
                return
        }
        retire(snapshot)
    }
    private func retire(_ snapshot: OwnedCaptureSnapshot) {
            if let value = captures[snapshot.manifest.id] { automaticAdmission.retire(value.captureID) }
            let id = snapshot.manifest.id
            captures[id]?.spectrogram?.stop(atMs:Double(captures[id]?.elapsedMs ?? 0))
            if let token = captures[id]?.signalReservation, stopping[id] == nil {
                releaseSignal(token,failed:captures[id]?.admissionCancelled != true)
            }
            captures.removeValue(forKey:id); announced.remove(id); feedOwnership(id)
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
              let data = try? Data(contentsOf:folder.appendingPathComponent("meeting.json")), data.count <= MeetingMetadataLimit.bytes,
              let metadata = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              (metadata["notes"] as? [Any])?.isEmpty == true, metadata["titleSource"] as? String == "meeting-window",
              snapshot.manifest.tracks.allSatisfy({ (try? fm.attributesOfItem(atPath:folder.appendingPathComponent($0.file).path)[.size] as? NSNumber)?.intValue == 44 }) else { return false }
        do { try fm.removeItem(at:folder); return true } catch { return false }
    }
    private func replacePeers(_ peers: [BrowserControlPeerSnapshot]) {
        self.peers = peers
        reloadBaseline = reloadBaseline.filter { key,revision in peers.contains { $0.id == key.peer && $0.healthRevision == revision } }
        let keys = Set(companionHealth.reloadTabs.map(\.key))
        reloadErrors = reloadErrors.filter { keys.contains($0.key) }
        if connected { CompanionSetup.shared.didConnect() }
        let meetings = Set(peers.flatMap(\.meetings).filter { $0.sourceCount > 0 }.map(\.key))
        failedMeetings = failedMeetings.filter { meetings.contains($0.key) }
        microphones = microphones.filter { meetings.contains($0.key) }
        for id in Array(captures.keys) {
            if let value = captures[id] {
                let key = key(for:value.captureID) ?? value.key; captures[id]?.key = key
                if let key { microphones[key] = value.owner.snapshot.me }
                if !value.peerKnown, peers.contains(where:{ $0.id == key?.peer }) { captures[id]?.peerKnown = true }
            }
        }
        announce()
        poll() // Invalidate pending source work immediately on control updates.
    }
    private func key(for captureID: String) -> BrowserMeetingKey? {
        peers.flatMap { $0.captures + $0.interrupted }.first { $0.captureID.map { Data($0.utf8) == Data(captureID.utf8) } == true }?.key
    }
    private func completed(_ outcome: BrowserControlOutcome, automatic: Bool) {
        if outcome.action == .reloadTab {
            reloadInFlight.remove(outcome.key)
            if outcome.ok { reloadErrors.removeValue(forKey:outcome.key) }
            else {
                reloadBaseline.removeValue(forKey:outcome.key)
                reloadErrors[outcome.key] = outcome.error ?? UXText.text("browser.state.reason.temporary")
            }
            return
        }
        // D58 #10: a resume ask's answer belongs to the recording it asked to join. A refusal
        // the browser answered is recorded there, in Details only; a timeout, a closed
        // connection or a local failure records nothing. Never a failed meeting or a banner.
        if outcome.resume { broker.resumeAnswered(outcome); return }
        if outcome.admissionWithdrawn { return } // Cancellation is not a device failure or user Stop.
        // A held Start whose call the user stopped meanwhile: the attempt ends, nothing to report.
        if outcome.action == .start, outcome.userStopped {
            if !automatic, !manualIssued || manualPending.contains(outcome.key) {
                manualCompleted.insert(outcome.key); manualPending.remove(outcome.key); finishAttempt()
            }
            return
        }
        if outcome.action == .start {
            if outcome.ok {
                for key in [outcome.key,outcome.settledKey].compactMap({ $0 }) { failedMeetings.removeValue(forKey:key); meetingRefusals.removeValue(forKey:key) }
            }
            else {
                failedMeetings[outcome.key] = peers.flatMap(\.meetings).first { $0.key == outcome.key }?.title ?? UXText.text("library.untitled")
                // D58 noFallback: a refused browser Start opens nothing and never falls back.
                if let refusal = outcome.startRefusal() {
                    meetingRefusals[outcome.key] = refusal
                    attemptRefusals = CaptureRefusal.appending(refusal,to:attemptRefusals)
                }
            }
            if !automatic {
                if !manualIssued || manualPending.contains(outcome.key) {
                    manualCompleted.insert(outcome.key); manualPending.remove(outcome.key)
                    if outcome.ok { manualSucceeded.insert(outcome.key) }
                    finishAttempt()
                }
            } else if !outcome.ok { recordFailed = !isRecording }
        }
        // A held Start settles under the newer link's key, which its capture now carries.
        if automatic && outcome.action == .start && outcome.ok { pendingAuto.insert(outcome.settledKey ?? outcome.key); announce() }
    }
    private func finishAttempt() {
        guard manualIssued, manualPending.isEmpty else { return }
        requestingRecord = false
        recordFailed = manualSucceeded.isEmpty && !isRecording && !failedMeetings.isEmpty
    }
    func retry(_ key: BrowserMeetingKey) {
        guard !shuttingDown,!starting,failedMeetings[key] != nil else { return }
        recordFailed = false; attemptRefusals = []; meetingRefusals.removeValue(forKey:key)
        requestingRecord = true; manualIssued = true
        manualPending = [key]; manualCompleted = []; manualSucceeded = []
        attemptHasAudio = isRecording
        service.recordMeeting(key,microphone:microphones[key] ?? true)
    }
    private func announce() {
        for (id,value) in captures {
            // A capture already saving (stopped before its Start was confirmed or before its
            // inputs were admitted) consumes the pending Start without being announced.
            if value.inputsAdmitted || value.savingSinceMs != nil, let key = value.key, pendingAuto.contains(key), !announced.contains(id) {
                pendingAuto.remove(key); announced.insert(id)
                if value.inputsAdmitted, value.savingSinceMs == nil { onAutomaticStart?(id) }
            }
        }
    }
    /// D49 via resume-capture-v1: a Record with no call keeps a system/missing
    /// stand-in. When exactly one heard call with sources appears on a peer that
    /// supports resume, ask it once to join this recording. No fresh Start follows.
    private func offerStandIn(_ id: UUID, _ value: LiveCapture) {
        let source = value.owner.snapshot
        guard value.signalReservation == nil, value.key == nil, !value.standInAttempt.attempted, !value.standInAttempt.pending, value.savingSinceMs == nil, source.phase == .recording,
              source.manifest.source == "macos", source.others, !source.transportAlive else { return }
        let state = CaptureSourceState(events:source.manifest.events ?? [],atMs:.infinity)
        guard state.source == "system", state.reason == "missing",
              let identity = broker.standInIdentity(value.owner) else { return }
        let busy = Set(captures.values.compactMap(\.key)), held = ownership.snapshot
        let calls = peers.filter { $0.reconciled && $0.supportsResume && $0.supportsMultiStream }.flatMap { peer in
            peer.browserRecordableMeetings.filter { meeting in meeting.sourceCount > 0 && meeting.heard && meeting.callGeneration != nil && !busy.contains(meeting.key)
                && !held.holds(meeting:meeting)
                && !peer.captures.contains { $0.key == meeting.key } }
        }
        guard calls.count == 1, let call = calls.first else { return }
        guard captures[id]?.standInAttempt.begin() == true else { return }
        let owner = value.owner, broker = broker, askedAt = Double(value.elapsedMs)
        service.resumeMeeting(call.key,captureID:identity.captureID,timelineOriginMs:identity.timelineOriginMs,owner:owner,expectedGeneration:call.callGeneration) { [weak self] generation,request in
            broker.expectResume(owner,callGeneration:generation,ask:request.map { ($0,askedAt) })
            // The generation the resume was sent with (nil: refused). After the take-over this
            // recording is that call's, so it follows and suppresses exactly that call (D52.5).
            Task { @MainActor in
                guard let self else { return }
                guard self.captures[id] != nil else {
                    if request != nil { self.service.stopMeeting(call.key,captureID:identity.captureID,userInitiated:false,reason:.pageGone) }
                    return
                }
                guard let generation, self.captures[id]?.standInAttempt.complete(requestID:request) == true else {
                    self.captures[id]?.standInAttempt.complete(requestID:nil); return
                }
                self.captures[id]?.key = call.key
                self.bindStandIn(id,callGeneration:generation)
                if let value = self.captures[id], let reason = value.stoppingReason {
                    self.service.stopMeeting(call.key,captureID:identity.captureID,userInitiated:value.stoppingUserInitiated,reason:reason)
                }
            }
        }
    }
    private func bindStandIn(_ id: UUID, callGeneration: String) {
        guard captures[id]?.callGeneration == nil else { return }
        captures[id]?.callGeneration = callGeneration; captures[id]?.callPolicy.callGeneration = callGeneration; feedOwnership(id)
    }
    private var lastRecordRetry: TimeInterval = 0
    /// D52.5: the recording's call (same tab and call generation) on any reconciled control
    /// peer, past or present. Only a recording whose audio transport closed is re-keyed.
    /// D52.5: feed this recording's call binding (or its removal) to the shared ownership. A
    /// D49 stand-in whose take-over committed follows its call like a Chromium capture.
    /// A hold is taken at once (it only suppresses Starts); a release (saving, retired) goes
    /// through the control queue, after the user's Stop memory that `stop` queued first.
    private func feedOwnership(_ id: UUID) {
        let current = ownership.snapshot.binding(id)
        guard let value = captures[id] else {
            if current != nil { service.updateOwnership { $0.remove(id) } }
            return
        }
        let source = value.owner.snapshot
        let binding = CallOwnership.Binding(key:value.key,callGeneration:value.callGeneration,
            follows:BrowserCallPolicy.followsCall(source:source.manifest.source,keyed:value.key != nil,events:source.manifest.events ?? []),
            recording:value.savingSinceMs == nil && source.phase == .recording)
        guard binding != current else { return }
        if current?.recording == true && !binding.recording { service.updateOwnership { $0.bind(id,binding) } }
        else { ownership.update { $0.bind(id,binding) } }
    }
    /// D52.4/D52.5: the policy asked once (per loss and control connection) to resume this
    /// recording onto its system/lost fallback through resume-capture-v1.
    private func askResume(_ value: LiveCapture, _ meeting: BrowserMeetingKey) {
        guard let identity = broker.standInIdentity(value.owner) else { return }
        let owner = value.owner, broker = broker, askedAt = Double(value.elapsedMs)
        service.resumeMeeting(meeting,captureID:identity.captureID,timelineOriginMs:identity.timelineOriginMs,owner:owner,expectedGeneration:value.callGeneration) { generation,request in
            broker.expectResume(owner,callGeneration:generation,ask:request.map { ($0,askedAt) })
        }
    }
    /// D52.5: feed every recording's binding. The service reads the held calls itself, on its
    /// queue, whenever it admits a Start; a release re-admits through `updateOwnership`.
    private func publishOwnership() {
        for id in captures.keys { feedOwnership(id) }
    }
    private func poll(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        defer { publishOwnership() }
        // D52.1 R65: a capture whose portable record could not be written stays saving (and
        // move-protected); retry it every 5 s until the broker saves it.
        if now - lastRecordRetry >= 5 {
            lastRecordRetry = now
            let broker = broker
            Task { await broker.retryPendingRecords() }
        }
        for id in Array(captures.keys) {
            guard stopping[id] == nil, let current = captures[id], current.stoppingReason == nil else { continue }
            if let reason = automaticAdmission.endReason(current.captureID) { stop(id,reason:reason); continue }
            // Every lost-call decision for this poll comes from the shared ownership, fed first
            // with what this collection knows now (a key replacePeers just learned included).
            feedOwnership(id)
            let follow = ownership.follow(id,captureID:current.captureID,peers:peers)
            if follow.rebound, let key = follow.key { captures[id]?.key = key; feedOwnership(id) }
            guard let value = captures[id] else { continue }
            offerStandIn(id,value)
            refreshLevels(id, value)
            // A native stand-in joins this path once it asked a call to resume it; until the
            // take-over commits it is a plain native recording.
            let standIn = value.snapshot.manifest.source == "macos" && value.key != nil
            let pending = BrowserCallPolicy.standInPending(source:value.snapshot.manifest.source,keyed:value.key != nil,
                                                           events:value.owner.snapshot.manifest.events ?? [])
            if value.snapshot.manifest.source == "chromium" || standIn, value.savingSinceMs == nil {
                let peer = peers.first { $0.id == value.key?.peer && $0.reconciled }
                let count = peer?.meetings.first { $0.key == value.key }?.sourceCount
                // Native Start can precede the control status that binds this
                // capture to its peer. Absence during that handshake is not loss.
                let initial = value.owner.snapshot
                if !value.peerKnown && initial.browserAlive && initial.transportAlive { continue }
                let reported = (peer?.captures ?? []) + (peer?.interrupted ?? [])
                let status = reported.first { $0.captureID.map { Data($0.utf8) == Data(value.captureID.utf8) } == true }
                let meeting = peer?.meetings.first { $0.key == value.key }
                if let peer { captures[id]?.callPolicy.resumeCapture = peer.supportsResume }
                let pages: [(BrowserCallLifecycle.Page,TimeInterval?)] = [
                    status?.pageState.map { ($0,status?.pageStateAt) },
                    meeting?.pageState.map { ($0,meeting?.pageStateAt) }
                ].compactMap { $0 }
                // Historical `present` (interrupted history) never counts once the call is gone.
                let page = CallOwnership.page(pages,callVisible:follow.callVisible)
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
                // D52 M6: a capture belongs to the call it started in. When the tab's
                // call generation moves on (seen from any of its browser's peers), this
                // session ends instead of absorbing B.
                if !pending, let ended = follow.end,
                   let reason = CaptureEndReason(rawValue:ended.rawValue) {
                    value.owner.requestEnd(reason,atMs:max(0,now-value.originUptime)*1000)
                    stop(id,reason:reason); continue
                }
                // D52 M3: unknown inventory is not zero; the 30 s grace arms only after
                // remote audio was heard; admitted browser PCM (never the microphone)
                // keeps a call alive while control is absent. Until the call has taken over, a
                // stand-in is a plain native recording: nothing but the take-over applies.
                let committed = CaptureSourceState(events:source.manifest.events ?? [],atMs:.infinity)
                // No page report: present only while the bound call is still reported. A row that
                // vanished with no session left is missing evidence (bounded by the D52 grace).
                var callObservation = BrowserCallPolicy.Observation(page:page?.0 ?? (follow.callVisible ? .present : nil),rowPresent:meeting != nil,
                    sourceCount:count,sourceCountKnown:meeting?.sourceCountKnown ?? false,heard:meeting?.heard ?? false,
                    controlAlive:peer != nil,pcmLive:fresh,transportAlive:source.transportAlive,
                    callGeneration:meeting?.callGeneration,controlConnection:peer?.id.uuidString ?? "",pageObservedAt:page?.1,lostAt:source.browserLostUptime)
                // D57 (R78.1): ask to resume only once the status no longer lists a session for this tab.
                callObservation.sessionListed = follow.sessionListed
                var policy = captures[id]?.callPolicy ?? BrowserCallPolicy()
                let action = BrowserCallPolicy.decide(pending:pending,policy:&policy,now:now,callObservation,
                    source:committed.source,reason:committed.reason,others:source.others,restoreReady:ready) {
                    // D52.5: the policy asked once (per loss and control connection) to resume;
                    // decide sends it only once the fallback has committed system/lost.
                    if let key = meeting?.key { askResume(value,key) }
                }
                captures[id]?.callPolicy = policy
                if case .stop(let reason) = action, let end = CaptureEndReason(rawValue:reason.rawValue) {
                    value.owner.requestEnd(end,atMs:max(0,now-value.originUptime)*1000)
                    stop(id,reason:end); continue
                }
                guard !value.changingSource else { continue }
                let navigation = observedPage == .navigating && page?.1 != value.lastNavigationAt
                // A present/zero report can cancel the queued navigation-loss
                // task before it reaches the owner. Commit the still-observed
                // source loss before attempting fallback, even after present.
                // Under D52 a present page with zero sources is a possible rejoin, not loss,
                // until the policy asks to fall back while the source is still alive.
                // A stand-in is a plain native recording until the call takes over; after that a
                // navigation loses the browser like any other (and falls back to system sound).
                let fallback = action == .fallback && !value.input.failedSides.contains(.others)
                let lost = !pending && BrowserCallPolicy.commitsLoss(browserAlive:source.browserAlive,page:observedPage,navigation:navigation,fallback:fallback)
                // That deferred loss began when the policy first saw the page missing.
                let lossStamp = !navigation && observedPage == .present ? captures[id]?.callPolicy.missingSince ?? page?.1 : page?.1
                if navigation { captures[id]?.lastNavigationAt = page?.1 }
                let returned = action == .restore
                guard lost || fallback || returned else { continue }
                captures[id]?.changingSource = true
                let atMs = max(0,now-value.originUptime)*1000
                let revision = value.input.sourceRevision
                Task { [weak self] in
                    do {
                        if lost {
                            #if DEBUG
                            if CaptureFixture.enabled { await CaptureFixture.beforeBrowserLoss?() }
                            #endif
                            let lossAt = max(0,(lossStamp ?? now)-value.originUptime)*1000
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
    private func refreshLevels(_ id: UUID, _ value: LiveCapture) {
        let status = value.input.status()
        captures[id]?.levels = status.mapValues { $0.levels.values.max() ?? 0 }
        if value.snapshot.browserAlive && value.snapshot.others {
            captures[id]?.levels[.others] = ProcessInfo.processInfo.systemUptime - value.snapshot.levelTimestamp <= 1 ? value.snapshot.browserLevel : 0
        }
        if (captures[id]?.levels[.me] ?? 0) >= 0.01 { captures[id]?.lastMicSound = value.microphoneUptime }
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
    func setMicrophoneUptimeForTesting(_ ids: [UUID], at time: TimeInterval?) {
        guard CaptureFixture.enabled else { return }
        for id in ids {
            guard let value = captures[id] else { continue }
            if value.fixtureMicrophoneUptime == nil || time == nil {
                captures[id]?.lastMicSound = time ?? ProcessInfo.processInfo.systemUptime
            }
            captures[id]?.fixtureMicrophoneUptime = time
            if let updated = captures[id] { refreshLevels(id, updated) }
        }
    }
    func ageMicrophoneForTesting(_ id: UUID,seconds: TimeInterval) {
        guard CaptureFixture.enabled else { return }
        captures[id]?.lastMicSound = ProcessInfo.processInfo.systemUptime-seconds
    }
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
        if CaptureFixture.enabled { try? await CaptureFixtureInput(.me).authorize(); return }
        if RecordingFixture.enabled { return }
        #endif
        try? await NativeRecordingInputs().authorize()
    }
}
