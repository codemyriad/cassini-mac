// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniRecording

/// A running candidate has no file side effects until its selection commits.
/// Preparation is bounded independently of RecordingSink's active write queue.
final class StagedNativeWriter: RecordingSinkWriter, @unchecked Sendable {
    private struct Format { let id: String, label: String, kind: String; let rate: Int, channels: Int }
    private struct Chunk { let id: String; let pcm: Data; let offset: Double; var gapKind = "input"; var padding: (frames: UInt64, channels: Int, rate: Double)? = nil }
    private let lock = NSLock(), problemLock = NSLock()
    private var target: (any RecordingSinkWriter)?
    private var formats: [Format] = [], chunks: [Chunk] = []
    private var bytes = 0, discarded = false
    private var issue: String?
    var recordingProblem: String? { problemLock.withLock { issue } }
    func fail(_ message: String) { problemLock.withLock { if issue == nil { issue = message } } }
    func addTrack(id: String, label: String, kind: String, sampleRate: Int, channels: Int) throws {
        try lock.withLock {
            guard !discarded else { return }
            if let target { try target.addTrack(id:id,label:label,kind:kind,sampleRate:sampleRate,channels:channels) }
            else { formats.append(.init(id:id,label:label,kind:kind,rate:sampleRate,channels:channels)) }
        }
    }
    func appendNative(id: String, pcm: Data, offsetMs: Double) throws {
        try lock.withLock {
            guard !discarded else { return }
            if let target { try target.appendNative(id:id,pcm:pcm,offsetMs:offsetMs) }
            else {
                guard bytes + pcm.count <= 8*1024*1024 else { throw RecordingError.limit("The new audio source could not be prepared within its memory limit.") }
                chunks.append(.init(id:id,pcm:pcm,offset:offsetMs)); bytes += pcm.count
            }
        }
    }
    // D52.2/D52.4: forward the sink's gap kind and writer padding to the active writer.
    func appendNative(id: String, pcm: Data, offsetMs: Double, gapKind: String) throws {
        try lock.withLock {
            guard !discarded else { return }
            if let target { try target.appendNative(id:id,pcm:pcm,offsetMs:offsetMs,gapKind:gapKind) }
            else {
                guard bytes + pcm.count <= 8*1024*1024 else { throw RecordingError.limit("The new audio source could not be prepared within its memory limit.") }
                chunks.append(.init(id:id,pcm:pcm,offset:offsetMs,gapKind:gapKind)); bytes += pcm.count
            }
        }
    }
    func padNative(id: String, frames: UInt64, channels: Int, rate: Double, offsetMs: Double) throws {
        try lock.withLock {
            guard !discarded else { return }
            if let target { try target.padNative(id:id,frames:frames,channels:channels,rate:rate,offsetMs:offsetMs) }
            else { chunks.append(.init(id:id,pcm:Data(),offset:offsetMs,padding:(frames,channels,rate))) }
        }
    }
    func activate(_ writer: any RecordingSinkWriter) throws {
        try lock.withLock {
            guard !discarded, target == nil else { throw BrowserIPCError.closed }
            guard recordingProblem == nil else { throw RecordingError.invalid("The prepared audio input stopped before activation.") }
            target = writer
            defer { formats = []; chunks = []; bytes = 0 }
            for value in formats { try writer.addTrack(id:value.id,label:value.label,kind:value.kind,sampleRate:value.rate,channels:value.channels) }
            for value in chunks {
                if let padding = value.padding { try writer.padNative(id:value.id,frames:padding.frames,channels:padding.channels,rate:padding.rate,offsetMs:value.offset) }
                else { try writer.appendNative(id:value.id,pcm:value.pcm,offsetMs:value.offset,gapKind:value.gapKind) }
            }
        }
    }
    func discard() { lock.withLock { discarded = true; formats = []; chunks = []; bytes = 0 } }
    func reportLoss(id: String, droppedFrames: UInt64, gapFrames: UInt64) {
        lock.withLock { target?.reportLoss(id:id,droppedFrames:droppedFrames,gapFrames:gapFrames) }
    }
    func finish(problem: String?) throws { try finish(problem:problem,kind:nil) }
    func finish(problem: String?, kind: String?) throws {
        try lock.withLock {
            if let target { try target.finish(problem:problem,kind:kind) }
            discarded = true; chunks = []; formats = []; bytes = 0
        }
    }
}
