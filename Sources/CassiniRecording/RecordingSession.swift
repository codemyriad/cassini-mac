// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit
import Darwin

public struct RecordingManifest: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public let createdAt: Date
    public let title: String
    public let source: String
    public var state: String
    public var problem: String?
    public var tracks: [RecordingTrack]
    public var problemKind: String? = nil
    public var events: [CaptureEvent]? = nil
    /// D52 capture record: every announced source, including ones that never opened a WAV.
    public var captureOutcome: SessionCaptureOutcome? = nil
    enum CodingKeys: String, CodingKey { case version, id, createdAt, title, source, state, problem, tracks, problemKind, events, captureOutcome }
}

/// D52 per-source outcome. neverAudio: no admitted frames; lowAudio: under 1000 ms;
/// failed: a sticky source error. Padding never counts as received audio.
public enum CaptureOutcome: String, Codable, CaseIterable, Sendable {
    case captured, neverAudio, lowAudio, failed
    public init(failed: Bool, audioMs: Double) {
        self = failed ? .failed : audioMs <= 0 ? .neverAudio : audioMs < 1000 ? .lowAudio : .captured
    }
}

public struct SessionCaptureOutcome: Codable, Sendable, Equatable {
    public struct Source: Codable, Sendable, Equatable {
        public var sourceTrackId: String
        public var kind: String
        public var label: String?
        public var captureOutcome: CaptureOutcome
        public var audioMs: Double
        public var trackIds: [String]
        /// R69: false only while a source was never selected and never opened a span.
        public var captureExpected: Bool?
        public init(sourceTrackId: String, kind: String, label: String?, captureOutcome: CaptureOutcome, audioMs: Double, trackIds: [String], captureExpected: Bool? = nil) {
            self.sourceTrackId = sourceTrackId; self.kind = kind; self.label = label; self.captureOutcome = captureOutcome
            self.audioMs = audioMs; self.trackIds = trackIds; self.captureExpected = captureExpected
        }
        public var expected: Bool { captureExpected != false }
    }
    public var sources: [Source]
    public var unreportedSourceCount: Int?
    public init(sources: [Source], unreportedSourceCount: Int? = nil) { self.sources = sources; self.unreportedSourceCount = unreportedSourceCount }
    /// Readers ignore a malformed record rather than rejecting playable audio.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        sources = ((try? c.decode([Lossy].self,forKey:.sources)) ?? []).compactMap(\.value)
        unreportedSourceCount = (try? c.decodeIfPresent(Int.self,forKey:.unreportedSourceCount)).flatMap { $0.flatMap { $0 >= 0 ? $0 : nil } }
    }
    private struct Lossy: Decodable {
        let value: Source?
        init(from decoder: Decoder) throws {
            let source = try? Source(from:decoder)
            value = source.flatMap { s in
                !s.sourceTrackId.isEmpty && s.sourceTrackId.utf8.count <= 200 && s.audioMs.isFinite && (0...86_400_000).contains(s.audioMs) && s.trackIds.count <= 64 ? s : nil
            }
        }
    }
    enum CodingKeys: String, CodingKey { case sources, unreportedSourceCount }
}

public struct RecordingTrack: Codable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let kind: String
    public let file: String
    public let sampleRate: Int
    public let channels: Int
    public var startOffsetMs: Double?
    public var frames: UInt64
    public var endOffsetMs: Double? = nil
    public var ended: Bool? = nil
    public var labelSource: String? = nil
    public var sourceTrackId: String? = nil
    public var droppedFrames: UInt64? = nil
    public var gapFrames: UInt64? = nil
    /// Admitted PCM frames, including zeros/DC, excluding inserted gap padding.
    public var receivedFrames: UInt64? = nil
    public var captureOutcome: CaptureOutcome? = nil
    /// Per-track `capture` or `io`; the session keeps its own problemKind.
    public var problemKind: String? = nil
    enum CodingKeys: String, CodingKey { case id, label, kind, file, sampleRate, channels, startOffsetMs, frames, endOffsetMs, ended, labelSource, sourceTrackId, droppedFrames, gapFrames, receivedFrames, captureOutcome, problemKind }
}

