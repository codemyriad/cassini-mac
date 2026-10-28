// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D8/gocassini f128f37f. Empty tracks still set bandwidth, but not bitrate.
public struct AudioEncodeSource: Codable, Sendable {
    public let codec: String
    public let sampleRate: Int?
    public let speechBitrateBps: Int?
    public let empty: Bool
    public init(codec: String, sampleRate: Int?, speechBitrateBps: Int?, empty: Bool) {
        self.codec = codec; self.sampleRate = sampleRate; self.speechBitrateBps = speechBitrateBps; self.empty = empty
    }
}
public struct AudioEncodeChoice: Encodable, Equatable, Sendable {
    public let policy = "match-source"
    public let application = "audio"
    public let bitrateBps: Int
    public let cutoffHz: Int
    public let sourceBandwidthHz: Int
    public let sourceSpeechBitrateBps: Int
    public static func choose(_ sources: [AudioEncodeSource]) -> Self {
        let widest = sources.map { $0.codec.lowercased() == "opus" || ($0.sampleRate ?? 0) <= 0 ? 20000 : $0.sampleRate! / 2 }.max() ?? 0
        let bandwidth = widest > 0 ? widest : 20000
        let bands = [(4000,12000,16000),(6000,12000,20000),(8000,16000,32000),(12000,20000,48000),(20000,24000,64000)]
        let band = bands.first { $0.0 >= bandwidth } ?? bands.last!
        let active = sources.filter { !$0.empty }
        let measured = !active.isEmpty && active.allSatisfy { ($0.speechBitrateBps ?? 0) > 0 }
        let speech = max(0,active.compactMap(\.speechBitrateBps).max() ?? 0)
        let bitrate: Int
        if measured {
            let desired = ceil(Double(speech) * (4.0 / 3.0) / 1000) * 1000
            bitrate = Int(min(Double(band.2),max(Double(band.1),desired)))
        } else { bitrate = band.2 }
        return .init(bitrateBps:bitrate,cutoffHz:band.0,sourceBandwidthHz:bandwidth,sourceSpeechBitrateBps:speech)
    }
    /// Source packet bps histogram, not a silence-heavy whole-file average.
    /// Opus per-channel rates come from the TOC coded-channel bit.
    public static func speechBitrate(histogram: [Int:Int]) -> Int? {
        let positive = histogram.filter { $0.key >= 0 && $0.value > 0 }
        let total = positive.values.reduce(0.0) { $0 + Double($1) }
        guard total >= 50, total <= Double(Int.max - 1024) else { return nil }
        let rank = Int(0.9 * total)
        var seen = 0, p90 = 0
        for rate in positive.keys.sorted() {
            seen += positive[rate]!
            if seen > rank { p90 = rate; break }
        }
        let selected = positive.filter { Double($0.key) * 2 >= Double(p90) }
        let count = selected.values.reduce(0.0) { $0 + Double($1) }
        guard count > 0 else { return nil }
        let result = selected.reduce(0.0) { $0 + Double($1.key) * Double($1.value) } / count
        return Int(min(Double(Int.max - 1024),result.rounded(.toNearestOrAwayFromZero)))
    }
}
