// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit
import CassiniRecording

public enum CaptureSide: Sendable { case me, others }
public enum OwnedCapturePhase: Sendable { case recording, saving, saved }
public struct OwnedCaptureSnapshot: Sendable {
    public let manifest: RecordingManifest
    public let directory: URL
    public let phase: OwnedCapturePhase
    public let me: Bool, others: Bool
    public let browserAlive: Bool
    public let fallbackReason: String?
    public var needsSystem: Bool { phase == .recording && others && !browserAlive && !manifest.tracks.contains { $0.kind == "system" && $0.ended != true } }
}

/// One file owner per meeting. Device callbacks use RecordingSink's admission
/// budget and a native span writer; browser requests use this owner's I/O queue.
/// No file I/O occurs under a store-wide lock or in snapshot/UI getters.
public final class OwnedBrowserCapture: @unchecked Sendable {
    private struct BrowserSource {
        let id: String, label: String, kind: String
        let rate: Int, channels: Int
        var span: String?
        var nextSequence = 0
        var clockStart: Double?
        var frames: Int64 = 0
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
    private var cached: OwnedCaptureSnapshot
    private let recording: RecordingSession
    private var browserSources: [Data:BrowserSource] = [:]
    private var nativeSpans: [String:NativeSpan] = [:]
    private var me: Bool, others = true, browserAlive = true
    private var fallbackReason: String?
    private var phase: OwnedCapturePhase = .recording
    private var resumeAt: Double = 0
    private var nativeProblem: String?
    private let changed: @Sendable (OwnedCaptureSnapshot) -> Void
    private let notifications: DispatchQueue
    private var lastPublished = DispatchTime.now().uptimeNanoseconds

