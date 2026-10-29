// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Serial writer interface, also used by deterministic tests that model a stalled disk.
public protocol RecordingSinkWriter: AnyObject {
    func addTrack(id: String, label: String, kind: String, sampleRate: Int, channels: Int) throws
    func appendNative(id: String, pcm: Data, offsetMs: Double) throws
    func finish(problem: String?) throws
    func finish(problem: String?, kind: String?) throws
    func reportLoss(id: String, droppedFrames: UInt64, gapFrames: UInt64)
    var recordingProblem: String? { get }
}

extension RecordingSinkWriter {
    public func finish(problem: String?, kind: String?) throws { try finish(problem: problem) }
    public func reportLoss(id: String, droppedFrames: UInt64, gapFrames: UInt64) {}
}

extension RecordingSession: RecordingSinkWriter {
    public var recordingProblem: String? { manifest.problem }
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
private struct ACLevelWindow {
    var left = ACLevelChannel(), right = ACLevelChannel(), count = 0
    mutating func receive(_ value: Float, channel: Int) {
        if channel == 0 { left.receive(value) } else { right.receive(value) }
    }
    mutating func endFrame(channels: Int, window: Int) -> Float? {
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
        var meter = ACLevelWindow()
        var meteredFrames: UInt64 = 0
        var reportedMeterFrames: UInt64 = 0
        var lastCompletePeak: Float?
    }
    private let queue = DispatchQueue(label: "com.codemyriad.cassini.recording-writer", qos: .userInitiated)
    private let lock = NSLock()
    private var failed = false
    private var failureMessage: String?
    private var accepting = true
    private var finished = false
    private var levels: [String: Float] = [:]
    private var sourceFrames: [String: UInt64] = [:]
    private var sources: [String: Source] = [:]
    private var warnings: Set<String> = []
    private let writer: any RecordingSinkWriter
    private let origin: UInt64
    private let capacitySeconds: Double
    private let onFailure: @Sendable (String) -> Void

    public init(session: any RecordingSinkWriter, capacitySeconds: Double = 10,
                originHostTime: UInt64 = AVAudioTime.hostTime(forSeconds: ProcessInfo.processInfo.systemUptime),
                onFailure: @escaping @Sendable (String) -> Void) {
        writer = session
        origin = originHostTime
        self.capacitySeconds = max(0.01, min(60, capacitySeconds))
        self.onFailure = onFailure
    }

    public func receive(_ buffer: AVAudioPCMBuffer, hostTime: UInt64, id: String, label: String, kind: String) {
        lock.lock()
        guard accepting, !failed, buffer.frameLength > 0 else { lock.unlock(); return }
        guard buffer.frameLength <= 65_536, buffer.format.commonFormat == .pcmFormatFloat32,
              let input = buffer.floatChannelData, (1...64).contains(buffer.format.channelCount),
              buffer.format.sampleRate.isFinite, buffer.format.sampleRate.rounded() == buffer.format.sampleRate, (8_000...192_000).contains(buffer.format.sampleRate) else {
            lock.unlock(); fail("The audio source changed to an unsupported format. The recorded audio was preserved."); return
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
        guard source.rate == rate, source.inputChannels == inputChannels else {
            lock.unlock(); fail("The audio device format changed. Start a new recording with the current device."); return
        }
        if hostTime != 0, let previous = source.lastHostOffset {
            // Detect a jump between callbacks, not accumulated slow device drift. A fixed
            // session-start lag would misclassify 10h at +50ppm (1.8s) as lost input.
            let gap = NativeSourceTimeline.missingFrames(sampleRate: rate, hostOffsetMs: hostOffset,
                                                         previousHostMs: previous, previousInputFrames: source.lastInputFrames)
            if gap > 0 {
                source.timeline.insertGap(frames: gap)
                source.gapFrames += gap
                source.meter = .init(); source.lastCompletePeak = nil; levels.removeValue(forKey:id)
                warnings.insert("\(label): a host-time gap was preserved as counted silence.")
            }
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
            sources[id] = source
            lock.unlock()
            return
        }
        source.pendingFrames += frames
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
                try writer.appendNative(id: id, pcm: pcm, offsetMs: offset)
            } catch { fail(error.localizedDescription) }
        }
        lock.unlock()
    }

    // Drain before activating a prepared input; never called from the audio callback.
    public func flush() { queue.sync {} }

    /// Pause a live source without finalizing its file. A rejected source
    /// transaction can restart its driver on this same sample timeline.
    public func pause() throws {
        lock.lock(); accepting = false; let snapshot = sources; lock.unlock()
        try queue.sync { try padTail(snapshot) }
        lock.lock()
        for (id,value) in snapshot { sources[id]?.submittedEnd = value.timeline.frames }
        lock.unlock()
    }
    public func resume() throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished, !failed else { throw RecordingError.invalid(failureMessage ?? "The input cannot resume.") }
        accepting = true
    }
    private func padTail(_ snapshot: [String:Source]) throws {
        for (id,source) in snapshot where source.registered && source.submittedEnd < source.timeline.frames {
            var frame = source.submittedEnd
            while frame < source.timeline.frames {
                let count = min(UInt64(8192),source.timeline.frames-frame)
                try writer.appendNative(id:id,pcm:Data(repeating:0,count:Int(count)*source.outputChannels*2),
                    offsetMs:source.timeline.startOffsetMs + Double(frame)/source.rate*1000)
                frame += count
            }
        }
    }

    public func status() -> (levels: [String: Float], frames: [String: UInt64], droppedMs: Double, gapMs: Double, warnings: [String]) {
        lock.lock(); defer { lock.unlock() }
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


    public func finish(problem: String?) throws {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        accepting = false
        finished = true
        let snapshot = sources
        lock.unlock()
        try queue.sync {
            // A drop at the tail has no following chunk to create its gap. Preserve it here.
            var paddingFailure: Error?
            do {
            try padTail(snapshot)
            } catch { paddingFailure = error }
            let lost = snapshot.values.reduce(0) { $0 + Double($1.droppedFrames) / $1.rate * 1000 }
            let gaps = snapshot.values.reduce(0) { $0 + Double($1.gapFrames) / $1.rate * 1000 }
            let gapNote = gaps > 0 ? "Recording saved with \(Int(gaps.rounded())) ms of host-time gap; the timeline contains silence." : nil
            for (id, source) in snapshot { writer.reportLoss(id: id, droppedFrames: source.droppedFrames, gapFrames: source.gapFrames) }
            let loss = lost > 0 ? "Recording saved with \(Int(lost.rounded())) ms of audio lost during a disk stall; the gaps contain silence." : nil
            lock.lock(); let recordedFailure = failureMessage; lock.unlock()
            let issue = [problem ?? recordedFailure, loss, gapNote, paddingFailure?.localizedDescription].compactMap { $0 }.joined(separator: " ")
            try writer.finish(problem: issue.isEmpty ? nil : issue, kind: lost > 0 || paddingFailure != nil ? "io" : (gaps > 0 ? "gap" : nil))
            if let paddingFailure { throw paddingFailure }
            if problem == nil, let issue = writer.recordingProblem { throw RecordingError.invalid(issue) }
        }
    }
}