extension RecordingManifest {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        version = try c.decode(Int.self,forKey:.version); id = try c.decode(UUID.self,forKey:.id)
        createdAt = try c.decode(Date.self,forKey:.createdAt); title = try c.decode(String.self,forKey:.title)
        source = try c.decode(String.self,forKey:.source); state = try c.decode(String.self,forKey:.state)
        problem = try c.decodeIfPresent(String.self,forKey:.problem); tracks = try c.decode([RecordingTrack].self,forKey:.tracks)
        problemKind = try c.decodeIfPresent(String.self,forKey:.problemKind)
        events = try? c.decodeIfPresent([CaptureEvent].self,forKey:.events)
        if (events?.count ?? 0) > 1000 { events = nil }
        captureOutcome = (try? c.decodeIfPresent(SessionCaptureOutcome.self,forKey:.captureOutcome)) ?? nil
    }
}
extension RecordingTrack {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        id = try c.decode(String.self,forKey:.id); label = try c.decode(String.self,forKey:.label)
        kind = try c.decode(String.self,forKey:.kind); file = try c.decode(String.self,forKey:.file)
        sampleRate = try c.decode(Int.self,forKey:.sampleRate); channels = try c.decode(Int.self,forKey:.channels)
        startOffsetMs = try c.decodeIfPresent(Double.self,forKey:.startOffsetMs); frames = try c.decode(UInt64.self,forKey:.frames)
        endOffsetMs = try c.decodeIfPresent(Double.self,forKey:.endOffsetMs); ended = try c.decodeIfPresent(Bool.self,forKey:.ended)
        labelSource = try c.decodeIfPresent(String.self,forKey:.labelSource)
        droppedFrames = try? c.decode(UInt64.self,forKey:.droppedFrames)
        gapFrames = try? c.decode(UInt64.self,forKey:.gapFrames)
        sourceTrackId = (try? c.decode(String.self,forKey:.sourceTrackId)).flatMap { !$0.isEmpty && $0.utf8.count <= 200 ? $0 : nil }
        receivedFrames = try? c.decode(UInt64.self,forKey:.receivedFrames)
        captureOutcome = try? c.decode(CaptureOutcome.self,forKey:.captureOutcome)
        problemKind = (try? c.decode(String.self,forKey:.problemKind)).flatMap { ["capture","io"].contains($0) ? $0 : nil }
    }
}

public struct RecordingSource: Sendable {
    public let id: String, label: String, kind: String
    public let sampleRate: Int, channels: Int
    public let sourceTrackId: String?
    public let labelSource: String?
    public let endsImmediately: Bool
    public init(id: String, label: String, kind: String, sampleRate: Int, channels: Int, sourceTrackId: String? = nil, labelSource: String? = nil, endsImmediately: Bool = false) {
        self.id = id; self.label = label; self.kind = kind; self.sampleRate = sampleRate; self.channels = channels; self.sourceTrackId = sourceTrackId; self.labelSource = labelSource; self.endsImmediately = endsImmediately
    }
}

/// The new metadata was published; callers must keep the committed source state
/// even if a subsequent directory sync or retiring file close reports an error.
public struct RecordingTransitionCommittedError: LocalizedError {
    public let underlying: Error
    public var errorDescription: String? { underlying.localizedDescription }
}

public enum RecordingError: LocalizedError {
    case invalid(String)
    case limit(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason), .limit(let reason): return reason }
    }
}

@_spi(Testing) public enum RecordingCheckpointPhase: String { case filesCreated, audioSynchronized, metadataSynchronized, metadataPublished }

/// A serially accessed, incremental recording. Audio is ordinary PCM WAV; the manifest
/// preserves source provenance and offsets without claiming that track IDs are people.
public final class RecordingSession {
    public let directory: URL
    public private(set) var manifest: RecordingManifest
    private var writers: [String: WAVWriter] = [:]
    private var finished = false
    private var lastCheckpoint = Date.distantPast
    private var metadataRevision: UInt64 = 0
    /// Build-only process-crash probes observe persistence boundaries. This is
    /// not exposed through native messaging or any app setting.
    @_spi(Testing) public var checkpointObserver: ((RecordingCheckpointPhase) throws -> Void)?

