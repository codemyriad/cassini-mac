// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniRecording
import CassiniWhistle

/// App-local preview only. Final transcription still reads the saved meeting.
public enum LiveCaptureTranscription {
    public struct Revision: Sendable {
        public let source: String
        public let fromMs: Double
        public let throughMs: Double
        public let settledMs: Double
        public let words: [WhistleTranscript.Word]
    }

    private struct Work: Sendable {
        let source: String
        let span: UUID
        let origin: Double
        let start: Double
        let samples: [Float]
        let final: Bool
        var end: Double { start + Double(samples.count) / 16 }
    }

    /// A busy recognizer skips superseded windows, so it never holds up the audio reader.
    private actor Mailbox {
        private var pending: [Work] = []
        let wake: AsyncStream<Void>.Continuation
        init(_ wake: AsyncStream<Void>.Continuation) { self.wake = wake }

        func offer(_ work: Work) {
            if let index = pending.firstIndex(where: { $0.span == work.span }) {
                pending[index] = work
            } else {
                if pending.count == 64 { pending.removeFirst() }
                pending.append(work)
            }
            wake.yield()
        }

        func next() -> Work? { pending.isEmpty ? nil : pending.removeFirst() }
    }

    public static func follow(_ input: AsyncStream<LivePCMEvent>, worker: WhistleSubprocess.WindowSession,
                              update: @Sendable (Revision) -> Void) async throws {
        try await follow(input, decode: worker.decode, update: update)
    }

    static func follow(_ input: AsyncStream<LivePCMEvent>,
                       decode: @Sendable ([Float]) async throws -> WhistleTranscript,
                       update: @Sendable (Revision) -> Void) async throws {
        let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let mailbox = Mailbox(wake)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                defer { wake.finish() }
                try await ingest(input, mailbox: mailbox)
            }
            var settled: [String: (UUID, Double)] = [:]
            for await _ in wakes {
                while let work = await mailbox.next() {
                    try Task.checkCancellation()
                    let result: [WhistleTranscript.Word]
                    do {
                        result = work.samples.count >= 4800 && work.samples.contains(where: { $0 != 0 })
                            ? try await decode(work.samples).words ?? [] : []
                    } catch WhistleSubprocess.WindowSession.RequestFailure.rejected {
                        continue
                    }
                    try Task.checkCancellation()
                    let previous = settled[work.source]
                    let from = max(work.start, previous?.0 == work.span ? previous!.1 : work.origin)
                    let words = result.compactMap { item -> WhistleTranscript.Word? in
                        guard item.start.isFinite, item.end.isFinite else { return nil }
                        let begin = min(work.end, work.start + max(0, item.start * 1000))
                        let end = min(work.end, work.start + max(0, item.end * 1000))
                        let midpoint = begin + (end - begin) / 2
                        guard end >= begin, from <= midpoint, midpoint < work.end else { return nil }
                        return .init(word: item.word, start: begin / 1000, end: end / 1000, probability: item.probability)
                    }
                    let boundary = work.final ? work.end : max(from, work.end - 2000)
                    update(Revision(source: work.source, fromMs: from, throughMs: work.end,
                                    settledMs: boundary, words: words))
                    settled[work.source] = (work.span, boundary)
                }
            }
            try await group.waitForAll()
        }
    }

    private static func ingest(_ input: AsyncStream<LivePCMEvent>, mailbox: Mailbox) async throws {
        var spans: [String: Span] = [:]
        for await event in input {
            try Task.checkCancellation()
            switch event {
            case let .ended(id):
                if var span = spans.removeValue(forKey: id), let last = span.finish() {
                    await mailbox.offer(last)
                }
            case let .audio(source, pcm, offset):
                guard [16_000, 48_000].contains(source.sampleRate), offset.isFinite else { continue }
                let frameBytes = source.channels * 2
                guard !pcm.isEmpty, pcm.count.isMultiple(of: frameBytes) else { continue }
                let position = max(0, Int64(((offset - source.startOffsetMs) * Double(source.sampleRate) / 1000).rounded()))
                var span = try spans.removeValue(forKey: source.id) ?? Span(source, frame: position)
                if position != span.nextFrame {
                    if position < span.nextFrame {
                        spans[source.id] = span
                        continue
                    }
                    if let last = span.finish() { await mailbox.offer(last) }
                    span = try Span(source, frame: position)
                }
                let samples = pcm.withUnsafeBytes { bytes in
                    (0..<(pcm.count / frameBytes)).map { frame -> Float in
                        let offset = frame * frameBytes
                        let left = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
                        if source.channels == 1 { return left / 32768 }
                        let right = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 2, as: Int16.self)))
                        return (left + right) / 65536
                    }
                }
                span.nextFrame += Int64(samples.count)
                if let work = span.accept(samples) { await mailbox.offer(work) }
                spans[source.id] = span
            }
        }
        try Task.checkCancellation()
        for var span in spans.values {
            if let last = span.finish() { await mailbox.offer(last) }
        }
    }

    private struct Span {
        let source: RecordedPCMSource
        let id = UUID()
        var resampler: MeetingResampler
        var nextFrame: Int64
        let originMs: Double
        var start = 0
        var window: [Float] = []
        var pending = 0
        let cadence = 24_000

        init(_ source: RecordedPCMSource, frame: Int64) throws {
            self.source = source
            resampler = try MeetingResampler(rate: source.sampleRate)
            nextFrame = frame
            originMs = source.startOffsetMs + Double(frame) * 1000 / Double(source.sampleRate)
        }

        mutating func accept(_ samples: [Float]) -> Work? {
            let pcm = resampler.feed(samples)
            append(pcm)
            guard pending >= cadence else { return nil }
            pending %= cadence
            return work(final: false)
        }

        mutating func finish() -> Work? {
            let last = resampler.feed([], final: true)
            append(last)
            return window.isEmpty ? nil : work(final: true)
        }

        mutating func append(_ samples: [Float]) {
            window.append(contentsOf: samples)
            pending += samples.count
            let trim = max(0, window.count - LiveWindowProtocol.sampleLimit)
            window.removeFirst(trim)
            start += trim
        }

        func work(final: Bool) -> Work {
            Work(source: source.id, span: id, origin: originMs, start: originMs + Double(start) / 16,
                 samples: window, final: final)
        }
    }
}
