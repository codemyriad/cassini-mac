// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit
@_spi(Testing) import CassiniRecording

public enum CaptureSide: Hashable, Sendable { case me, others }
public enum OwnedCapturePhase: Sendable { case recording, saving, saved }
public struct OwnedCaptureSnapshot: Sendable {
    public let manifest: RecordingManifest
    public let directory: URL
    public let phase: OwnedCapturePhase
    public let me: Bool, others: Bool
    public let browserAlive: Bool
    public let transportAlive: Bool
    public let restoreReady: Bool
    public let browserReturnPCMAt: Double?
    public let managedBrowser: Bool
    public let fallbackRequested: Bool
    public var usingSystem: Bool { manifest.tracks.contains { $0.kind == "system" && $0.ended != true && $0.frames > 0 } }
    /// Live admission is authoritative here. A fractional first-buffer stamp
    /// can lie ahead of a rounded UI elapsed time until the next notification.
    public var isSystemFallback: Bool { phase == .recording && fallbackReason != nil && usingSystem }
    public let fallbackReason: String?
    public let browserLostUptime: TimeInterval?
    public let browserMeLevel: Float
    public let meLevelTimestamp: TimeInterval
    public let browserLevel: Float
    public let levelTimestamp: TimeInterval
    /// Audio and the final session are saved; only the portable capture record is pending
    /// (cached, so a broker scan never waits on this capture's I/O queue).
    public var recordPending = false
    public var needsSystem: Bool { phase == .recording && others && !browserAlive && (!managedBrowser || fallbackRequested) && !manifest.tracks.contains { $0.kind == "system" && $0.ended != true } }
}

/// One file owner per meeting. Device callbacks use RecordingSink's admission
/// budget and a native span writer; browser requests use this owner's I/O queue.
/// No file I/O occurs under a store-wide lock or in snapshot/UI getters.
public final class OwnedBrowserCapture: @unchecked Sendable {
    /// Separated calls own Me in the browser, including throughout transport gaps.
    public let nativeMe: Bool
    public let pcmObservers: RecordedPCMObservers
    private struct BrowserSource {
        let id: String, label: String, kind: String
        let labelSource: String
        /// D61: the declaration's clock facts, repeated on every span of this source.
        var clock: ClockFacts? = nil
        /// D52 M1: the stable wire sourceTrackId, or the wire id from older extensions.
        let key: String
        let rate: Int, channels: Int
        var span: String?
        var nextSequence = 0
        var clockStart: Double?
        var frames: Int64 = 0
        var returning = false
        var lastPacketAt: Double?
        var current = true
        var meter = ACLevelWindow()
        /// A new span of this source. D61: every span repeats the declaration's clock facts,
        /// whichever path starts it (a resumed chunk, Others turned back on, a restore).
        func start(_ span: String, boundaryMs: Double? = nil) -> RecordingSource {
            var value = RecordingSource(id:span,label:label,kind:kind,sampleRate:rate,channels:channels,sourceTrackId:key,labelSource:labelSource,boundaryMs:boundaryMs)
            value.clock = clock
            return value
        }
        /// D52.2 Q3: the latest span that recorded this wire id; producer drops add to it.
        var recorded: String?
    }
    private struct NativeSpan {
        let side: CaptureSide
        let label: String
        let rate: Int, channels: Int
        var registered = false
    }
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<UInt8>()
    private let snapshotLock = NSLock()
    private let endLock = NSLock()
    private var endIntent: (CaptureEndReason,Double)?
    private var timelineOrigin = ProcessInfo.processInfo.systemUptime
    private var cached: OwnedCaptureSnapshot
    private let recording: RecordingSession
    private var browserSources: [Data:BrowserSource] = [:]
    private var browserPeaks: [Data:(Float,TimeInterval)] = [:]
    private var nativeSpans: [String:NativeSpan] = [:]
    private var reservedNative: Set<CaptureSide> = []
    private var pendingNative: Int { nativeSpans.values.filter { !$0.registered }.count + reservedNative.count }
    private var me: Bool, others = true, browserAlive = true
    private var managedBrowser: Bool
    private var transportAlive = true, fallbackRequested = false
    private var browserReturnAt: Double = 0
    private var freshestReturn: Double? { browserSources.values.filter { $0.returning }.compactMap(\.lastPacketAt).max() }
    private var readyForBrowser: Bool { managedBrowser && !browserAlive && transportAlive && browserSources.values.contains { $0.returning } }
    private var fallbackReason: String?
    private var browserLossCause: BrowserCaptureLossCause?
    private var browserLostUptime: TimeInterval?
    private var systemReason = "lost"
    private var phase: OwnedCapturePhase = .recording
    private var resumeAt: Double = 0
    private var meResumeAt: Double = 0
    private var nativeProblems: [String] = []
    private var nativeProblem: String? { nativeProblems.isEmpty ? nil : nativeProblems.joined(separator:" ") }
    /// The audio and final session are closed (once); a close failure is kept for every finish.
    private var audioClosed = false, closeError: Error?
    private var nativeProblemKind: String?
    /// D52 source-outcomes-v1, enabled only when this connection negotiated it.
    private var ledger: CaptureLedger?
    private struct Declaration: Equatable { let kind: String, rate: Int, channels: Int, key: String }
    private var declarations: [String:Declaration] = [:]
    private var retired: Set<String> = []
    /// Test seam, like the reference host's `fail-audio-<id>`: writes for these wire ids fail as ENOSPC.
    private var failingWrites: Set<String> = []
    func injectWriteFailure(wireID: String) { sync { _ = failingWrites.insert(wireID) } }
    private let changed: @Sendable (OwnedCaptureSnapshot) -> Void
    private let notifications: DispatchQueue
    private var lastPublished = DispatchTime.now().uptimeNanoseconds