    public init(parent: URL, title: String, source: String, id: UUID = UUID()) throws {
        directory = parent.appendingPathComponent("Recording-\(id.uuidString.lowercased())", isDirectory: true)
        manifest = RecordingManifest(version: 1, id: id, createdAt: Date(), title: String(String.UnicodeScalarView(title.unicodeScalars.prefix(500))),
                                     source: source, state: "recording", tracks: [])
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard mkdir(directory.path,0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        do { try checkpoint() }
        catch { try? FileManager.default.removeItem(at:directory); throw error }
    }

    public func addTrack(id: String, label: String, kind: String, sampleRate: Int, channels: Int) throws {
        try transition(starting:[.init(id:id,label:label,kind:kind,sampleRate:sampleRate,channels:channels)])
    }
    /// One metadata checkpoint publishes the source changes and their events.
    /// New files created before publication are harmless orphans after a crash:
    /// a valid old manifest never discovers or infers them as an active source.
    public func transition(starting sources: [RecordingSource] = [], ending ids: [String] = [], events: [CaptureEvent] = []) throws {
        if sources.isEmpty && ids.isEmpty && events.isEmpty { return }
        guard !finished, manifest.tracks.count + sources.count <= 64,
              ((manifest.events?.count ?? 0) < 999 || (sources.isEmpty && events.isEmpty)),
              Set(sources.map(\.id)).count == sources.count, Set(ids).count == ids.count,
              ids.allSatisfy({ writers[$0] != nil }),
              (manifest.events?.count ?? 0) + events.count <= 999 else { throw RecordingError.invalid("Invalid source transition or event limit.") }
        var previous = manifest.events?.last?.atMs ?? 0
        var history = manifest.events ?? []
        for event in events {
            guard event.isKnownValid, event.type != "end", let time = event.atMs, time >= previous else { throw RecordingError.invalid("Invalid or out-of-order capture event.") }
            if event.type == "othersSource", event.reason == "restored" || event.reason == "callConnected" {
                guard CaptureSourceState(events:history,atMs:time).admitsBrowserReturn(event.reason),
                      manifest.tracks.filter({ $0.kind == "system" && $0.ended != true }).allSatisfy({ ids.contains($0.id) }),
                      sources.contains(where:{ ["remote","media","tab"].contains($0.kind) && $0.sourceTrackId != nil && !$0.endsImmediately }) else {
                    throw RecordingError.invalid("Browser restoration requires an active fallback and its new source span.")
                }
            }
            history.append(event)
            previous = time
        }
        for source in sources {
            guard !source.id.isEmpty, source.id.utf8.count <= 200, !manifest.tracks.contains(where:{ $0.id == source.id }),
                  (8_000...192_000).contains(source.sampleRate), (1...2).contains(source.channels),
                  ["microphone","system","application","local","remote","media","tab"].contains(source.kind),
                  source.sourceTrackId == nil || (source.sourceTrackId!.isEmpty == false && source.sourceTrackId!.utf8.count <= 200 && !["microphone","system"].contains(source.kind)),
                  source.labelSource == nil || ["browser","device","user","recovered"].contains(source.labelSource!)
            else { throw RecordingError.invalid("Invalid or duplicate audio source.") }
        }
        var staged: [(RecordingTrack,WAVWriter)] = []
        var created: [URL] = []
        let before = manifest, oldWriters = writers, revision = metadataRevision
        var committedIssue: Error?
        do {
            for source in sources {
                let file = "track-" + UUID().uuidString.lowercased() + ".wav"
                let url = directory.appendingPathComponent(file); created.append(url)
                let writer = try WAVWriter(url:url,sampleRate:source.sampleRate,channels:source.channels)
                var track = RecordingTrack(id:source.id,label:Self.cleanLabel(source.label),kind:source.kind,file:file,
                    sampleRate:source.sampleRate,channels:source.channels,startOffsetMs:nil,frames:0)
                track.sourceTrackId = source.sourceTrackId
                track.labelSource = source.labelSource ?? (manifest.source == "chromium" ? "browser" : "device")
                if source.endsImmediately { try writer.close(); track.ended = true }
                staged.append((track,writer))
            }
            try checkpointObserver?(.filesCreated)
            // Old handles remain open through publication, so a rejected
            // checkpoint can restore the exact metadata and keep appending.
            for id in ids {
                if let index = manifest.tracks.firstIndex(where:{ $0.id == id }) {
                    let track = manifest.tracks[index]
                    manifest.tracks[index].ended = true
                    manifest.tracks[index].endOffsetMs = track.startOffsetMs.map { $0 + Double(track.frames)/Double(track.sampleRate)*1000 }
                }
            }
            for (track,writer) in staged {
                if track.ended != true { writers[track.id] = writer }
                manifest.tracks.append(track)
            }
            if !events.isEmpty { manifest.events = (manifest.events ?? []) + events }
            try checkpoint()
        } catch {
            if metadataRevision == revision {
                manifest = before; writers = oldWriters
                for (_,writer) in staged { try? writer.close() }
                for url in created { try? FileManager.default.removeItem(at:url) }
                throw error
            }
            committedIssue = error
        }
        for id in ids {
            do { try oldWriters[id]?.close() } catch { committedIssue = committedIssue ?? error }
            writers.removeValue(forKey:id)
        }
        if let committedIssue { throw RecordingTransitionCommittedError(underlying:committedIssue) }
    }

    /// Interleaved signed 16-bit little-endian samples, with a timestamp on the session timeline.
    /// Gaps larger than 20ms become silence; overlapping/stale chunks are rejected.
    public func append(id: String, pcm: Data, offsetMs: Double) throws {
        try append(id: id, pcm: pcm, offsetMs: offsetMs, native: false)
    }

    /// Native offsets come from admitted input frame counts, including counted queue drops.
    /// Preserve even sub-20ms drop gaps exactly; the browser's jitter tolerance is not used.
    public func appendNative(id: String, pcm: Data, offsetMs: Double) throws {
        try append(id: id, pcm: pcm, offsetMs: offsetMs, native: true)
    }

    private func append(id: String, pcm: Data, offsetMs: Double, native: Bool) throws {
        guard !finished, let writer = writers[id], let i = manifest.tracks.firstIndex(where: { $0.id == id }),
              offsetMs.isFinite, (0...86_400_000).contains(offsetMs), !pcm.isEmpty,
              pcm.count <= 262_144, pcm.count % (manifest.tracks[i].channels * 2) == 0
        else { throw RecordingError.invalid("Invalid audio chunk or timestamp.") }
        if manifest.tracks[i].startOffsetMs == nil { manifest.tracks[i].startOffsetMs = offsetMs }
        let track = manifest.tracks[i]
        let target = Int64(((offsetMs - track.startOffsetMs!) * Double(track.sampleRate) / 1000).rounded())
        let delta = target - Int64(writer.frames)
        let tolerance = native ? 0 : Int64(track.sampleRate / 50)
        guard delta >= -tolerance else { throw RecordingError.invalid("Audio chunks arrived out of order.") }
        if delta > tolerance {
            guard native || delta <= Int64(track.sampleRate) * 60 else {
                throw RecordingError.invalid("Audio source was interrupted for more than a minute. Start a new recording.")
            }
            try writer.silence(frames: Int(delta))
        }
        try writer.append(pcm)
        manifest.tracks[i].frames = writer.frames
        manifest.tracks[i].receivedFrames = (manifest.tracks[i].receivedFrames ?? 0) + UInt64(pcm.count / (track.channels * 2))
        if Date().timeIntervalSince(lastCheckpoint) >= 1 { try checkpoint() }
    }

    /// D52 M5: end one failed span while every other writer keeps recording. The
    /// track keeps its audio and records `problemKind`; the session continues.
    public func failTrack(id: String, problemKind: String) throws {
        guard !finished, ["capture","io"].contains(problemKind), let index = manifest.tracks.firstIndex(where:{ $0.id == id }) else {
            throw RecordingError.invalid("Invalid source failure.")
        }
        let writer = writers.removeValue(forKey:id)
        var closeError: Error?
        do { try writer?.close() } catch { closeError = error }
        let track = manifest.tracks[index]
        manifest.tracks[index].ended = true
        manifest.tracks[index].endOffsetMs = track.endOffsetMs ?? track.startOffsetMs.map { $0 + Double(track.frames)/Double(track.sampleRate)*1000 }
        manifest.tracks[index].problemKind = closeError != nil ? "io" : problemKind
        try checkpoint()
    }
    /// The capture ledger owns this record; it is published at the next checkpoint.
    public func setCaptureOutcome(_ outcome: SessionCaptureOutcome?, tracks: [String:CaptureOutcome] = [:]) {
        manifest.captureOutcome = outcome
        for (id,value) in tracks {
            // Every source-outcomes-v1 track states its received frames, 0 when none arrived.
            if let i = manifest.tracks.firstIndex(where:{ $0.id == id }) { manifest.tracks[i].captureOutcome = value; manifest.tracks[i].receivedFrames = manifest.tracks[i].receivedFrames ?? 0 }
        }
    }
    /// D52 M2: when set, every checkpoint first refreshes the capture outcome from the
    /// manifest it is about to publish, so one write carries a track change and its accounting.
    public var captureOutcomeSource: ((RecordingManifest) -> (SessionCaptureOutcome,[String:CaptureOutcome]))?
    /// A `sources` ACK means the record is durable even before any WAV exists.
    public func publishCaptureOutcome(_ outcome: SessionCaptureOutcome?, tracks: [String:CaptureOutcome] = [:]) throws {
        guard !finished else { throw RecordingError.invalid("Recording is already saved.") }
        setCaptureOutcome(outcome,tracks:tracks)
        try checkpoint()
    }

    /// D52.2 Q3: producer drop counts accumulate on the span that recorded them.
    public func addDroppedFrames(id: String, frames: UInt64) {
        guard frames > 0, let index = manifest.tracks.firstIndex(where:{ $0.id == id }) else { return }
        let (sum,overflow) = (manifest.tracks[index].droppedFrames ?? 0).addingReportingOverflow(frames)
        manifest.tracks[index].droppedFrames = overflow ? .max : sum
    }
    public func reportLoss(id: String, droppedFrames: UInt64, gapFrames: UInt64) {
        guard let index = manifest.tracks.firstIndex(where:{ $0.id == id }) else { return }
        manifest.tracks[index].droppedFrames = droppedFrames > 0 ? droppedFrames : nil
        manifest.tracks[index].gapFrames = gapFrames > 0 ? gapFrames : nil
    }
    public func finish(problem: String? = nil) throws { try finish(problem:problem,kind:nil) }
    public func finish(problem: String?, kind: String?) throws { try finish(problem:problem,kind:kind,reason:nil) }
    public func finish(problem: String?, kind: String?, reason: CaptureEndReason?, atMs: Double? = nil) throws {
        guard !finished else { return }
        if let atMs { guard atMs.isFinite, atMs >= 0 else { throw RecordingError.invalid("Invalid recording stop time.") } }
        finished = true
        var failure: Error?
        for writer in writers.values {
            do { try writer.close() } catch { failure = failure ?? error }
        }
        writers.removeAll()
        let empty = manifest.tracks.allSatisfy { $0.frames == 0 }
        manifest.problem = (problem?.isEmpty == false ? problem : nil) ?? failure?.localizedDescription ?? (empty ? "No audio samples were received. Check the selected sources and permissions." : nil)
        for i in manifest.tracks.indices {
            let track = manifest.tracks[i]
            manifest.tracks[i].ended = true
            manifest.tracks[i].endOffsetMs = track.startOffsetMs.map { $0 + Double(track.frames) / Double(track.sampleRate) * 1000 }
        }
        manifest.problemKind = failure != nil ? "io" : kind ?? (empty ? "empty" : (manifest.problem == nil ? nil : "capture"))
        // A failed track's I/O loss takes precedence over a capture problem.
        if manifest.problemKind == "capture", manifest.tracks.contains(where:{ $0.problemKind == "io" }) { manifest.problemKind = "io" }
        manifest.state = manifest.problem == nil ? "completed" : "interrupted"
        let boundary = max(atMs ?? 0,manifest.events?.last?.atMs ?? 0,manifest.tracks.compactMap(\.endOffsetMs).max() ?? 0)
        let stopReason: CaptureEndReason = failure != nil || kind == "io" ? .error : reason ?? (problem?.isEmpty == false && kind != "gap" ? .error : .user)
        manifest.events = (manifest.events ?? []) + [.init(atMs:boundary,type:"end",reason:stopReason.rawValue)]
        let revision = metadataRevision
        do { try checkpoint() }
        catch {
            // If no final metadata was published, try one durable error
            // checkpoint. A published end is immutable even if directory sync
            // subsequently fails. Neither a retry nor close adds another end.
            if metadataRevision == revision {
                manifest.problem = error.localizedDescription; manifest.problemKind = "io"; manifest.state = "interrupted"
                manifest.events![manifest.events!.count-1] = .init(atMs:boundary,type:"end",reason:"error")
                try? checkpoint()
            }
            throw error
        }
        if let failure { throw failure }
    }

    public static func cleanLabel(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(200)))
    }

    private func checkpoint() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let captureOutcomeSource { let (outcome,tracks) = captureOutcomeSource(manifest); setCaptureOutcome(outcome,tracks:tracks) }
        // Commit audio before metadata so frames never advertise unsynced audio.
        for writer in writers.values { try writer.synchronize() }
        try checkpointObserver?(.audioSynchronized)
        let temporary = directory.appendingPathComponent(".session-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = try encoder.encode(manifest)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw RecordingError.invalid("Could not write recording metadata.")
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try durableSync(handle); try handle.close() } catch { try? handle.close(); throw error }
        try checkpointObserver?(.metadataSynchronized)
        guard rename(temporary.path, directory.appendingPathComponent("session.json").path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        metadataRevision &+= 1
        try checkpointObserver?(.metadataPublished)
        let descriptor = open(directory.path, O_RDONLY)
        if descriptor >= 0 { defer { Darwin.close(descriptor) }; if fsync(descriptor) != 0 && errno != EINVAL { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) } }
        lastCheckpoint = Date()
    }
}

