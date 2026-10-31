// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import Accelerate
import os
import CassiniRecording

/// A session-local bounded consumer. Input callbacks only retain immutable S16
/// bytes and reserve a one-second budget; conversion/FFT run on utility work.
/// The display coordinator asks for one batch per frame and fans it out to the
/// pill/rows. There are no per-column main-thread notifications or timers.
public final class SpectrogramSession: RecordedPCMObserver, @unchecked Sendable {
    private struct Pending { var bytes = 0, packets = 0 }
    private struct Admission {
        var visible = false, accepting = true
        var generation: UInt64 = 0, dropped: UInt64 = 0
        var pending: [String:Pending] = [:]
    }
    private final class Source {
        let descriptor: RecordedPCMSource, index: Int, lane: SpectrogramLane, track: SpectrogramTrack
        var active = true
        var arrival: Double
        init(_ descriptor: RecordedPCMSource, index: Int, transform: SpectrogramTransform, arrival: Double) {
            self.descriptor = descriptor; self.index = index; self.arrival = arrival
            lane = ["microphone","local"].contains(descriptor.kind) ? .me : .others
            track = .init(parameters:transform.parameters,startOffsetMs:descriptor.startOffsetMs,transform:transform)
        }
    }
    private static let signposts = OSLog(subsystem:"io.codemyriad.cassini",category:"Spectrogram")
    private let state = OSAllocatedUnfairLock(initialState:Admission())
    private let queue = DispatchQueue(label:"io.codemyriad.cassini.spectro",qos:.utility)
    private let clock: @Sendable () -> Double
    private let measureCPU: Bool
    private struct Presentation {
        var generation: UInt64 = 0
        var me = SpectrogramLaneAccumulator(), others = SpectrogramLaneAccumulator()
        var clock = SpectrogramDisplayClock()
        let mailbox = SpectrogramMailbox()
        var analyzedFrames: UInt64 = 0, analysisNanoseconds: UInt64 = 0
        var retainedTracks = 0
        var stoppedAt: Double?
        var lateSamples: [LateColumn] = []
        mutating func reset(generation value: UInt64) {
            guard value > generation else { return }
            generation = value; me.reset(); others.reset(); clock.reset(); mailbox.reset()
            analyzedFrames = 0; retainedTracks = 0; lateSamples.removeAll(keepingCapacity:true)
        }
    }
    // FFTs never run under this lock. A display link drains ready powers at its
    // own timestamp without dispatching to the analysis queue and back.
    private let presentation = OSAllocatedUnfairLock(uncheckedState:Presentation())
    // Everything below belongs only to queue.
    private var generation: UInt64 = .max
    private var sources: [String:Source] = [:]
    private var endedIDs: Set<String> = []
    private var endedOrder: [String] = []
    private var occupiedIndices: UInt64 = 0
    private var retiredAnalyzedFrames: UInt64 = 0
    private var transforms: [Int:SpectrogramTransform] = [:]
    private var meSelection = SpectrogramSelection(), othersSelection = SpectrogramSelection()
    private var mono: [Float] = [], right: [Float] = []
    private var alignedPCM: [Int16] = []
    private var nextChoiceAt: Double = 0

