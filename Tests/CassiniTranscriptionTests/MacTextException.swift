// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import CassiniWhistle
import CassiniTranscription

/// D11.4 is deliberately narrower than a text-normalisation rule. The actual
/// recognizer output is never changed; this is only a golden-test exception.
struct MacTextExceptions: Decodable {
    let version: Int
    let decision: String
    let platform: String
    let enginePins: [String:String]
    let exceptions: [Entry]
    struct Entry: Decodable {
        let golden: String, goldenSha256: String
        let segmentIndex: Int, startSample: Int, endSample: Int
        let segmentInputSha256: String
        let wordIndex: Int
        let expectedWord: String, actualWord: String
        let expectedSegmentText: String, actualSegmentText: String
    }
    static func load(_ root: URL) throws -> Self {
        let bytes = try Data(contentsOf: root.appendingPathComponent("mac-text-exceptions.json"))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == "5ec26f54bfc5e6e73f3c25e91f74aa37610b20b8f2aa43ea1f423bfca41a9b39" else { throw TranscriptionFailure.runtime("unapproved text exception manifest") }
        let policy = try JSONDecoder().decode(Self.self, from: bytes)
        guard policy.version == 1, policy.decision == "D11.4", policy.platform == "macos", policy.enginePins == WhistleAssets.sourcePins,
              policy.exceptions.count == 1 else { throw TranscriptionFailure.runtime("text exception does not match this engine") }
        return policy
    }
    func entry(golden: String, goldenHash: String, segmentIndex: Int, segment: SpeechSegment, actualHash: String, referenceHash: String) -> Entry? {
        exceptions.first { $0.golden == golden && $0.goldenSha256 == goldenHash && $0.segmentIndex == segmentIndex &&
            $0.startSample == segment.startSample && $0.endSample == segment.endSample && segment.reason == "silence" &&
            $0.segmentInputSha256 == actualHash && actualHash == referenceHash }
    }
    func permitsWord(golden: String, goldenHash: String, index: Int, actual: String, expected: String,
                     segments: [SpeechSegment], hashes: [[String:String]]) -> Bool {
        guard let rule = exceptions.first, index == rule.wordIndex, segments.indices.contains(rule.segmentIndex), hashes.indices.contains(rule.segmentIndex),
              let actualHash = hashes[rule.segmentIndex]["actual"], let expectedHash = hashes[rule.segmentIndex]["expected"],
              let scoped = entry(golden: golden, goldenHash: goldenHash, segmentIndex: rule.segmentIndex, segment: segments[rule.segmentIndex], actualHash: actualHash, referenceHash: expectedHash) else { return false }
        return actual == scoped.actualWord && expected == scoped.expectedWord
    }
}