private final class WAVWriter {
    private let handle: FileHandle
    private let sampleRate: Int
    private let channels: Int
    private var bytes: UInt32 = 0
    private var closed = false
    var frames: UInt64 { UInt64(bytes) / UInt64(channels * 2) }

    init(url: URL, sampleRate: Int, channels: Int) throws {
        self.sampleRate = sampleRate
        self.channels = channels
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RecordingError.invalid("Could not create the audio file.")
        }
        handle = try FileHandle(forWritingTo: url)
        try updateHeader()
    }

    func append(_ data: Data) throws {
        guard !closed, UInt64(bytes) + UInt64(data.count) <= UInt64(UInt32.max) - 36 else {
            throw RecordingError.limit("This track reached the WAV size limit. Start a new recording.")
        }
        try handle.seek(toOffset: 44 + UInt64(bytes))
        try handle.write(contentsOf: data)
        bytes += UInt32(data.count)
        // Keep even an interrupted recording playable without a separate repair step.
        try updateHeader()
    }

    func silence(frames: Int) throws {
        var remaining = frames * channels * 2
        let zeros = Data(repeating: 0, count: 16_384)
        while remaining > 0 {
            let count = min(remaining, zeros.count)
            try append(zeros.prefix(count))
            remaining -= count
        }
    }

    private func updateHeader() throws {
        var header = Data()
        func string(_ s: String) { header.append(contentsOf: s.utf8) }
        func number<T: FixedWidthInteger>(_ n: T) {
            var value = n.littleEndian
            withUnsafeBytes(of: &value) { header.append(contentsOf: $0) }
        }
        string("RIFF"); number(bytes + 36); string("WAVEfmt "); number(UInt32(16))
        number(UInt16(1)); number(UInt16(channels)); number(UInt32(sampleRate))
        number(UInt32(sampleRate * channels * 2)); number(UInt16(channels * 2)); number(UInt16(16))
        string("data"); number(bytes)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header)
    }

    func synchronize() throws { try durableSync(handle) }

    func close() throws {
        guard !closed else { return }
        try synchronize()
        try handle.close()
        closed = true
    }

    deinit { try? handle.close() }
}

private func durableSync(_ handle: FileHandle) throws {
    try handle.synchronize()
    // Network filesystems may not implement the stronger macOS disk-cache flush.
    if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 && ![EINVAL, ENOTSUP, ENOTTY].contains(errno) {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