    /// Creates/checkpoints the folder: call from a background task, not UI code.
    public init(parent: URL, title: String, microphone: Bool,
                changed: @escaping @Sendable (OwnedCaptureSnapshot) -> Void = { _ in }) throws {
        recording = try RecordingSession(parent:parent,title:title,source:"chromium")
        me = microphone; self.changed = changed
        queue = DispatchQueue(label:"com.codemyriad.cassini.capture." + recording.manifest.id.uuidString)
        notifications = DispatchQueue(label:"com.codemyriad.cassini.capture-notify." + recording.manifest.id.uuidString)
        try recording.transition(events:[.init(atMs:0,type:"othersSource",source:"browser",reason:"start"),
            .init(atMs:0,type:"selection",reason:"start",me:microphone,others:true)])
        cached = .init(manifest:recording.manifest,directory:recording.directory,phase:.recording,me:microphone,others:true,browserAlive:true,fallbackReason:nil)
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
        guard force || now - lastPublished >= 250_000_000 else { return }
        lastPublished = now
        let value = OwnedCaptureSnapshot(manifest:recording.manifest,directory:recording.directory,phase:phase,me:me,others:others,browserAlive:browserAlive,fallbackReason:fallbackReason)
        snapshotLock.lock(); cached = value; snapshotLock.unlock()
        notifications.async { [changed] in changed(value) }
    }
    public func browserTrack(id: String, label: String, kind: String, sampleRate: Int, channels: Int) throws {
        try sync {
            guard phase == .recording, browserAlive else { throw BrowserProtocolError("state","No active browser capture.") }
            guard !id.isEmpty, id.utf8.count <= 200, browserSources[Data(id.utf8)] == nil,
                  ["remote","media","tab"].contains(kind), (8000...192000).contains(sampleRate), (1...2).contains(channels) else { throw BrowserProtocolError("source","Invalid or duplicate browser source.") }
            guard browserSources.count < 64, recording.manifest.tracks.count < 64 else { throw BrowserProtocolError("limit","Too many browser sources.") }
            let span = UUID().uuidString.lowercased()
            try recording.transition(starting:[.init(id:span,label:label,kind:kind,sampleRate:sampleRate,channels:channels,sourceTrackId:id,labelSource:"browser",endsImmediately:!others)])
            browserSources[Data(id.utf8)] = .init(id:id,label:label,kind:kind,rate:sampleRate,channels:channels,span:others ? span : nil)
            publish()
        }
    }
    public func browserAudio(id: String, sequence: Int, offsetMs: Double, pcm: Data) throws {
        try sync {
            guard phase == .recording else { throw BrowserProtocolError("state","No active recording.") }
            guard var source = browserSources[Data(id.utf8)] else { throw BrowserProtocolError("source","Unknown browser source.") }
            guard sequence == source.nextSequence, sequence >= 0, sequence <= 9007199254740991 else { throw BrowserProtocolError("sequence","Missing or out-of-order sequence.") }
            guard offsetMs.isFinite, (0...86400000).contains(offsetMs), !pcm.isEmpty, pcm.count <= 262144, pcm.count % (source.channels*2) == 0 else { throw BrowserProtocolError("chunk","Invalid audio samples or timestamp.") }
            let start = source.clockStart ?? offsetMs
            let target = Int64(((offsetMs-start)*Double(source.rate)/1000).rounded())
            let delta = target-source.frames, tolerance = Int64(source.rate/50)
            guard delta >= -tolerance, delta <= Int64(source.rate)*60 else { throw BrowserProtocolError("chunk","Audio source clock is out of range.") }
            if delta > tolerance { source.frames += delta }
            let normalized = start + Double(source.frames)/Double(source.rate)*1000
            if browserAlive && others, let span = source.span {
                // A packet buffered before the user turned a side back on must
                // not write the excluded interval into its new span.
                let trim = min(pcm.count/(source.channels*2),max(0,Int(ceil((resumeAt-normalized)*Double(source.rate)/1000))))
                if trim*source.channels*2 < pcm.count {
                    try recording.append(id:span,pcm:Data(pcm.dropFirst(trim*source.channels*2)),offsetMs:normalized + Double(trim)/Double(source.rate)*1000)
                }
            }
            source.clockStart = start; source.frames += Int64(pcm.count/(source.channels*2)); source.nextSequence += 1
            browserSources[Data(id.utf8)] = source
            publish(force:false)
        }
    }
    /// Device owners stop admission and drain their native sink before disabling
    /// a side. Enabling it requires a fresh native sink/span writer generation.
    public func select(me newMe: Bool, others newOthers: Bool, atMs: Double) async throws {
        try await operation {
            guard self.phase == .recording, newMe || newOthers else { throw RecordingError.invalid("Choose at least one recording side.") }
            guard atMs.isFinite, atMs >= 0 else { throw RecordingError.invalid("Invalid selection time.") }
            guard newMe != self.me || newOthers != self.others else { return }
            let time = self.eventTime(atMs)
            let resuming = newOthers && !self.others
            var ends: [String] = []
            if !newMe { ends += self.nativeSpans.filter { $0.value.side == .me && $0.value.registered }.map(\.key) }
            if !newOthers {
                ends += self.browserSources.values.compactMap(\.span)
                ends += self.nativeSpans.filter { $0.value.side == .others && $0.value.registered }.map(\.key)
            }
            var starts: [RecordingSource] = []
            var spans: [Data:String] = [:]
            if newOthers && !self.others && self.browserAlive {
                for (id,source) in self.browserSources.sorted(by:{ $0.key.lexicographicallyPrecedes($1.key) }) {
                    let span = UUID().uuidString.lowercased(); spans[id] = span
                    starts.append(.init(id:span,label:source.label,kind:source.kind,sampleRate:source.rate,channels:source.channels,sourceTrackId:source.id,labelSource:"browser"))
                }
            }
            var events: [CaptureEvent] = [.init(atMs:time,type:"selection",reason:"user",me:newMe,others:newOthers)]
            if newOthers != self.others {
                events.append(.init(atMs:time,type:"othersSource",source:!newOthers ? "none" : self.browserAlive ? "browser" : "none",reason:newOthers && !self.browserAlive ? self.fallbackReason ?? "lost" : "user"))
            }
            try self.recording.transition(starting:starts,ending:ends,events:events)
            for id in Array(self.browserSources.keys) {
                if !newOthers { self.browserSources[id]?.span = nil }
                else if let span = spans[id] { self.browserSources[id]?.span = span }
            }
            self.nativeSpans = self.nativeSpans.filter { $0.value.side == .me ? newMe : newOthers }
            self.me = newMe; self.others = newOthers
            if resuming { self.resumeAt = time }
            self.publish()
        }
    }
    public func browserLost(atMs: Double) throws {
        try sync {
            guard phase == .recording, browserAlive else { return }
            guard atMs.isFinite, atMs >= 0 else { throw RecordingError.invalid("Invalid loss time.") }
            let events: [CaptureEvent] = others ? [.init(atMs:eventTime(atMs),type:"othersSource",source:"none",reason:"lost")] : []
            try recording.transition(ending:browserSources.values.compactMap(\.span),events:events)
            for id in Array(browserSources.keys) { browserSources[id]?.span = nil }
            browserAlive = false; fallbackReason = "lost"; publish()
        }
    }
    public func nativeWriter(side: CaptureSide) -> any RecordingSinkWriter { NativeSpanWriter(owner:self,side:side) }
    public func nativeSink(side: CaptureSide, originHostTime: UInt64,
                           failure: @escaping @Sendable (String) -> Void) -> RecordingSink {
        RecordingSink(session:nativeWriter(side:side),originHostTime:originHostTime,onFailure:failure)
    }
    fileprivate func nativeTrack(side: CaptureSide, label: String, rate: Int, channels: Int) throws -> String? {
        try sync {
            guard phase == .recording, side == .me ? me : others && !browserAlive else { return nil }
            guard (8000...192000).contains(rate), (1...2).contains(channels) else { throw RecordingError.invalid("Unsupported native source format.") }
            let id = UUID().uuidString.lowercased()
            nativeSpans[id] = .init(side:side,label:label,rate:rate,channels:channels)
            return id
        }
    }
    fileprivate func nativeAudio(id: String, pcm: Data, offsetMs: Double) throws {
        try sync {
            guard phase == .recording, var span = nativeSpans[id], span.side == .me ? me : others else { return }
            guard offsetMs.isFinite, (0...86400000).contains(offsetMs), !pcm.isEmpty,
                  pcm.count <= 262144, pcm.count % (span.channels*2) == 0 else { throw RecordingError.invalid("Invalid native audio chunk.") }
            var bytes = pcm, offset = offsetMs
            let first = !span.registered
            if !span.registered {
                if span.side == .others {
                    let earliest = recording.manifest.events?.last?.atMs ?? 0
                    let trim = min(pcm.count/(span.channels*2),max(0,Int(ceil((earliest-offsetMs)*Double(span.rate)/1000))))
                    guard trim*span.channels*2 < pcm.count else { return }
                    bytes = Data(pcm.dropFirst(trim*span.channels*2)); offset += Double(trim)/Double(span.rate)*1000
                }
                let events: [CaptureEvent] = span.side == .others ? [.init(atMs:offset,type:"othersSource",source:"system",reason:fallbackReason ?? "lost")] : []
                try recording.transition(starting:[.init(id:id,label:span.label,kind:span.side == .me ? "microphone" : "system",sampleRate:span.rate,channels:span.channels,labelSource:"device")],events:events)
                span.registered = true; nativeSpans[id] = span
            }
            try recording.appendNative(id:id,pcm:bytes,offsetMs:offset); publish(force:first)
        }
    }
    fileprivate func endNative(_ ids: [String], problem: String?) throws {
        try sync {
            guard phase == .recording else { return }
            let live = ids.filter { nativeSpans[$0]?.registered == true }
            if !live.isEmpty { try recording.transition(ending:live) }
            for id in ids { nativeSpans.removeValue(forKey:id) }
            if let problem, !problem.isEmpty { nativeProblem = nativeProblem ?? problem }
            publish()
        }
    }
    public func finish(problem: String? = nil) async throws {
        try await operation {
            guard self.phase != .saved else { return }
            self.phase = .saving; self.publish()
            do { try self.recording.finish(problem:problem ?? self.nativeProblem) }
            catch { self.phase = .saved; self.publish(); throw error }
            self.phase = .saved; self.publish()
        }
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

private final class NativeSpanWriter: RecordingSinkWriter {
    private let owner: OwnedBrowserCapture
    private let side: CaptureSide
    private var spans: [String:String] = [:]
    private var problem: String?
    init(owner: OwnedBrowserCapture, side: CaptureSide) { self.owner = owner; self.side = side }
    var recordingProblem: String? { problem }
    func addTrack(id: String, label: String, kind: String, sampleRate: Int, channels: Int) throws {
        guard spans[id] == nil, kind == (side == .me ? "microphone" : "system") else { throw RecordingError.invalid("Invalid native source role.") }
        spans[id] = try owner.nativeTrack(side:side,label:label,rate:sampleRate,channels:channels)
    }
    func appendNative(id: String, pcm: Data, offsetMs: Double) throws {
        guard let span = spans[id] else { return }; try owner.nativeAudio(id:span,pcm:pcm,offsetMs:offsetMs)
    }
    func finish(problem: String?) throws { self.problem = problem; try owner.endNative(Array(spans.values),problem:problem); spans.removeAll() }
}
