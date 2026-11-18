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

    public static func follow(_ input: AsyncStream<LivePCMEvent>, worker: WhistleSubprocess.WindowSession,
                              update: @Sendable (Revision) -> Void) async throws {
        try await follow(input, decode: worker.decode, update: update)
    }

    static func follow(_ input: AsyncStream<LivePCMEvent>,
                       decode: @Sendable ([Float]) async throws -> WhistleTranscript,
                       update: @Sendable (Revision) -> Void) async throws {
        var spans: [String: Span] = [:]
        for await event in input {
            try Task.checkCancellation()
            switch event {
            case let .ended(id):
                if var span = spans.removeValue(forKey: id) {
                    try await span.finish(recognize: decode, update: update)
                }
            case let .audio(source, pcm, offset):
                guard [16_000, 48_000].contains(source.sampleRate) else { continue }
                let frameBytes = source.channels * 2
                guard !pcm.isEmpty, pcm.count.isMultiple(of: frameBytes) else { continue }
                let position = max(0, Int64(((offset - source.startOffsetMs) * Double(source.sampleRate) / 1000).rounded()))
                var span = try spans.removeValue(forKey: source.id) ?? Span(source, frame: position)
                if position != span.nextFrame {
                    if position < span.nextFrame {
                        spans[source.id] = span
                        continue
                    }
                    try await span.finish(recognize: decode, update: update)
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
                let resampled = span.resampler.feed(samples)
                try await span.accept(resampled, recognize: decode, update: update)
                spans[source.id] = span
            }
        }
        try Task.checkCancellation()
        for var span in spans.values { try await span.finish(recognize: decode, update: update) }
    }

    private struct Span {
        let source: RecordedPCMSource
        var resampler: MeetingResampler
        var nextFrame: Int64
        let originMs: Double
        var start = 0
        var settledMs: Double
        var window: [Float] = []
        var pending = 0
        let cadence = 24_000

        init(_ source: RecordedPCMSource, frame: Int64) throws {
            self.source = source
            resampler = try MeetingResampler(rate: source.sampleRate)
            nextFrame = frame
            originMs = source.startOffsetMs + Double(frame) * 1000 / Double(source.sampleRate)
            settledMs = originMs
        }

        mutating func accept(_ samples: [Float], recognize: @Sendable ([Float]) async throws -> WhistleTranscript,
                             update: (Revision) -> Void) async throws {
            var at = 0
            while at < samples.count {
                let count = min(cadence - pending, samples.count - at)
                window.append(contentsOf: samples[at..<at + count])
                pending += count
                at += count
                if pending == cadence { try await decode(recognize: recognize, final: false, update: update) }
            }
        }

        mutating func finish(recognize: @Sendable ([Float]) async throws -> WhistleTranscript, update: (Revision) -> Void) async throws {
            let last = resampler.feed([], final: true)
            try await accept(last, recognize: recognize, update: update)
            try await decode(recognize: recognize, final: true, update: update)
        }

        mutating func decode(recognize: @Sendable ([Float]) async throws -> WhistleTranscript, final: Bool,
                             update: (Revision) -> Void) async throws {
            guard !window.isEmpty else { return }
            try Task.checkCancellation()
            let result = window.contains(where: { $0 != 0 }) ? try await recognize(window).words ?? [] : []
            try Task.checkCancellation()
            let from = originMs + Double(start) / 16
            let through = from + Double(window.count) / 16
            let words = result.compactMap { item -> WhistleTranscript.Word? in
                guard item.start.isFinite, item.end.isFinite else { return nil }
                let begin = min(through, from + max(0, item.start * 1000))
                let end = min(through, from + max(0, item.end * 1000))
                guard end >= begin, begin + (end - begin) / 2 >= settledMs else { return nil }
                return .init(word: item.word, start: begin / 1000, end: end / 1000, probability: item.probability)
            }
            let boundary = final ? through : max(settledMs, through - 2000)
            update(Revision(source: source.id, fromMs: settledMs, throughMs: through, settledMs: boundary, words: words))
            settledMs = boundary
            pending = 0
            if !final {
                let trim = max(0, window.count - (LiveWindowProtocol.sampleLimit - cadence))
                window.removeFirst(trim)
                start += trim
            }
        }
    }
}
