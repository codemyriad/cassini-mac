// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import CassiniKit

/// Serial writer interface, also used by deterministic tests that model a stalled disk.
public protocol RecordingSinkWriter: AnyObject {
    func addTrack(id: String, label: String, kind: String, sampleRate: Int, channels: Int) throws
    func appendNative(id: String, pcm: Data, offsetMs: Double) throws
    /// D52.2: the kind of any padding before this chunk (`input` or `writer`).
    func appendNative(id: String, pcm: Data, offsetMs: Double, gapKind: String) throws
    /// D52.2/D52.4 R70: pad `frames` in place from `offsetMs`, never as received audio:
    /// `writer` over the sink's own lost frames, `input` over a host-time gap.
    func padNative(id: String, frames: UInt64, channels: Int, rate: Double, offsetMs: Double, kind: String) throws
    func finish(problem: String?) throws
    func finish(problem: String?, kind: String?) throws
    func reportLoss(id: String, droppedFrames: UInt64, gapFrames: UInt64)
    var recordingProblem: String? { get }
    var recordedPCM: RecordedPCMPolicy? { get }
}

extension RecordingSinkWriter {
    public var recordedPCM: RecordedPCMPolicy? { nil }
    public func finish(problem: String?, kind: String?) throws { try finish(problem: problem) }
    public func reportLoss(id: String, droppedFrames: UInt64, gapFrames: UInt64) {}
    public func appendNative(id: String, pcm: Data, offsetMs: Double, gapKind: String) throws { try appendNative(id:id,pcm:pcm,offsetMs:offsetMs) }
    /// Writers without range support keep the earlier in-place zeros.
    public func padNative(id: String, frames: UInt64, channels: Int, rate: Double, offsetMs: Double, kind: String) throws {
        var frame: UInt64 = 0
        while frame < frames {
            let count = min(UInt64(8192),frames-frame)
            try appendNative(id:id,pcm:Data(repeating:0,count:Int(count)*channels*2),offsetMs:offsetMs + Double(frame)/rate*1000)
            frame += count
        }
    }
}

extension RecordingSession: RecordingSinkWriter {
    public var recordingProblem: String? { manifest.problem }
}

/// D69.1: exact callback-frame loss and a host-time estimate are different facts.
public enum NativeWriterLoss: Sendable {
    case known(frames: UInt64)
    case inferred(frames: UInt64)
}

/// A native device's sample clock supplies continuity. Host time only anchors its first buffer.
/// Subsequent host-time jumps preserve missing input time; ordinary device-clock drift must never add silence
/// or trigger the browser protocol's out-of-order protection.
struct NativeSourceTimeline {
    let sampleRate: Double
    let startOffsetMs: Double
    private(set) var frames: UInt64 = 0

    static func missingFrames(sampleRate: Double, hostOffsetMs: Double, previousHostMs: Double, previousInputFrames: UInt64) -> UInt64 {
        let lag = hostOffsetMs - previousHostMs - Double(previousInputFrames) / sampleRate * 1000
        guard lag > 0 else { return 0 }
        let frames = (lag * sampleRate / 1000).rounded()
        return frames >= sampleRate ? UInt64(frames) : 0
    }

    mutating func insertGap(frames count: UInt64) { frames += count }

    mutating func advance(frames count: UInt64) -> Double {
        let offset = startOffsetMs + Double(frames) / sampleRate * 1000
        frames += count
        return offset
    }
}