    /// Creates/checkpoints the folder: call from a background task, not UI code.
    public init(parent: URL, title: String, microphone: Bool, browser: Bool = true, id: UUID = UUID(), managedBrowser: Bool = false,
                changed: @escaping @Sendable (OwnedCaptureSnapshot) -> Void = { _ in }) throws {
        recording = try RecordingSession(parent:parent,title:title,source:browser ? "chromium" : "macos",id:id)
        pcmObservers = recording.pcmObservers
        nativeMe = !browser
        me = microphone; self.changed = changed
        // Only native recordings reserve a microphone slot before their first PCM.
        if microphone && !browser { reservedNative.insert(.me) }
        browserAlive = browser; transportAlive = browser; self.managedBrowser = managedBrowser && browser
        // D52.3b/D49: a Record with no call records the others as a system-sound
        // stand-in (system/missing), which a later call may take over once. Like any
        // source, it is published only when its first system PCM is admitted (D33):
        // until then the others are none/start, never a claim of system audio.
        systemReason = browser ? "lost" : "missing"
        queue = DispatchQueue(label:"io.codemyriad.cassini.capture." + recording.manifest.id.uuidString)
        notifications = DispatchQueue(label:"io.codemyriad.cassini.capture-notify." + recording.manifest.id.uuidString)
        try recording.transition(events:[.init(atMs:0,type:"othersSource",source:browser ? "browser" : "none",reason:"start"),
            .init(atMs:0,type:"selection",reason:"start",me:microphone,others:true)])
        cached = .init(manifest:recording.manifest,directory:recording.directory,phase:.recording,me:microphone,others:true,browserAlive:browser,transportAlive:browser,restoreReady:false,browserReturnPCMAt:nil,managedBrowser:managedBrowser && browser,fallbackRequested:false,fallbackReason:nil,browserLostUptime:nil,browserMeLevel:0,meLevelTimestamp:0,browserLevel:0,levelTimestamp:0)
        queue.setSpecific(key:key,value:1)
    }
    public var snapshot: OwnedCaptureSnapshot {
        snapshotLock.lock(); defer { snapshotLock.unlock() }; return cached
    }
    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key:key) != nil { return try body() }
        return try queue.sync(execute:body)
    }
    private func publish(force: Bool = true) {
        let now = DispatchTime.now().uptimeNanoseconds
        let uptime = ProcessInfo.processInfo.systemUptime
        let mePeaks = browserPeaks.filter { browserSources[$0.key]?.kind == "local" }.map(\.value)
        let otherPeaks = browserPeaks.filter { browserSources[$0.key]?.kind != "local" }.map(\.value)
        let peak = others && browserAlive ? otherPeaks.filter { uptime - $0.1 <= 1 }.map(\.0).max() ?? 0 : 0
        let mePeak = me && browserAlive ? mePeaks.filter { uptime - $0.1 <= 1 }.map(\.0).max() ?? 0 : 0
        var value = OwnedCaptureSnapshot(manifest:recording.manifest,directory:recording.directory,phase:phase,me:me,others:others,browserAlive:browserAlive,transportAlive:transportAlive,restoreReady:readyForBrowser,browserReturnPCMAt:freshestReturn,managedBrowser:managedBrowser,fallbackRequested:fallbackRequested,fallbackReason:fallbackReason,browserLostUptime:browserLostUptime,browserMeLevel:mePeak,meLevelTimestamp:mePeaks.map(\.1).max() ?? 0,browserLevel:peak,levelTimestamp:otherPeaks.map(\.1).max() ?? 0)
        value.recordPending = audioClosed && phase == .saving
        snapshotLock.lock(); cached = value; snapshotLock.unlock()
        guard force || now - lastPublished >= 250_000_000 else { return }
        lastPublished = now
        notifications.async { [changed] in changed(value) }
    }
    public func browserTrack(id: String, label: String, kind: String, sampleRate: Int, channels: Int, sourceTrackId: String? = nil, labelSource: String? = nil, clock: ClockFacts? = nil) throws {
        try sync {
            guard labelSource == nil || ["browser","dom"].contains(labelSource!) else { throw BrowserProtocolError("source","Invalid browser label provenance.") }
            var label = label, provenance = labelSource ?? "browser"
            guard phase == .recording, transportAlive, browserAlive || managedBrowser else { throw BrowserProtocolError("state","No active browser capture.") }
            guard sourceTrackId == nil || CaptureLedger.validIdentity(sourceTrackId) else { throw BrowserProtocolError("source","Invalid source identity.") }
            // Validate the declaration before it can change the ledger or be echoed.
            guard CaptureLedger.validIdentity(id), (["remote","media","tab"].contains(kind) || (kind == "local" && !nativeMe)), (8000...192000).contains(sampleRate), (1...2).contains(channels) else {
                throw BrowserProtocolError("source","Invalid or duplicate browser source.")
            }
            let selectedSide = kind == "local" ? me : others
            let key = sourceTrackId ?? id
            if ledger != nil {
                guard !retired.contains(id) else { throw BrowserProtocolError("state","Audio source has ended.") }
                let declaration = Declaration(kind:kind,rate:sampleRate,channels:channels,key:key)
                if let known = declarations[id] {
                    guard browserSources[Data(id.utf8)] != nil else { throw BrowserProtocolError("source","Source declaration was refused.") }
                    // A repeated identical declaration is idempotent; a conflicting one is
                    // refused and never tears down the live span it names.
                    guard known == declaration else { throw KeptSourceRefusal("source","Conflicting track declaration.") }
                    return
                }
                // Refused without failing or retiring anything: the live span keeps recording,
                // and this id may be declared again once that span ends.
                guard !browserSources.values.contains(where:{ $0.key == key }) else { throw KeptSourceRefusal("source","Overlapping live source spans.") }
                do { try ledger!.observe(key,kind:kind,label:RecordingSession.cleanLabel(label),expected:selectedSide,labelSource:provenance) }
                catch { throw BrowserProtocolError("source",error.localizedDescription) }
                if let snapshot = ledger!.labelSnapshot(key) { label = snapshot.label; provenance = snapshot.labelSource ?? "browser" }
                declarations[id] = declaration
            }
            // Legacy peers do not negotiate the ledger, but replacement spans
            // still refer to the original registered label snapshot.
            if ledger == nil, let original = recording.manifest.tracks.first(where:{ $0.sourceTrackId == key }) {
                label = original.label; provenance = original.labelSource ?? "browser"
            }
            guard browserSources[Data(id.utf8)] == nil else { throw BrowserProtocolError("source","Invalid or duplicate browser source.") }
            guard browserSources.count < 64, recording.manifest.tracks.count + pendingNative < 64 else { throw BrowserProtocolError("limit","Too many browser sources.") }
            let live = selectedSide && browserAlive
            // D68 (#49 review): a source a resumed transport declares before the restore gets no
            // track yet. restoreBrowser (or its first packet after the restore) opens its one real
            // span; an inert, start-less 0-frame span here would only be a second track for the key.
            // That needs the source-outcomes ledger, which already records the key and label: without
            // it (no source-outcomes-v1), the inert span is the only record of a source that never
            // returns, so it stays. A declaration while the Others are deselected keeps its inert span.
            if browserAlive || ledger == nil {
                let span = UUID().uuidString.lowercased()
                var start = RecordingSource(id:span,label:label,kind:kind,sampleRate:sampleRate,channels:channels,sourceTrackId:key,labelSource:provenance,endsImmediately:!live)
                start.clock = clock
                try commitBound([(span,key,live)],starting:[start])
                browserSources[Data(id.utf8)] = .init(id:id,label:label,kind:kind,labelSource:provenance,clock:clock,key:key,rate:sampleRate,channels:channels,span:live ? span : nil,current:browserAlive)
            } else {
                browserSources[Data(id.utf8)] = .init(id:id,label:label,kind:kind,labelSource:provenance,clock:clock,key:key,rate:sampleRate,channels:channels,span:nil,current:false)
            }
            publish()
        }
    }
    public func browserAudio(id: String, sequence: Int, offsetMs: Double, pcm: Data) throws {
        try sync {
            guard phase == .recording else { throw BrowserProtocolError("state","No active recording.") }
            if ledger != nil, retired.contains(id) { throw BrowserProtocolError("state","Audio source has ended.") }
            guard var source = browserSources[Data(id.utf8)] else { throw BrowserProtocolError("source","Unknown browser source.") }
            guard sequence == source.nextSequence, sequence >= 0, sequence <= 9007199254740991 else { throw BrowserProtocolError("sequence","Missing or out-of-order sequence.") }
            guard offsetMs.isFinite, (0...86400000).contains(offsetMs), !pcm.isEmpty, pcm.count <= 262144, pcm.count % (source.channels*2) == 0 else { throw BrowserProtocolError("chunk","Invalid audio samples or timestamp.") }
            let start = source.clockStart ?? offsetMs
            let target = Int64(((offsetMs-start)*Double(source.rate)/1000).rounded())
            let delta = target-source.frames, tolerance = Int64(source.rate/50)
            guard delta >= -tolerance else { throw BrowserProtocolError("chunk","Audio source clock is out of range.") }
            // After a suspension over 60 s the extension opens a new span; this one stays open.
            guard delta <= Int64(source.rate)*60 else { throw KeptSourceRefusal("chunk","New span required after suspension.") }
            if delta > tolerance { source.frames += delta }
            let normalized = start + Double(source.frames)/Double(source.rate)*1000
            var firstSamples = false
            source.lastPacketAt = normalized
            if managedBrowser, transportAlive, !browserAlive, normalized >= browserReturnAt {
                source.returning = true
            }
            let selectedSide = source.kind == "local" ? me : others
            let boundary = source.kind == "local" ? meResumeAt : resumeAt
            if managedBrowser, browserAlive, selectedSide, source.span == nil,
               normalized + Double(pcm.count/(source.channels*2))/Double(source.rate)*1000 > boundary {
                let span = UUID().uuidString.lowercased()
                let start = source.start(span)
                try commitBound([(span,source.key,true)],starting:[start])
                source.span = span; source.current = true
                browserSources[Data(id.utf8)] = source
            }
            if browserAlive && selectedSide, let span = source.span {
                // A packet buffered before the user turned a side back on must
                // not write the excluded interval into its new span.
                let trim = min(pcm.count/(source.channels*2),max(0,Int(ceil((boundary-normalized)*Double(source.rate)/1000))))
                if trim*source.channels*2 < pcm.count {
                    firstSamples = recording.manifest.tracks.first { $0.id == span }?.frames == 0
                    let bytes = Data(pcm.dropFirst(trim*source.channels*2)), at = normalized + Double(trim)/Double(source.rate)*1000
                    if let ledger {
                        guard !ledger.overlaps(recording.manifest,track:span,atMs:at,frames:UInt64(bytes.count/(source.channels*2))) else {
                            throw KeptSourceRefusal("source","Overlapping stored source spans.")
                        }
                        if failingWrites.contains(id) { throw SourceWriteError(underlying:POSIXError(.ENOSPC)) }
                        do { try recording.append(id:span,pcm:bytes,offsetMs:at) }
                        catch let error as RecordingError { throw BrowserProtocolError("chunk",error.localizedDescription) }
                        catch { throw SourceWriteError(underlying:error) }
                    } else { try recording.append(id:span,pcm:bytes,offsetMs:at) }
                    source.recorded = span
                    let admitted = bytes
                    var peak: Float = 0
                    admitted.withUnsafeBytes { bytes in
                        for offset in stride(from:0,to:bytes.count-1,by:max(2,bytes.count/512*2)) {
                            let sample = Int16(littleEndian:bytes.loadUnaligned(fromByteOffset:offset,as:Int16.self))
                            peak = max(peak,abs(Float(sample))/32768)
                        }
                    }
                    if source.kind == "local" {
                        var completed: Float?
                        admitted.withUnsafeBytes { bytes in
                            for frame in 0..<(bytes.count/(source.channels*2)) {
                                for channel in 0..<source.channels {
                                    let sample = Int16(littleEndian:bytes.loadUnaligned(fromByteOffset:(frame*source.channels+channel)*2,as:Int16.self))
                                    source.meter.receive(Float(sample)/32768,channel:channel)
                                }
                                if let level = source.meter.endFrame(channels:source.channels,window:source.rate/10) { completed = level }
                            }
                        }
                        if let completed { browserPeaks[Data(id.utf8)] = (completed,ProcessInfo.processInfo.systemUptime) }
                    } else { browserPeaks[Data(id.utf8)] = (peak,ProcessInfo.processInfo.systemUptime) }
                }
            }
            source.clockStart = start; source.frames += Int64(pcm.count/(source.channels*2)); source.nextSequence += 1
            browserSources[Data(id.utf8)] = source
            publish(force:firstSamples)
        }
    }
    // MARK: D52.1 R67 resume-capture-v1

    /// Atomically attach a resumed browser transport to this active stand-in. Runs
    /// on the owner queue, which also serializes finalization, and checks the end
    /// intent Stop claims first. A refusal changes nothing: no folder, clock,
    /// microphone or selection change.
    /// resume-capture-v1 targets (D49, D52.4): the reason the committed browser seam writes,
    /// or nil when the current othersSource is not an eligible target.
    public static func resumeSeamReason(source: String?, reason: String?) -> String? {
        guard source == "system" else { return nil }
        switch reason {
        case "missing": return "callConnected"   // the initial stand-in
        case "lost": return "restored"           // a fallback after the audio transport closed
        default: return nil
        }
    }
    /// Valid only during the synchronous owner callback below. The capture queue
    /// holds source transitions; this small fence orders the actual enqueue with Stop.
    final class ResumeReference: @unchecked Sendable {
        public let lostAtMs: Double
        private let owner: OwnedBrowserCapture
        private var active = true
        fileprivate init(_ owner: OwnedBrowserCapture, atMs: Double) { self.owner = owner; lostAtMs = atMs }
        public func dispatch(_ body: () throws -> Void) throws {
            try owner.endLock.withLock {
                guard active, owner.endIntent == nil else { throw BrowserIPCError.unavailable }
                try body()
            }
        }
        fileprivate func expire() { owner.endLock.withLock { active = false } }
    }
    /// Never makes the control service wait for disk. The callback must finish
    /// synchronously (the service hops onto its queue with sync); transitions
    /// cannot change the seam before dispatch, and Stop is checked at enqueue.
    func withCommittedResume(_ body: @escaping @Sendable (ResumeReference?) -> Void) {
        queue.async { [self] in
            let current = recording.manifest.events?.last(where:{ $0.type == "othersSource" })
            guard phase == .recording, others, !browserAlive, !transportAlive,
                  let committed = recording.committedOthersSource, current == committed,
                  Self.resumeSeamReason(source:committed.source,reason:committed.reason) != nil,
                  let atMs = committed.atMs, atMs.isFinite, atMs >= 0 else { body(nil); return }
            let reference = ResumeReference(self,atMs:atMs)
            defer { reference.expire() }
            body(reference)
        }
    }
    public func attachResumedBrowser() throws {
        try sync {
            let ending = endLock.withLock { endIntent != nil }
            let current = recording.manifest.events?.last(where:{ $0.type == "othersSource" })
            guard phase == .recording, !ending, others, !browserAlive, !transportAlive,
                  Self.resumeSeamReason(source:current?.source,reason:current?.reason) != nil else {
                throw BrowserProtocolError("state","The recording cannot be resumed.")
            }
            transportAlive = true; managedBrowser = true
            publish()
        }
    }

    // MARK: D52 source-outcomes-v1 (negotiated per connection)

    /// Called once, before any track, when the peer negotiated source-outcomes-v1.
    public func enableSourceOutcomes() {
        sync {
            guard ledger == nil, declarations.isEmpty else { return }
            ledger = CaptureLedger()
            // Runs inside the session's checkpoints, which happen on this capture's queue.
            recording.captureOutcomeSource = { [unowned self] manifest in
                let result = ledger!.result(manifest); return (result.outcome,result.tracks)
            }
        }
    }
    public var sourceOutcomesEnabled: Bool { sync { ledger != nil } }
    public func isRetired(_ id: String) -> Bool { sync { retired.contains(id) } }
    /// `sources`: validate the whole batch, merge sticky facts, then checkpoint.
    /// The ACK means the record is durable even when no WAV exists yet.
    public func discover(_ sources: [CaptureLedger.Discovered]) throws {
        try sync {
            guard phase == .recording, ledger != nil else { throw BrowserProtocolError("state","Capture already saved.") }
            guard !sources.isEmpty else { throw BrowserProtocolError("source","Invalid discovered audio sources.") }
            do { try ledger!.discover(sources) { $0 == "local" ? (!nativeMe && me) : others } }
            catch { throw BrowserProtocolError("source",error.localizedDescription) }
            try publishLedger()
        }
    }
    /// `trackEnd`: close the span, keep its dropped-frame count, and mark a failure
    /// only for `failed`. An intentional `callChanged` retirement is never a failure.
    public func trackEnd(id: String, reason: String, droppedFrames: UInt64) throws {
        try sync {
            guard phase == .recording, ledger != nil else { throw BrowserProtocolError("state","No active recording.") }
            guard !retired.contains(id) else { throw BrowserProtocolError("state","Audio source has ended.") }
            guard let source = browserSources[Data(id.utf8)] else { throw BrowserProtocolError("source","Unknown audio source.") }
            guard ["ended","replaced","retry","stopped","failed","callChanged"].contains(reason) else { throw BrowserProtocolError("source","Invalid source end reason.") }
            // Drops add (+=) to the latest span that recorded this wire id, even after it ended;
            // a source that never recorded stores none. They never become a range or change state.
            if let recorded = source.recorded { recording.addDroppedFrames(id:recorded,frames:droppedFrames) }
            // The ledger changes first, so the span's checkpoint also publishes its accounting.
            if reason == "failed" { ledger!.markFailed(source.key) }
            if let span = source.span {
                if reason == "failed" { try failRecordedTrack(id:span,problemKind:"capture") }
                else { try commitTransition(ending:[span]) }
            } else { try publishLedger() }
            retired.insert(id); browserSources.removeValue(forKey:Data(id.utf8)); browserPeaks.removeValue(forKey:Data(id.utf8))
            publish()
        }
    }
    #if DEBUG
    /// Hosted self-test diagnostics (D66 mac-P0-1): each declared browser source's state, by its
    /// opaque wire id and key, never a label.
    public func sourceDiagnostics() -> String {
        sync {
            let sources = browserSources.values.sorted { $0.id < $1.id }.map { source in
                "\(source.id.prefix(12)) key=\(source.key.prefix(12)) current=\(source.current) returning=\(source.returning) " +
                "span=\(source.span != nil) next=\(source.nextSequence) frames=\(source.frames) last=\(source.lastPacketAt.map { String(Int($0)) } ?? "nil")"
            }
            return (sources.isEmpty ? "none" : sources.joined(separator:"; ")) + " | retired=\(retired.count) returnAt=\(Int(browserReturnAt))"
        }
    }
    #endif
    /// A refused `track`/`audio`/`trackEnd` fails only that source; the capture
    /// and connection stay usable. Returns whether the span was already retired.
    @discardableResult public func refuseSource(id: String, code: String) -> Bool {
        sync {
            guard ledger != nil else { return false }
            if retired.contains(id) { return true }
            guard phase == .recording, let declaration = declarations[id] else { return false }
            ledger!.markFailed(declaration.key,io:code == "io")
            if let span = browserSources[Data(id.utf8)]?.span, recording.manifest.tracks.contains(where:{ $0.id == span && $0.ended != true }) {
                // One checkpoint carries the failed span and its accounting.
                do { try failRecordedTrack(id:span,problemKind:code == "io" ? "io" : "capture") }
                catch { nativeProblems.append(error.localizedDescription); nativeProblemKind = "io" }
            } else { try? publishLedger() }
            retired.insert(id); browserSources.removeValue(forKey:Data(id.utf8)); browserPeaks.removeValue(forKey:Data(id.utf8))
            publish()
            return false
        }
    }
    private func publishLedger() throws {
        guard let ledger else { return }
        let result = ledger.result(recording.manifest)
        try recording.publishCaptureOutcome(result.outcome,tracks:result.tracks)
    }

    /// Device owners stop admission and drain their native sink before disabling
    /// a side. Enabling it requires a fresh native sink/span writer generation.
    public func select(me newMe: Bool, others newOthers: Bool, atMs: Double, reservingNative: Set<CaptureSide> = []) async throws {
        try await operation {
            guard self.phase == .recording, newMe || newOthers else { throw RecordingError.invalid("Choose at least one recording side.") }
            guard atMs.isFinite, atMs >= 0 else { throw RecordingError.invalid("Invalid selection time.") }
            let reservingNative = reservingNative.filter { $0 != .me || self.nativeMe }
            if newMe == self.me && newOthers == self.others {
                guard self.recording.manifest.tracks.count + self.pendingNative + reservingNative.subtracting(self.reservedNative).count <= 64 else { throw RecordingError.limit("Too many recording tracks.") }
                self.reservedNative.formUnion(reservingNative)
                return
            }
            let time = self.eventTime(atMs)
            let resuming = newOthers && !self.others
            let resumingMe = newMe && !self.me
            var ends: [String] = []
            if !newMe { ends += self.nativeSpans.filter { $0.value.side == .me && $0.value.registered }.map(\.key) }
            if !newOthers {
                ends += self.browserSources.values.filter { $0.kind != "local" }.compactMap(\.span)
                ends += self.nativeSpans.filter { $0.value.side == .others && $0.value.registered }.map(\.key)
            }
            ends += self.browserSources.values.filter { $0.kind == "local" && !newMe }.compactMap(\.span)
            let browserAvailable = self.browserAlive || self.readyForBrowser
            var starts: [RecordingSource] = []
            var spans: [Data:String] = [:]
            if browserAvailable {
                for (id,source) in self.browserSources.sorted(by:{ $0.key.lexicographicallyPrecedes($1.key) }) where ((self.browserAlive && source.current) || source.returning) && (source.kind == "local" ? resumingMe : resuming) {
                    let span = UUID().uuidString.lowercased(); spans[id] = span
                    starts.append(source.start(span,boundaryMs:time))
                }
            }
            let keptPending = self.nativeSpans.values.filter { !$0.registered && ($0.side == .me ? newMe : newOthers) }.count
            let reservations = self.reservedNative.filter { $0 == .me ? newMe : newOthers }.union(reservingNative)
            guard self.recording.manifest.tracks.count + starts.count + keptPending + reservations.count <= 64 else { throw RecordingError.limit("Too many recording tracks.") }
            var events: [CaptureEvent] = [.init(atMs:time,type:"selection",reason:"user",me:newMe,others:newOthers)]
            if newOthers != self.others {
                events.append(.init(atMs:time,type:"othersSource",source:!newOthers ? "none" : browserAvailable ? "browser" : "none",reason:newOthers && !browserAvailable ? self.fallbackReason ?? "user" : "user"))
            }
            let bound = spans.compactMap { id,span in self.browserSources[id].map { (span,$0.key,true) } }
            try self.commitBound(bound,starting:starts,ending:ends,events:events)
            for id in Array(self.browserSources.keys) {
                let selected = self.browserSources[id]?.kind == "local" ? newMe : newOthers
                if !selected { self.browserSources[id]?.span = nil; self.browserSources[id]?.meter = .init(); self.browserPeaks.removeValue(forKey:id) }
                else if let span = spans[id] { self.browserSources[id]?.span = span }
            }
            self.ledger?.select { $0 == "local" ? (newMe && !self.nativeMe) : newOthers }
            self.nativeSpans = self.nativeSpans.filter { $0.value.side == .me ? newMe : newOthers }
            self.reservedNative = reservations
            self.me = newMe; self.others = newOthers
            if resuming && browserAvailable { self.browserAlive = true; self.browserLossCause = nil; self.fallbackReason = nil; self.browserLostUptime = nil; self.fallbackRequested = false }
            if resuming { self.resumeAt = time }
            if resuming && !self.browserAlive { self.systemReason = self.fallbackReason ?? "user" }
            if resumingMe { self.meResumeAt = time }
            self.publish()
        }
    }
    public func browserLost(atMs: Double, transportAlive: Bool = false, cause: BrowserCaptureLossCause? = nil, allowed: @Sendable () -> Bool = { true }) throws {
        try browserLost(atMs:atMs,observedAtUptime:ProcessInfo.processInfo.systemUptime,
                        transportAlive:transportAlive,cause:cause,allowed:allowed)
    }
    func browserLost(atMs: Double, observedAtUptime lost: TimeInterval, transportAlive: Bool,
                     cause: BrowserCaptureLossCause? = nil, allowed: @Sendable () -> Bool = { true }) throws {
        try sync {
            guard allowed() else { throw CancellationError() }
            guard phase == .recording else { return }
            guard atMs.isFinite, atMs >= 0 else { throw RecordingError.invalid("Invalid loss time.") }
            let transportDied = self.transportAlive && !transportAlive
            self.transportAlive = self.transportAlive && transportAlive
            guard browserAlive else {
                if browserLossCause == nil, let cause { browserLossCause = cause }
                if transportDied { browserLostUptime = lost; forgetDeadTransportSources() }
                for id in Array(browserSources.keys) { browserSources[id]?.returning = false; browserSources[id]?.current = false }
                browserReturnAt = max(browserReturnAt,atMs)
                publish(); return
            }
            let events: [CaptureEvent] = others ? [.init(atMs:eventTime(atMs),type:"othersSource",source:"none",reason:"lost",cause:cause)] : []
            try commitTransition(ending:browserSources.values.compactMap(\.span),events:events)
            for id in Array(browserSources.keys) {
                guard var source = browserSources[id] else { continue }
                source.span = nil; source.returning = false; source.current = false; source.meter = .init()
                browserSources[id] = source
            }
            browserPeaks.removeAll()
            browserReturnAt = eventTime(atMs)
            // A committed browser loss, also of a call that took over the D49 stand-in, falls
            // back as system/lost: the stand-in's "missing" belongs to the time before the call.
            if transportDied { forgetDeadTransportSources() }
            browserLossCause = cause
            browserAlive = false; fallbackReason = "lost"; systemReason = "lost"; browserLostUptime = lost; publish()
        }
    }
    /// The sources of a closed audio transport can never continue on it; a resumed transport
    /// declares fresh spans under the same source keys (D52.4). Their ledger rows stay.
    private func forgetDeadTransportSources() {
        browserSources.removeAll(); browserPeaks.removeAll()
    }
    /// A prepared, authorized system driver may now be attached. Source metadata
    /// is still unchanged until the staged writer admits its first actual PCM.
    public func requestSystemFallback(allowed: @escaping @Sendable () -> Bool = { true }) async throws {
        try await operation {
            guard allowed() else { throw CancellationError() }
            guard self.phase == .recording, self.others, !self.browserAlive else { throw BrowserIPCError.closed }
            guard self.recording.manifest.tracks.count + self.pendingNative < 64 else { throw RecordingError.limit("Too many recording tracks.") }
            self.fallbackRequested = true; self.publish()
        }
    }
    /// Admit the prepared formats and PCM on the same queue as page/source
    /// transitions. Cancellation is checked here before any candidate file or
    /// source event can be created, including after a delayed queue admission.
    func activateNative(_ stage: StagedNativeWriter, side: CaptureSide, allowed: @escaping @Sendable () -> Bool) async throws {
        try await operation {
            guard allowed() else { throw CancellationError() }
            guard self.phase == .recording, side == .others, self.others, !self.browserAlive else { throw BrowserIPCError.closed }
            try stage.activate(self.nativeWriter(side:side))
        }
    }
    /// Called only after the system sink pauses and drains. One checkpoint ends
    /// its spans, starts fresh browser spans and publishes restored together.
    public func restoreBrowser(atMs: Double, notBeforeMs: Double? = nil, allowed: @escaping @Sendable () -> Bool = { true }) async throws {
        if let notBeforeMs { guard notBeforeMs.isFinite, notBeforeMs >= 0 else { throw RecordingError.invalid("Invalid browser return time.") } }
        try await operation {
            guard allowed() else { throw CancellationError() }
            guard atMs.isFinite, atMs >= 0, self.phase == .recording,
                  (self.others || (!self.nativeMe && self.me)), !self.browserAlive, self.readyForBrowser,
                  self.freshestReturn.map({ $0 >= (notBeforeMs ?? 0) }) == true else { throw BrowserIPCError.closed }
            let time = self.eventTime(atMs)
            var spans: [Data:String] = [:], starts: [RecordingSource] = []
            for (id,source) in self.browserSources.sorted(by:{ $0.key.lexicographicallyPrecedes($1.key) }) where source.returning && (source.lastPacketAt ?? -1) >= (notBeforeMs ?? 0) && (source.kind == "local" ? self.me : self.others) {
                let span = UUID().uuidString.lowercased(); spans[id] = span
                starts.append(source.start(span))
            }
            let ending = self.nativeSpans.filter { $0.value.side == .others && $0.value.registered }.map(\.key)
            let last = self.recording.manifest.events?.last(where:{ $0.type == "othersSource" })
            // D49: a call taking over the initial stand-in is callConnected; returning from a fallback is restored.
            // A return after a browser loss whose fallback never committed (none/lost: not asked
            // yet, or still starting) is restored too (D52, protocol #44). It invents no system span.
            let reason = last?.source == "system" ? (last?.reason == "missing" ? "callConnected" : last?.reason == "lost" ? "restored" : "user")
                : last?.source == "none" && last?.reason == "lost" ? "restored" : "user"
            let bound = spans.compactMap { id,span in self.browserSources[id].map { (span,$0.key,true) } }
            try self.commitBound(bound,starting:starts,ending:ending,events:self.others ? [.init(atMs:time,type:"othersSource",source:"browser",reason:reason)] : [])
            for id in Array(self.browserSources.keys) {
                self.browserSources[id]?.span = spans[id]; self.browserSources[id]?.returning = false
                self.browserSources[id]?.current = spans[id] != nil
            }
            self.nativeSpans = self.nativeSpans.filter { $0.value.side == .me }; self.reservedNative.remove(.others)
            self.browserAlive = true; self.browserLossCause = nil; self.fallbackReason = nil; self.browserLostUptime = nil
            self.fallbackRequested = false; self.resumeAt = time
            if !self.nativeMe { self.meResumeAt = time }
            self.publish()
        }
    }
    public func nativeWriter(side: CaptureSide) -> any RecordingSinkWriter { NativeSpanWriter(owner:self,side:side) }
    /// D58: a side that never opened. It writes no event or track and never changes
    /// state, problem, othersSource or the outcome; it is checkpointed on its own.
    public func refuse(_ refusal: CaptureRefusal) throws {
        try sync {
            guard phase == .recording else { return }
            try recording.refuse(refusal); publish()
        }
    }
    /// `refuse`, enqueued on this recording's own queue: the caller (the main actor answering a
    /// resume) never waits for the checkpoint it writes to every track and session.json.
    public func refuseLater(_ refusal: CaptureRefusal) {
        queue.async { [self] in try? refuse(refusal) }
    }
    /// Returns once everything enqueued on this recording's queue before it has run (tests).
    func settled() async { await withCheckedContinuation { done in queue.async { done.resume() } } }
    /// Runs `body` on this recording's queue, in order with its writes (tests: a stalled disk).
    func enqueue(_ body: @escaping @Sendable () -> Void) { queue.async(execute:body) }
    public func systemUnavailable(atMs: Double) async throws {
        try await operation {
            guard self.phase == .recording, self.others, !self.browserAlive else { return }
            guard atMs.isFinite, atMs >= 0 else { throw RecordingError.invalid("Invalid source time.") }
            guard self.recording.manifest.events?.last(where:{ $0.type == "othersSource" })?.source != "none" else { return }
            try self.commitTransition(events:[.init(atMs:self.eventTime(atMs),type:"othersSource",source:"none",reason:"lost")])
            self.systemReason = "user"
            self.publish()
        }
    }
    public func nativeSink(side: CaptureSide, originHostTime: UInt64,
                           failure: @escaping @Sendable (String) -> Void) -> RecordingSink {
        RecordingSink(session:nativeWriter(side:side),originHostTime:originHostTime,onFailure:failure)
    }
    fileprivate func nativeTrack(side: CaptureSide, label: String, rate: Int, channels: Int) throws -> String? {
        try sync {
            guard phase == .recording, side == .me ? (me && nativeMe) : others && !browserAlive else { return nil }
            guard (8000...192000).contains(rate), (1...2).contains(channels) else { throw RecordingError.invalid("Unsupported native source format.") }
            guard reservedNative.contains(side) || recording.manifest.tracks.count + pendingNative < 64 else { throw RecordingError.limit("Too many recording tracks.") }
            reservedNative.remove(side)
            let id = UUID().uuidString.lowercased()
            nativeSpans[id] = .init(side:side,label:label,rate:rate,channels:channels)
            return id
        }
    }
    fileprivate func nativeAudio(id: String, pcm: Data, offsetMs: Double, gapKind: String = "input") throws -> RecordedPCMSource? {
        try sync {
            guard phase == .recording, var span = nativeSpans[id], span.side == .me ? me : others else { return nil }
            guard offsetMs.isFinite, (0...86400000).contains(offsetMs), !pcm.isEmpty,
                  pcm.count <= 262144, pcm.count % (span.channels*2) == 0 else { throw RecordingError.invalid("Invalid native audio chunk.") }
            var bytes = pcm, offset = offsetMs
            let first = !span.registered
            if !span.registered {
                let earliest = span.side == .others ? recording.manifest.events?.last?.atMs ?? 0 : meResumeAt
                if earliest > offsetMs {
                    let trim = min(pcm.count/(span.channels*2),max(0,Int(ceil((earliest-offsetMs)*Double(span.rate)/1000))))
                    guard trim*span.channels*2 < pcm.count else { return nil }
                    bytes = Data(pcm.dropFirst(trim*span.channels*2)); offset += Double(trim)/Double(span.rate)*1000
                }
                // The stand-in already published system/missing; its first PCM adds no event.
                let current = recording.manifest.events?.last(where:{ $0.type == "othersSource" })
                let announced = current?.source == "system" && current?.reason == systemReason
                let events: [CaptureEvent] = span.side == .others && !announced ? [.init(atMs:offset,type:"othersSource",source:"system",reason:systemReason,cause:systemReason == "lost" ? browserLossCause : nil)] : []
                // D52.2: a native span starts at its selection boundary; the wait for its first buffer is a prefix.
                try commitTransition(starting:[.init(id:id,label:span.label,kind:span.side == .me ? "microphone" : "system",sampleRate:span.rate,channels:span.channels,labelSource:"device",
                                                     boundaryMs:nativeBoundary(span.side).flatMap { $0 < offset ? $0 : nil })],events:events)
                span.registered = true; nativeSpans[id] = span
            }
            try recording.appendNative(id:id,pcm:bytes,offsetMs:offset,gapKind:gapKind); publish(force:first)
            guard let track = recording.manifest.tracks.first(where:{ $0.id == id }), let start = track.startOffsetMs else { return nil }
            return .init(id:id,kind:track.kind,sampleRate:track.sampleRate,channels:track.channels,startOffsetMs:start)
        }
    }
    /// D52.2 selection boundaries for native spans: the microphone's selection time,
    /// and the no-call stand-in's start. A fallback system span switches source, so it
    /// starts at its first frame.
    private func nativeBoundary(_ side: CaptureSide) -> Double? {
        if side == .me { return meResumeAt }
        return recording.manifest.source == "macos" && systemReason == "missing" ? resumeAt : nil
    }
    fileprivate func nativePadding(id: String, frames: UInt64, offsetMs: Double, kind: String) throws {
        try sync {
            guard phase == .recording, let span = nativeSpans[id], span.registered, span.side == .me ? me : others else { return }
            try recording.padNative(id:id,frames:frames,channels:span.channels,rate:Double(span.rate),offsetMs:offsetMs,kind:kind); publish(force:false)
        }
    }
    fileprivate func reportNativeLoss(id: String, droppedFrames: UInt64, gapFrames: UInt64) {
        sync { recording.reportLoss(id:id,droppedFrames:droppedFrames,gapFrames:gapFrames) }
    }
    fileprivate func endNative(_ ids: [String], side: CaptureSide, problem: String?, kind: String? = nil) throws {
        try sync {
            guard phase == .recording else { return }
            // Keep the source diagnostic even if closing/checkpointing its track fails.
            if let problem, !problem.isEmpty {
                nativeProblems.append(problem)
            }
            if kind != nil || problem?.isEmpty == false {
                let value = kind ?? "capture"
                if nativeProblemKind == nil || value == "io" || nativeProblemKind == "gap" { nativeProblemKind = value }
            }
            let live = ids.filter { nativeSpans[$0]?.registered == true }
            // D52 (GNOME live_problem): a native input lost to an I/O failure ends its
            // track with problemKind io, which the Recording page reports per source.
            // SPEC "Gap ranges": writer loss is padding instead of failing the source, so
            // writer loss alone (io with no diagnostic) ends the span normally (D69.2).
            if kind == "io", problem?.isEmpty == false {
                for id in live { try failRecordedTrack(id:id,problemKind:"io") }
            } else if !live.isEmpty { try commitTransition(ending:live) }
            for id in ids { nativeSpans.removeValue(forKey:id) }
            reservedNative.remove(side)
            publish()
        }
    }
    /// Claim the trigger before asynchronous native/browser drains. This lock
    /// never waits for disk I/O, so a UI Stop cannot lose its reason to a later
    /// generic native Stop. A second trigger cannot rewrite the first one.
    func setTimelineOrigin(_ uptime: TimeInterval) {
        guard uptime.isFinite else { return }
        endLock.withLock { if endIntent == nil { timelineOrigin = uptime } }
    }
    @discardableResult public func requestEnd(_ reason: CaptureEndReason, atMs: Double? = nil) -> Bool {
        if let atMs { guard atMs.isFinite, atMs >= 0 else { return false } }
        return endLock.withLock {
            guard endIntent == nil else { return false }
            endIntent = (reason,atMs ?? max(0,ProcessInfo.processInfo.systemUptime-timelineOrigin)*1000); return true
        }
    }
    /// Closes the audio and writes the final session, then publishes `.saved`. `persist`
    /// (D52.1 R65, the portable capture record) runs after any final session that reached disk,
    /// also an interrupted one, and before `.saved`: the capture keeps its saving state, and so
    /// the Library's move protection, until both writes finish. If `persist` throws the capture
    /// stays saving with its audio closed; a later `finish` retries only `persist`.
    public func finish(problem: String? = nil, reason: CaptureEndReason? = nil, atMs: Double? = nil,
                       persist: (@Sendable (RecordingManifest,URL) throws -> Void)? = nil) async throws {
        if let atMs { guard atMs.isFinite, atMs >= 0 else { throw RecordingError.invalid("Invalid recording stop time.") } }
        if let reason { requestEnd(reason,atMs:atMs) }
        try await operation {
            guard self.phase != .saved else { return }
            if !self.audioClosed { try self.closeAudio(problem:problem,reason:reason,atMs:atMs); self.publish() }
            if let persist, self.recording.finalPublished {
                do { try persist(self.recording.manifest,self.recording.directory) }
                catch { self.publish(); throw error }
            }
            self.phase = .saved; self.publish()
            if let closeError = self.closeError { throw closeError }
        }
    }
    /// Audio is closed and the final session written; only the portable record may be pending.
    public var recordPending: Bool { snapshot.recordPending }
    @_spi(Testing) public func requirePeriodicCheckpoint() { sync { recording.requirePeriodicCheckpoint() } }
    @_spi(Testing) public func setCheckpointObserver(_ observer: ((RecordingCheckpointPhase) throws -> Void)?) {
        sync { recording.checkpointObserver = observer }
    }
    private func closeAudio(problem: String?, reason: CaptureEndReason?, atMs: Double?) throws {
        self.phase = .saving; self.publish()
        // The broker can echo the input drain's already recorded diagnostic.
        // Preserve its classification; a different external failure is capture.
        let kind = self.nativeProblemKind == "io" || problem == nil || problem == self.nativeProblem ? self.nativeProblemKind : nil
        let intent = self.endLock.withLock { self.endIntent }
        var diagnostics = self.nativeProblems
        if let problem, !problem.isEmpty, problem != self.nativeProblem, !diagnostics.contains(problem) { diagnostics.insert(problem,at:0) }
        var finalProblem = diagnostics.isEmpty ? nil : diagnostics.joined(separator:" "), finalKind = kind
        if let ledger = self.ledger {
            let result = ledger.result(self.recording.manifest)
            self.recording.setCaptureOutcome(result.outcome,tracks:result.tracks)
            // A person whose source failed is never silently missing.
            if result.incomplete {
                finalProblem = finalProblem ?? "Some announced audio was not fully captured."
                if finalKind != "io" { finalKind = ledger.ioFailed ? "io" : "capture" }
            }
        }
        do { try self.recording.finish(problem:finalProblem,kind:finalKind,reason:intent?.0 ?? reason,atMs:intent?.1 ?? atMs) }
        catch { self.closeError = error }
        self.audioClosed = true
    }
    // Once the metadata rename succeeds, source state must follow it even if
    // directory sync/retiring-file close fails. Preserve the diagnostic for Stop.
    /// Binds new spans to their sources before the transition's checkpoint, so that one
    /// write carries the tracks with their captureOutcome and trackIds. A refused
    /// transition leaves the ledger as it was.
    private func commitBound(_ bindings: [(span: String, key: String, expected: Bool)], starting: [RecordingSource] = [], ending: [String] = [], events: [CaptureEvent] = []) throws {
        let saved = ledger
        for binding in bindings { ledger?.bind(track:binding.span,to:binding.key,expected:binding.expected) }
        do { try commitTransition(starting:starting,ending:ending,events:events) } catch { ledger = saved; throw error }
    }
    /// A declared wire id with a span that has not ended or been refused.
    func isLive(_ id: String) -> Bool { sync { browserSources[Data(id.utf8)] != nil } }
    private func failRecordedTrack(id: String, problemKind: String) throws {
        defer { pcmObservers.sourceEnded(id:id) }
        try recording.failTrack(id:id,problemKind:problemKind)
    }
    private func commitTransition(starting: [RecordingSource] = [], ending: [String] = [], events: [CaptureEvent] = []) throws {
        do { try recording.transition(starting:starting,ending:ending,events:events) }
        catch let error as RecordingTransitionCommittedError {
            nativeProblems.append(error.localizedDescription); nativeProblemKind = "io"
        }
        for id in ending { pcmObservers.sourceEnded(id:id) }
    }
    private func eventTime(_ requested: Double) -> Double {
        // A device's frame count is not the control clock. Its drift must not
        // move a browser loss, or discard the beginning of a system fallback.
        max(requested,recording.manifest.events?.last?.atMs ?? 0)
    }
    private func operation(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with:Result { try body() }) }
        }
    }
}

