// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import CassiniWhistle
import CassiniTranscription

/// D11.5 is deliberately narrower than a text-normalisation rule. The actual
/// recognizer output is never changed; this is only a golden-test exception.
struct WhistleTextExceptions: Decodable {
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
        let allowedWords: [String]
        let expectedSegmentText: String, actualSegmentText: String
    }
    static func load(_ root: URL) throws -> Self {
        let bytes = try Data(contentsOf: root.appendingPathComponent("whistle-text-exceptions.json"))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == "448aeaeaae178621e3296bc9cdc0463172bbdc35525aed74becdef31541c0b56" else { throw TranscriptionFailure.runtime("unapproved text exception manifest") }
        let policy = try JSONDecoder().decode(Self.self, from: bytes)
        let pins = WhistleAssets.sourcePins
        guard policy.version == 1, policy.decision == "D11.5", policy.platform == "any",
              policy.enginePins["engineVersion"] == pins["engineVersion"],
              policy.enginePins["modelSha256"] == pins["modelSha256"],
              policy.enginePins["macArm64LibrarySha256"] == pins["arm64LibrarySha256"],
              policy.enginePins["macX86_64LibrarySha256"] == pins["x86_64LibrarySha256"],
              policy.enginePins.count == 5, policy.enginePins["linuxX86_64LibneedleSha256"] != nil,
              policy.exceptions.count == 1,
              policy.exceptions[0].allowedWords == [policy.exceptions[0].expectedWord,policy.exceptions[0].actualWord] else {
            throw TranscriptionFailure.runtime("text exception does not match this engine")
        }
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
        return scoped.allowedWords.contains(actual) && expected == scoped.expectedWord
    }
}