    public init(originUptime: TimeInterval, measureCPU: Bool = false) {
        self.measureCPU = measureCPU
        precondition(originUptime.isFinite)
        clock = { max(0,(ProcessInfo.processInfo.systemUptime-originUptime)*1000) }
    }
    public init(clock: @escaping @Sendable () -> Double, measureCPU: Bool = false) { self.clock = clock; self.measureCPU = measureCPU }
    /// Called by the session's view coordinator only when its aggregate visible
    /// subscriber count crosses zero. The old generation cannot repopulate it.
    public func setVisible(_ value: Bool) {
        let change = state.withLock { valueState -> UInt64? in
            guard valueState.visible != value else { return nil }
            valueState.visible = value; valueState.generation &+= 1; valueState.dropped = 0
            return valueState.generation
        }
        guard let change else { return }
        presentation.withLock { $0.reset(generation:change) }
        queue.async { [self] in
            guard state.withLock({ $0.generation == change }) else { return }
            ensureGeneration(change)
        }
    }
    public func offer(source: RecordedPCMSource, pcm: Data, offsetMs: Double) {
        guard offsetMs.isFinite, offsetMs >= 0, !pcm.isEmpty, pcm.count <= 262144, pcm.count%(source.channels*2) == 0 else { return }
        let admitted = state.withLock { value -> UInt64? in
            guard value.visible, value.accepting else { return nil }
            var pending = value.pending[source.id,default:.init()]
            guard value.pending.count < 64 || pending.bytes > 0,
                  pending.packets < 64,
                  pending.bytes+pcm.count <= source.sampleRate*source.channels*2 else { value.dropped &+= 1; return nil }
            pending.bytes += pcm.count; pending.packets += 1
            value.pending[source.id] = pending
            return value.generation
        }
        guard let admitted else { return }
        queue.async { [self,pcm] in
            defer {
                state.withLock { value in
                    // Reservations belong to retained dispatch closures, not
                    // the view generation. Hiding cannot release their Data.
                    var remaining = value.pending[source.id,default:.init()]
                    remaining.bytes -= pcm.count; remaining.packets -= 1
                    if remaining.packets > 0 { value.pending[source.id] = remaining }
                    else { value.pending.removeValue(forKey:source.id) }
                }
            }
            guard state.withLock({ $0.visible && $0.generation == admitted }) else { return }
            ensureGeneration(admitted)
            consume(source,pcm:pcm,offsetMs:offsetMs)
        }
    }
    public func sourceEnded(id: String) {
        queue.async { [self] in
            if endedIDs.insert(id).inserted {
                endedOrder.append(id)
                if endedOrder.count > 64 { endedIDs.remove(endedOrder.removeFirst()) }
            }
            guard let source = sources.removeValue(forKey:id) else { return }
            retiredAnalyzedFrames += source.track.analyzedFrames
            if !sources.values.contains(where:{ $0.descriptor.sampleRate == source.descriptor.sampleRate }) {
                transforms.removeValue(forKey:source.descriptor.sampleRate)
            }
            occupiedIndices &= ~(UInt64(1)<<source.index)
            // Pending old powers remain visible. Only their duplicate guard is
            // released so a replacement can share a slot without losing data.
            let sourceLane = source.lane, sourceIndex = source.index
            presentation.withLock { value in
                guard value.generation == generation else { return }
                (sourceLane == .me ? value.me : value.others).retire(trackIndex:sourceIndex)
                value.retainedTracks = sources.count
            }
            nextChoiceAt = 0
            if source.lane == .me { meSelection.reset() } else { othersSelection.reset() }
        }
    }
    /// Bounded timing evidence for the isolated performance probe. Ordinary
    /// sessions leave this empty and never collect source or window metadata.
    public struct LateColumn: Sendable {
        public let ordinal: UInt64
        public let slot: Int64, releasedThrough: Int64
        public let arrivalMs: Double, delayMs: Double
    }
    public struct Frame: Sendable {
        public let me: [SpectrogramColumn], others: [SpectrogramColumn]
        public let displayMs: Double, delayMs: Double
        public let analyzedFrames: UInt64, lateColumns: UInt64, droppedBuffers: UInt64, droppedColumns: UInt64
        public let retainedTracks: Int
        public let analysisNanoseconds: UInt64
        public let lateSamples: [LateColumn]
    }
    /// A queue barrier for producers/tests that need all prior offers consumed.
    /// The native display link instead calls pollFrame, which never waits for
    /// queued PCM conversion or FFT work. Completion stays on the utility queue.
    public func requestFrame(nowMs: Double, completion: @escaping @Sendable (Frame) -> Void) {
        queue.async { [self] in
            ensureGeneration(state.withLock { $0.generation })
            completion(pollFrame(nowMs:nowMs))
        }
    }
    /// Drain only ready analysis. The short presentation critical section never
    /// contains FFT, IO, capture callbacks or user code. The same timestamp,
    /// delay, power-sum/release and bounded mailbox rules serve both read paths.
    public func pollFrame(nowMs: Double) -> Frame {
        let cpuStart = measureCPU ? clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) : 0
        let status = state.withLock { ($0.visible,$0.generation,$0.dropped) }
        return presentation.withLock { value in
            guard value.generation == status.1 else {
                return .init(me:[],others:[],displayMs:0,delayMs:40,analyzedFrames:0,lateColumns:0,
                    droppedBuffers:status.2,droppedColumns:0,retainedTracks:0,
                    analysisNanoseconds:value.analysisNanoseconds,lateSamples:[])
            }
            let now = nowMs.isFinite ? max(0,min(nowMs,value.stoppedAt ?? nowMs)) : 0
            let display = value.clock.advance(nowMs:now)
            if status.0 {
                let slot = Int64(floor(display/20)), mailbox = value.mailbox
                value.me.release(through:slot) { mailbox.append($0,lane:.me) }
                value.others.release(through:slot) { mailbox.append($0,lane:.others) }
            }
            let batch = value.mailbox.drain()
            // Include analysis work performed by the display's drain as well as
            // utility FFT work. Moving it cannot make the CPU gate disappear.
            if measureCPU { value.analysisNanoseconds &+= clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)-cpuStart }
            return .init(me:batch.me,others:batch.others,displayMs:display,delayMs:value.clock.delayMs,
                analyzedFrames:value.analyzedFrames,lateColumns:value.me.late+value.others.late,
                droppedBuffers:status.2,droppedColumns:value.me.overflow+value.others.overflow+batch.droppedMe+batch.droppedOthers,
                retainedTracks:value.retainedTracks,analysisNanoseconds:value.analysisNanoseconds,lateSamples:value.lateSamples)
        }
    }
    public func stop(atMs: Double) {
        guard atMs.isFinite, atMs >= 0 else { return }
        state.withLock { $0.accepting = false }
        presentation.withLock { $0.stoppedAt = atMs }
    }
    private func ensureGeneration(_ value: UInt64) {
        guard generation != value else { return }
        generation = value; sources = [:]; transforms = [:]; mono = []; right = []; alignedPCM = []
        occupiedIndices = 0; retiredAnalyzedFrames = 0
        meSelection.reset(); othersSelection.reset(); nextChoiceAt = 0
    }
    private func consume(_ descriptor: RecordedPCMSource, pcm: Data, offsetMs: Double) {
        guard !endedIDs.contains(descriptor.id) else { return }
        let cpuStart = measureCPU ? clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) : 0
        defer {
            let frames = sources.values.reduce(retiredAnalyzedFrames) { $0+$1.track.analyzedFrames }
            let elapsed = measureCPU ? clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)-cpuStart : 0
            presentation.withLock { value in
                value.analysisNanoseconds &+= elapsed
                if value.generation == generation { value.analyzedFrames = frames; value.retainedTracks = sources.count }
            }
        }
        let interval = OSSignpostID(log:Self.signposts,object:self)
        os_signpost(.begin,log:Self.signposts,name:"Spectrogram analysis",signpostID:interval)
        defer { os_signpost(.end,log:Self.signposts,name:"Spectrogram analysis",signpostID:interval) }
        let arrival = clock()
        guard arrival.isFinite, arrival >= 0,
              state.withLock({ $0.visible && $0.generation == generation }) else { return }
        let inserted = sources[descriptor.id] == nil
        if inserted {
            guard sources.count < 64, let parameters = try? SpectrogramParameters(rate:descriptor.sampleRate) else { return }
            let transform = transforms[descriptor.sampleRate] ?? SpectrogramTransform(parameters:parameters)
            transforms[descriptor.sampleRate] = transform
            let index = (~occupiedIndices).trailingZeroBitCount
            occupiedIndices |= UInt64(1)<<index
            sources[descriptor.id] = Source(descriptor,index:index,transform:transform,arrival:arrival)
        }
        guard let source = sources[descriptor.id], source.active, source.descriptor == descriptor else { return }
        source.arrival = arrival
        if inserted || arrival >= nextChoiceAt {
            let active = sources.values.filter { $0.active && arrival-$0.arrival <= 1000 }
            meSelection.choose(levels:Dictionary(uniqueKeysWithValues:active.filter{$0.lane == .me}.map{($0.index,$0.track.latestLevel)}),nowMs:arrival)
            othersSelection.choose(levels:Dictionary(uniqueKeysWithValues:active.filter{$0.lane == .others}.map{($0.index,$0.track.latestLevel)}),nowMs:arrival)
            if arrival >= nextChoiceAt { nextChoiceAt = arrival+1000 }
        }
        let analyze = source.lane == .me ? meSelection.tracks.contains(source.index) : othersSelection.tracks.contains(source.index)
        let total = pcm.count/(descriptor.channels*2)
        let start = ((offsetMs-descriptor.startOffsetMs)*Double(descriptor.sampleRate)/1000).rounded()
        guard start >= Double(Int64.min/2), start < Double(Int64.max/2) else { return }
        let original = Int64(start), trim = Int(min(Int64(total),max(0,-original)))
        guard trim < total else { return }
        let count = total-trim
        if mono.count < count { mono = [Float](repeating:0,count:count); right = mono }
        pcm.withUnsafeBytes { bytes in
            let first = bytes.baseAddress!+trim*descriptor.channels*2
            if UInt(bitPattern:first)%UInt(MemoryLayout<Int16>.alignment) == 0 {
                convert(first.assumingMemoryBound(to:Int16.self),frames:count,channels:descriptor.channels)
            } else {
                // Data slices need not be aligned. Only that unusual case pays
                // for an aligned copy, on this utility queue rather than IO.
                let samples = count*descriptor.channels
                if alignedPCM.count < samples { alignedPCM = [Int16](repeating:0,count:samples) }
                alignedPCM.withUnsafeMutableBytes { $0.baseAddress!.copyMemory(from:first,byteCount:samples*2) }
                alignedPCM.withUnsafeBufferPointer { convert($0.baseAddress!,frames:count,channels:descriptor.channels) }
            }
        }
        let sourceLane = source.lane, sourceIndex = source.index
        mono.withUnsafeBufferPointer { samples in
            source.track.appendNormalized(.init(start:samples.baseAddress,count:count),atFrame:max(0,original),
                analyze:analyze) { frame in
                // Release is keyed by the containing20ms slot, not the later
                // FFT centre within it. Measure readiness on that same clock.
                presentation.withLock { value in
                    guard value.generation == generation else { return }
                    value.clock.observe(columnMs:Double(frame.slot)*20,arrivalMs:arrival)
                    let lane = sourceLane == .me ? value.me : value.others
                    if measureCPU, frame.slot <= lane.releasedThrough {
                        if value.lateSamples.count == 16 { value.lateSamples.removeFirst() }
                        value.lateSamples.append(.init(ordinal:value.me.late+value.others.late+1,slot:frame.slot,
                            releasedThrough:lane.releasedThrough,arrivalMs:arrival,delayMs:value.clock.delayMs))
                    }
                    lane.append(slot:frame.slot,trackIndex:sourceIndex,powers:frame.powers)
                }
            }
        }
    }
    private func convert(_ input: UnsafePointer<Int16>, frames count: Int, channels: Int) {
        // Borrow each workspace once: passing mono both as an Array input and
        // an inout output forces a copy before otherwise in-place vDSP calls.
        mono.withUnsafeMutableBufferPointer { destination in
            let output = destination.baseAddress!, length = vDSP_Length(count)
            vDSP_vflt16(input,vDSP_Stride(channels),output,1,length)
            var scale: Float = 1/32768
            if channels == 2 {
                right.withUnsafeMutableBufferPointer { second in
                    vDSP_vflt16(input+1,2,second.baseAddress!,1,length)
                    vDSP_vadd(output,1,second.baseAddress!,1,output,1,length)
                }
                scale /= 2
            }
            vDSP_vsmul(output,1,&scale,output,1,length)
        }
    }

}