/// A per-source refusal that leaves the named span and its source untouched: an overlap,
/// a conflicting re-declaration or a suspension gap (the reference host never fails these).
struct KeptSourceRefusal: LocalizedError {
    let code: String, message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var errorDescription: String? { message }
}
/// An append failed for one span's file; the broker refuses that source as `io`.
struct SourceWriteError: LocalizedError {
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

private final class NativeSpanWriter: RecordingSinkWriter {
    private let owner: OwnedBrowserCapture
    private let side: CaptureSide
    private var spans: [String:String] = [:]
    let recordedPCM: RecordedPCMPolicy?
    init(owner: OwnedBrowserCapture, side: CaptureSide) {
        self.owner = owner; self.side = side
        recordedPCM = RecordedPCMPolicy(observers:owner.pcmObservers)
    }
    // Ending a span records diagnostics on its meeting owner. A preserved gap
    // or counted queue loss must not reject the user's source-off transition.
    // Actual write/checkpoint errors still throw from append/endNative.
    var recordingProblem: String? { nil }
    func addTrack(id: String, label: String, kind: String, sampleRate: Int, channels: Int) throws {
        guard spans[id] == nil, kind == (side == .me ? "microphone" : "system") else { throw RecordingError.invalid("Invalid native source role.") }
        spans[id] = try owner.nativeTrack(side:side,label:label,rate:sampleRate,channels:channels)
    }
    func appendNative(id: String, pcm: Data, offsetMs: Double) throws {
        guard let span = spans[id] else { return }
        if let source = try owner.nativeAudio(id:span,pcm:pcm,offsetMs:offsetMs) { recordedPCM?.publish(source,for:id) }
    }
    func appendNative(id: String, pcm: Data, offsetMs: Double, gapKind: String) throws {
        guard let span = spans[id] else { return }
        if let source = try owner.nativeAudio(id:span,pcm:pcm,offsetMs:offsetMs,gapKind:gapKind) { recordedPCM?.publish(source,for:id) }
    }
    func padNative(id: String, frames: UInt64, channels: Int, rate: Double, offsetMs: Double, kind: String) throws {
        guard let span = spans[id] else { return }; try owner.nativePadding(id:span,frames:frames,offsetMs:offsetMs,kind:kind)
    }
    func reportLoss(id: String, droppedFrames: UInt64, gapFrames: UInt64) {
        guard let span = spans[id] else { return }
        owner.reportNativeLoss(id:span,droppedFrames:droppedFrames,gapFrames:gapFrames)
    }
    func finish(problem: String?) throws { try finish(problem:problem,kind:nil) }
    func finish(problem: String?, kind: String?) throws {
        try owner.endNative(Array(spans.values),side:side,problem:problem,kind:kind); spans.removeAll()
    }
}