/// Owns admission/format/timeline state under `lock`; all writer access is on `queue`.
/// Disk stalls have a ten-second per-source memory budget. Overflow becomes counted silence
/// on that source's sample timeline, without stopping unrelated sources or blocking audio IO.
private struct ACLevelChannel {
    var sum = 0.0, minimum = Double.infinity, maximum = -Double.infinity
    mutating func receive(_ sample: Float) {
        let value = Double(sample.isFinite ? sample : 0)
        sum += value; minimum = min(minimum,value); maximum = max(maximum,value)
    }
    func peak(count: Int) -> Float {
        let mean = sum / Double(count)
        return Float(max(abs(minimum-mean),abs(maximum-mean)))
    }
}
/// AC peak over continuous 100 ms windows, independently centred per channel.
package struct ACLevelWindow {
    package init() {}
    private var left = ACLevelChannel(), right = ACLevelChannel(), count = 0
    package mutating func receive(_ value: Float, channel: Int) {
        if channel == 0 { left.receive(value) } else { right.receive(value) }
    }
    package mutating func endFrame(channels: Int, window: Int) -> Float? {
        count += 1
        guard count >= window else { return nil }
        let value = max(left.peak(count:count),channels == 2 ? right.peak(count:count) : 0)
        self = Self(); return min(1,value)
    }
}
public final class RecordingSink: @unchecked Sendable {
    private struct Source {
        let rate: Double
        let inputChannels: AVAudioChannelCount
        let outputChannels: Int
        var timeline: NativeSourceTimeline
        var pendingFrames: UInt64 = 0
        var droppedFrames: UInt64 = 0
        var gapFrames: UInt64 = 0
        var lastHostOffset: Double?
        var lastInputFrames: UInt64 = 0
        var submittedEnd: UInt64 = 0
        var registered = false
        var tailRecorded = false
        var meter = ACLevelWindow()
        var meteredFrames: UInt64 = 0
        var reportedMeterFrames: UInt64 = 0
        var lastCompletePeak: Float?
    }
    private let queue = DispatchQueue(label: "io.codemyriad.cassini.recording-writer", qos: .userInitiated)
    private let lock = NSLock()
    private var failed = false
    private var failureMessage: String?
    private var accepting = true
    private var finished = false
    private var levels: [String: Float] = [:]
    private var sourceFrames: [String: UInt64] = [:]
    private var sources: [String: Source] = [:]
    /// Unwritten timeline since each source's last admitted write, in order: a host-time
    /// gap is `input`, a dropped buffer is `writer`. Each is padded with its own kind.
    private struct Hole { let kind: String; var frames: UInt64 }
    private var holes: [String: [Hole]] = [:]
    private func hole(_ id: String, _ kind: String, _ frames: UInt64) {
        if holes[id]?.last?.kind == kind { holes[id]![holes[id]!.count - 1].frames += frames }
        else { holes[id, default: []].append(.init(kind:kind,frames:frames)) }
    }
    private var warnings: Set<String> = []
    private let writer: any RecordingSinkWriter
    private let pcmPolicy: RecordedPCMPolicy?
    private let origin: UInt64
    private let capacitySeconds: Double
    private let onFailure: @Sendable (String) -> Void
    /// D58: asked once, at the first valid buffer, before it is queued for the writer (so before
    /// any disk write: a slow Library disk never makes a working input look unopened). False
    /// means the input's opening bound already passed: that buffer and every later one are
    /// refused, so an expired input records nothing (#120 r3).
    private let admit: (@Sendable () -> Bool)?
    private var admitted = false

    public init(session: any RecordingSinkWriter, capacitySeconds: Double = 10,
                originHostTime: UInt64 = AVAudioTime.hostTime(forSeconds: ProcessInfo.processInfo.systemUptime),
                onFailure: @escaping @Sendable (String) -> Void, admit: (@Sendable () -> Bool)? = nil) {
        writer = session; pcmPolicy = session.recordedPCM
        origin = originHostTime
        self.capacitySeconds = max(0.01, min(60, capacitySeconds))
        self.onFailure = onFailure
        self.admit = admit
    }

