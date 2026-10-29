// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniWhistle
import CassiniVAD

public enum TranscriptionFailure: Error { case audioFormat, invalidMeeting, runtime(String) }

/// D11's centred FIR, bounded to a decoder batch plus its 96-sample overlap.
public struct MeetingResampler {
    private let coefficients: [Float]
    private let rate: Int
    private var samples: [Float] = []
    private var base = 0, count = 0, next = 0
    public init(rate: Int) throws {
        guard rate == 16000 || rate == 48000 else { throw TranscriptionFailure.audioFormat }
        self.rate = rate
        struct Filter: Decodable { let coefficients: [Float] }
        coefficients = try JSONDecoder().decode(Filter.self, from: Data(contentsOf: Bundle.module.url(forResource: "fir-48k-16k", withExtension: "json", subdirectory: "Resources")!)).coefficients
        guard coefficients.count == 97 else { throw TranscriptionFailure.audioFormat }
    }
    public mutating func feed(_ input: [Float], final: Bool = false) -> [Float] {
        if rate == 16000 { return input }
        samples.append(contentsOf: input); count += input.count
        var output: [Float] = []
        let limit = final ? (count + 2) / 3 : max(0, (count - 49) / 3 + 1)
        while next < limit {
            var value: Double = 0
            for n in 0..<97 {
                let index = 3 * next + 48 - n
                if index >= 0 && index < count { value += Double(coefficients[n]) * Double(samples[index - base]) }
            }
            output.append(Float(value)); next += 1
        }
        let remove = min(samples.count, max(0, next * 3 - 48 - base))
        samples.removeFirst(remove); base += remove
        return output
    }
}

/// D26.1 / WebRTC APM: binary64 Direct Form I, left-to-right, without FMA.
/// Only Silero sees this signal. The recognisers and mono.f32 retain raw PCM.
struct SileroInputHighPass {
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    mutating func process(_ frame: [Float]) -> [Float] {
        frame.map { sample in
            let x = Double(sample)
            var y = 0.9726138984998437 * x
            y += -1.9452277969996874 * x1
            y += 0.9726138984998437 * x2
            y -= -1.9444776577670935 * y1
            y -= 0.9459779362322813 * y2
            if y > -1e-25 && y < 1e-25 { y = 0 }
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return Float(y)
        }
    }
}
public final class SpeechDetector {
    public static let inputFilterVersion = "silero-input-hpf-butter2-100hz-v1"
    private let detector: OpaquePointer
    private var inputFilter = SileroInputHighPass()
    public init(assets: VADAssets) throws {
        try WhistleEnvironment.validateLive()
        var error = [CChar](repeating: 0, count: 2048)
        guard let detector = cassini_vad_create(assets.library.path, assets.model.path, &error, error.count) else { throw TranscriptionFailure.runtime(String(cString: error)) }
        self.detector = detector
    }
    deinit { cassini_vad_destroy(detector) }
    public func reset() { inputFilter = .init(); cassini_vad_reset(detector) }
    public func probability(_ frame: [Float]) throws -> Float {
        guard frame.count == 512 else { throw TranscriptionFailure.audioFormat }
        let filtered = inputFilter.process(frame)
        var value: Float = 0, error = [CChar](repeating: 0, count: 2048)
        guard cassini_vad_probability(detector, filtered, &value, &error, error.count) == 1 else { throw TranscriptionFailure.runtime(String(cString: error)) }
        return value
    }
}
public struct SpeechSegment: Codable, Equatable, Sendable {
    public let startSample: Int
    public let endSample: Int
    public let reason: String
}
/// Exact cassini-live SpeechGate decisions. Live's one-second handoff chunks are
/// aggregated into contiguous ranges; no samples are replayed or resynthesised.
public struct SpeechGate {
    private var tail: [Float] = [], pre: [[Float]] = [], votes: [Bool] = []
    private var active = false, quiet = 0, duration = 0, position = 0, start = 0
    public init() {}
    public mutating func feed(_ samples: [Float], probability: ([Float]) throws -> Float) rethrows -> [SpeechSegment] {
        tail.append(contentsOf: samples)
        var segments: [SpeechSegment] = [], consumed = 0
        while tail.count - consumed >= 512 {
            let frame = Array(tail[consumed..<consumed + 512]); consumed += 512; position += 512
            let voiced = try probability(frame) >= (active ? 0.35 : 0.5)
            if !active {
                pre.append(frame); if pre.count > 10 { pre.removeFirst() }
                votes.append(voiced); if votes.count > 3 { votes.removeFirst() }
                guard votes.filter({ $0 }).count >= 2 else { continue }
                active = true; duration = pre.count * 512; start = position - duration
                pre.removeAll(keepingCapacity: true); votes.removeAll(keepingCapacity: true)
            } else { duration += 512 }
            quiet = voiced ? 0 : quiet + 1
            let reason: String?
            if quiet * 512 >= 9600 { reason = "silence" }
            else if duration >= 224000 && quiet * 512 >= 2048 { reason = "durationPause" }
            else if duration >= 240000 { reason = "durationLimit" }
            else { reason = nil }
            if let reason {
                segments.append(.init(startSample: start, endSample: position, reason: reason)); active = false; quiet = 0
            }
        }
        tail.removeFirst(consumed)
        return segments
    }
    public mutating func flush() -> [SpeechSegment] {
        let result: [SpeechSegment] = active ? [.init(startSample: start, endSample: position + tail.count, reason: "flush")] : []
        self = Self(); return result
    }
}