    public func receive(_ buffer: AVAudioPCMBuffer, hostTime: UInt64, id: String, label: String, kind: String, writerLoss: NativeWriterLoss? = nil) {
        lock.lock()
        guard accepting, !failed, buffer.frameLength > 0 else { lock.unlock(); return }
        guard buffer.frameLength <= 65_536, buffer.format.commonFormat == .pcmFormatFloat32,
              let input = buffer.floatChannelData, (1...64).contains(buffer.format.channelCount),
              buffer.format.sampleRate.isFinite, buffer.format.sampleRate.rounded() == buffer.format.sampleRate, (8_000...192_000).contains(buffer.format.sampleRate) else {
            lock.unlock(); fail("The audio source changed to an unsupported format. The recorded audio was preserved."); return
        }
        if !admitted {
            // The signal's own lock decides; nothing here calls back into this sink.
            guard admit?() ?? true else { accepting = false; lock.unlock(); return }
            admitted = true
        }
        let rate = buffer.format.sampleRate
        let inputChannels = buffer.format.channelCount
        let outputChannels = min(2, Int(inputChannels))
        let frames = UInt64(buffer.frameLength)
        let stamp = hostTime == 0 ? AVAudioTime.hostTime(forSeconds: ProcessInfo.processInfo.systemUptime) : hostTime
        let hostOffset = stamp > origin ? AVAudioTime.seconds(forHostTime: stamp - origin) * 1000 : 0
        if sources[id] == nil {
            guard sources.count < 64 else { lock.unlock(); fail("Too many native audio sources."); return }
            sources[id] = Source(rate: rate, inputChannels: inputChannels, outputChannels: outputChannels,
                                 timeline: NativeSourceTimeline(sampleRate: rate, startOffsetMs: hostOffset))
            if inputChannels > 2 { warnings.insert("\(label): recording input channels 1 and 2.") }
        }
        var source = sources[id]!
        guard !source.tailRecorded else { lock.unlock(); return }
        guard source.rate == rate, source.inputChannels == inputChannels else {
            lock.unlock(); fail("The audio device format changed. Start a new recording with the current device."); return
        }
        let interval = hostTime == 0 ? nil : source.lastHostOffset.map { hostOffset - $0 - Double(source.lastInputFrames) / rate * 1000 }
        let lost: UInt64
        switch writerLoss {
        case .known(let frames): lost = source.lastInputFrames > 0 ? frames : 0
        case .inferred(let frames): lost = min(frames,UInt64(max(0,((interval ?? 0) * rate / 1000).rounded())))
        case nil: lost = 0
        }
        guard lost <= UInt64(rate * 86400) else { lock.unlock(); fail("Invalid native writer loss."); return }
        // Known frames do not require a host stamp. Only host-time inference does.
        if hostTime != 0, let previous = source.lastHostOffset {
            let gap = NativeSourceTimeline.missingFrames(sampleRate:rate,hostOffsetMs:hostOffset,previousHostMs:previous,
                                                         previousInputFrames:source.lastInputFrames+lost)
            if gap > 0 {
                source.timeline.insertGap(frames:gap); source.gapFrames += gap
                hole(id,"input",gap)
                source.meter = .init(); source.lastCompletePeak = nil; levels.removeValue(forKey:id)
                warnings.insert("\(label): a host-time gap was preserved as counted silence.")
            }
        }
        if lost > 0 {
            source.timeline.insertGap(frames:lost); source.droppedFrames += lost
            hole(id,"writer",lost)
        }
        // Arrival time can anchor a source with no host stamp, but cannot establish
        // an input discontinuity. Break the comparison chain until stamps return.
        source.lastHostOffset = hostTime == 0 ? nil : hostOffset
        source.lastInputFrames = frames
        let offset = source.timeline.advance(frames: frames)
        if abs(hostOffset - offset) >= 250 { warnings.insert("\(label): device time differs from the sample timeline; sample continuity was preserved.") }
        sourceFrames[id] = source.timeline.frames
        guard source.pendingFrames + frames <= UInt64(rate * capacitySeconds) else {
            source.droppedFrames += frames
            hole(id,"writer",frames)
            sources[id] = source
            lock.unlock()
            return
        }
        source.pendingFrames += frames
        // Before a track exists its start is this chunk, so earlier holes are not padding.
        let pending = source.registered ? holes.removeValue(forKey:id) ?? [] : []
        if !source.registered { holes.removeValue(forKey:id) }
        let holeStart = source.submittedEnd, timelineStart = source.timeline.startOffsetMs
        source.submittedEnd = source.timeline.frames
        let register = !source.registered
        source.registered = true
        var peak: Float?
        var pcm = Data(count: Int(frames) * outputChannels * 2)
        pcm.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for frame in 0..<Int(frames) {
                for channel in 0..<outputChannels {
                    let value = buffer.format.isInterleaved ? input[0][frame * Int(inputChannels) + channel] : input[channel][frame]
                    source.meter.receive(value,channel:channel)
                    samples[frame * outputChannels + channel] = Int16((max(-1, min(1, value.isFinite ? value : 0)) * 32767).rounded()).littleEndian
                }
                if let value = source.meter.endFrame(channels:outputChannels,window:max(1,Int(rate/10))) {
                    peak = max(peak ?? 0,value); source.lastCompletePeak = value
                }
            }
        }
        source.meteredFrames += frames
        sources[id] = source
        if let peak { levels[id] = max(levels[id,default:0],peak) }
        // Enqueue before releasing admission lock: finish can never overtake an admitted copy.
        queue.async { [self, pcm] in
            defer { lock.lock(); sources[id]?.pendingFrames -= frames; lock.unlock() }
            do {
                if register {
                    try writer.addTrack(id: id, label: label, kind: kind, sampleRate: Int(rate), channels: outputChannels)
                }
                var frame = holeStart
                for hole in pending {
                    try writer.padNative(id:id,frames:hole.frames,channels:outputChannels,rate:rate,offsetMs:timelineStart + Double(frame)/rate*1000,kind:hole.kind)
                    frame += hole.frames
                }
                try writer.appendNative(id: id, pcm: pcm, offsetMs: offset, gapKind: "input")
            } catch { fail(error.localizedDescription) }
        }
        lock.unlock()
        // Immutable admitted bytes are shared, not copied or analyzed here.
        // The policy has only independent short metadata locks, never the
        // writer's lock. Missing readiness/source metadata means no picture.
        pcmPolicy?.offer(inputID:id,pcm:pcm,offsetMs:offset)
    }

    /// Close a source's reported writer-loss interval. Call only with evidence of loss,
    /// never to infer loss merely from a quiet source or a delayed Stop. The interval
    /// follows the latest observed input; already counted callback drops are excluded.
    /// A later host stamp can locate the interval without admitting that later buffer.
    public func recordWriterTail(id: String, untilHostTime: UInt64, loss: NativeWriterLoss? = nil,
                                 resumeHostTime: UInt64? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard accepting, !finished, var source = sources[id], !source.tailRecorded else { throw RecordingError.invalid("No open source for writer loss.") }
        let exactUnstampedTail: Bool
        if case .known = loss, resumeHostTime == nil { exactUnstampedTail = true } else { exactUnstampedTail = false }
        guard source.lastHostOffset != nil || exactUnstampedTail else { throw RecordingError.invalid("No input host stamp for inferred writer loss.") }
        let end = (source.lastHostOffset ?? 0) + Double(source.lastInputFrames) / source.rate * 1000
        func frames(to stamp: UInt64) -> Int64 {
            let at = stamp > origin ? AVAudioTime.seconds(forHostTime:stamp-origin)*1000 : 0
            return Int64(((at-end)*source.rate/1000).rounded())
        }
        let until = source.lastHostOffset == nil ? 0 : max(0,frames(to:untilHostTime))
        guard until <= Int64(source.rate * 86400) else { throw RecordingError.invalid("Invalid writer-loss stop time.") }
        let missing: Int64, lost: Int64
        switch loss {
        case .known(let count):
            guard count <= UInt64(source.rate * 86400) else { throw RecordingError.invalid("Invalid writer loss.") }
            lost = Int64(count)
            missing = resumeHostTime.map { min(until,max(0,frames(to:$0)-lost)) } ?? 0
        case .inferred(let count):
            guard count <= UInt64(source.rate * 86400), let resumeHostTime else { throw RecordingError.invalid("An inferred interval needs its following host stamp.") }
            let resume = frames(to:resumeHostTime), from = max(0,resume-Int64(count))
            missing = min(until,from); lost = max(0,min(until,resume)-from)
        case nil:
            guard resumeHostTime == nil else { throw RecordingError.invalid("A following host stamp needs a loss count.") }
            missing = 0; lost = until
        }
        if Double(missing) >= source.rate {
            source.timeline.insertGap(frames:UInt64(missing)); source.gapFrames += UInt64(missing)
            hole(id,"input",UInt64(missing))
        }
        if lost > 0 {
            source.timeline.insertGap(frames:UInt64(lost)); source.droppedFrames += UInt64(lost)
            hole(id,"writer",UInt64(lost))
        }
        source.tailRecorded = true
        sourceFrames[id] = source.timeline.frames; sources[id] = source
    }

    // Drain before activating a prepared input; never called from the audio callback.
    public func flush() { queue.sync {} }

    /// Pause a live source without finalizing its file. A rejected source
    /// transaction can restart its driver on this same sample timeline.
    public func pause() throws {
        lock.lock(); accepting = false; let snapshot = sources, tail = holes; lock.unlock()
        try queue.sync { try padTail(snapshot,tail) }
        lock.lock()
        // The padded tail is written: a later write must not pad or label it again.
        for (id,value) in snapshot { sources[id]?.submittedEnd = value.timeline.frames; holes.removeValue(forKey:id) }
        lock.unlock()
    }
    public func resume() throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished, !failed else { throw RecordingError.invalid(failureMessage ?? "The input cannot resume.") }
        accepting = true
    }
    private func padTail(_ snapshot: [String:Source], _ tail: [String:[Hole]]) throws {
        for (id,source) in snapshot where source.registered && source.submittedEnd < source.timeline.frames {
            var frame = source.submittedEnd
            // Each unwritten hole keeps its kind: a lost tail is writer padding
            // (D52.4 R70), a host-time gap is input; neither is received audio.
            for hole in tail[id] ?? [] where frame < source.timeline.frames {
                let frames = min(hole.frames,source.timeline.frames - frame)
                try writer.padNative(id:id,frames:frames,channels:source.outputChannels,rate:source.rate,offsetMs:source.timeline.startOffsetMs + Double(frame)/source.rate*1000,kind:hole.kind)
                frame += frames
            }
            if frame < source.timeline.frames {
                try writer.padNative(id:id,frames:source.timeline.frames-frame,channels:source.outputChannels,rate:source.rate,offsetMs:source.timeline.startOffsetMs + Double(frame)/source.rate*1000,kind:"writer")
            }
        }
    }

    public typealias Status = (levels: [String: Float], frames: [String: UInt64], droppedMs: Double, gapMs: Double, warnings: [String])

    /// UI polling must never wait for PCM conversion holding the admission lock.
    /// A skipped poll leaves meter peaks intact for the next tick.
    public func statusIfAvailable() -> Status? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return consumeStatus()
    }

    public func status() -> Status {
        lock.lock(); defer { lock.unlock() }
        return consumeStatus()
    }

    private func consumeStatus() -> Status {
        let lost = sources.values.reduce(0) { $0 + Double($1.droppedFrames) / $1.rate * 1000 }
        let gaps = sources.values.reduce(0) { $0 + Double($1.gapFrames) / $1.rate * 1000 }
        var available = levels
        for (id,var source) in sources {
            // Polling between completed 100 ms windows must not blink a live
            // source to zero. Reuse its last whole-window peak only when new
            // PCM arrived; no new samples means no fresh sound observation.
            if source.meteredFrames > source.reportedMeterFrames, available[id] == nil,
               let peak = source.lastCompletePeak { available[id] = peak }
            source.reportedMeterFrames = source.meteredFrames; sources[id] = source
        }
        let result = (available, sourceFrames, lost, gaps, warnings.sorted())
        levels = [:]
        return result
    }

    private func fail(_ message: String) {
        lock.lock()
        let first = !failed
        failed = true
        if first { failureMessage = message }
        lock.unlock()
        if first { onFailure(message) }
    }


    public func finish(problem: String?) throws { try finish(problem:problem,keepingFailure:true) }
    /// D58: drains an input that never opened (refused). Its own failure (an unsupported first
    /// buffer, a driver that failed before admitting one) is a refusal, not a recording problem,
    /// so it never reaches the writer, the owner, or the other side's recording.
    public func finishUnopened() throws { try finish(problem:nil,keepingFailure:false) }
    /// The input failed (its own failure, e.g. an unsupported buffer), whether or not its
    /// failure callback has been handled yet.
    public var hasFailed: Bool { lock.withLock { failed } }
    private func finish(problem: String?, keepingFailure: Bool) throws {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        accepting = false
        finished = true
        let snapshot = sources, tail = holes
        lock.unlock()
        try queue.sync {
            // A drop at the tail has no following chunk to create its gap. Preserve it here.
            var paddingFailure: Error?
            do {
            try padTail(snapshot,tail)
            } catch { paddingFailure = error }
            let lost = snapshot.values.reduce(0) { $0 + Double($1.droppedFrames) / $1.rate * 1000 }
            let gaps = snapshot.values.reduce(0) { $0 + Double($1.gapFrames) / $1.rate * 1000 }
            let gapNote = gaps > 0 && lost == 0 ? "Recording saved with \(Int(gaps.rounded())) ms of host-time gap; the timeline contains silence." : nil
            for (id, source) in snapshot { writer.reportLoss(id: id, droppedFrames: source.droppedFrames, gapFrames: source.gapFrames) }
            lock.lock(); let recordedFailure = keepingFailure ? failureMessage : nil; lock.unlock()
            let issue = [problem, recordedFailure == problem ? nil : recordedFailure, gapNote, paddingFailure?.localizedDescription].compactMap { $0 }.joined(separator: " ")
            try writer.finish(problem: issue.isEmpty ? nil : issue, kind: lost > 0 || paddingFailure != nil ? "io" : (gaps > 0 ? "gap" : nil))
            if let paddingFailure { throw paddingFailure }
            // An unopened input's own failure (a staged writer records it too) is its refusal's.
            // D69.2: the stored D69 writer sentence is never shown; only another diagnostic is thrown.
            if problem == nil, keepingFailure, let issue = writer.recordingProblem {
                let rest = WriterLoss.strip(issue).rest
                if !rest.isEmpty { throw RecordingError.invalid(rest) }
                // A host-time gap is still reported as it is without writer loss (the file keeps
                // only D69's sentence then, so the note is built here, not stored).
                if gaps > 0 { throw RecordingError.invalid("Recording saved with \(Int(gaps.rounded())) ms of host-time gap; the timeline contains silence.") }
            }
        }
    }
}
