// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import CassiniTranscription
import CassiniLibrary
import CassiniWhistle

/// Wave 0 shared head-start transcription vector conformance tests (D-1117 / D109 / D111 / D-1122).
final class HeadStartVectorTests: XCTestCase {
    private static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HeadStart/\(name)")
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testVendoredHeadStartVectorsMatchPinnedChecksums() throws {
        let sumsText = try String(contentsOf: Self.fixtureURL("SHA256SUMS"), encoding: .utf8)
        var pinned: [String: String] = [:]
        for line in sumsText.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2 {
                pinned[String(parts[1])] = String(parts[0])
            }
        }
        for name in ["desktop-segment-cache-vectors.json", "transcription-mode-vectors.json"] {
            let expected = try XCTUnwrap(pinned[name], "missing SHA256SUMS entry for \(name)")
            let actual = Self.sha256Hex(try Data(contentsOf: Self.fixtureURL(name)))
            XCTAssertEqual(actual, expected, "vendored \(name) checksum mismatch")
        }
    }

    func testTranscriptionModeVectors() throws {
        let data = try Data(contentsOf: Self.fixtureURL("transcription-mode-vectors.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(TranscriptionMode.defaultMode, .transcribeWhileRecording)
        XCTAssertEqual(root["defaultMode"] as? String, TranscriptionMode.defaultMode.rawValue)
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 10)

        for item in cases {
            let id = try XCTUnwrap(item["id"] as? String)
            let input = try XCTUnwrap(item["input"] as? [String: Any])
            let expected = try XCTUnwrap(item["expected"] as? [String: Any])

            let rawMode: Any? = input["rawMode"] is NSNull ? nil : input["rawMode"]
            let hasForeground = try XCTUnwrap(input["hasForegroundSavedJob"] as? Bool)
            let manualRequested = try XCTUnwrap(input["manualTranscribeRequested"] as? Bool)
            let supportsPrecompute = try XCTUnwrap(input["platformSupportsPrecompute"] as? Bool)

            let policy = TranscriptionMode.evaluate(
                rawMode: rawMode,
                hasForegroundSavedJob: hasForeground,
                manualTranscribeRequested: manualRequested,
                platformSupportsPrecompute: supportsPrecompute
            )

            XCTAssertEqual(policy.resolvedMode.rawValue, expected["resolvedMode"] as? String, id)
            XCTAssertEqual(policy.fellBackToDefault, expected["fellBackToDefault"] as? Bool, id)
            XCTAssertEqual(policy.spawnWorkerDuringRecording, expected["spawnWorkerDuringRecording"] as? Bool, id)
            XCTAssertEqual(policy.autoEnqueueOnStop, expected["autoEnqueueOnStop"] as? Bool, id)
            XCTAssertEqual(policy.savedTranscriptStateOnStop, expected["savedTranscriptStateOnStop"] as? String, id)
            XCTAssertEqual(policy.enqueueOnManualRequest, expected["enqueueOnManualRequest"] as? Bool, id)
            XCTAssertEqual(policy.preemptActiveFollower, expected["preemptActiveFollower"] as? Bool, id)
        }
    }

    func testDesktopSegmentCacheVectors() throws {
        let data = try Data(contentsOf: Self.fixtureURL("desktop-segment-cache-vectors.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["cacheFormat"] as? String, SegmentRecognitionCache.format)
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 15)

        for item in cases {
            let id = try XCTUnwrap(item["id"] as? String)
            let cacheDocObj = try XCTUnwrap(item["cacheDocument"])
            let cacheDocData = try JSONSerialization.data(withJSONObject: cacheDocObj)
            let query = try XCTUnwrap(item["query"] as? [String: Any])
            let expected = try XCTUnwrap(item["expected"] as? [String: Any])

            let modelIdentity = try XCTUnwrap(query["modelIdentity"] as? String)
            let pcmSpec = try XCTUnwrap(query["pcmSpec"] as? [String: Any])
            let samples = try expandPCM(pcmSpec)
            let expectedPcmSha = try XCTUnwrap(query["pcmF32Sha256"] as? String)
            let sampleCount = try XCTUnwrap(query["sampleCount"] as? Int)

            let computedPcmSha = try XCTUnwrap(SegmentRecognitionCache.pcmF32Sha256(samples), id)
            XCTAssertEqual(computedPcmSha, expectedPcmSha, "\(id): pcmF32Sha256")

            let lookup = SegmentRecognitionCache.lookup(
                documentData: cacheDocData,
                modelIdentity: modelIdentity,
                pcmF32Sha256: computedPcmSha,
                sampleCount: sampleCount
            )
            XCTAssertEqual(lookup.derivedKey, expected["derivedKey"] as? String, "\(id): derivedKey")
            XCTAssertEqual(lookup.isHit, expected["cacheHit"] as? Bool, "\(id): cacheHit")
            let expectedReason = expected["rejectReason"] as? String
            XCTAssertEqual(lookup.rejectReason?.rawValue, expectedReason, "\(id): rejectReason")

            if let expectedFinalized = expected["finalized"] as? [String: Any] {
                let entry = try XCTUnwrap(lookup.entry, "\(id): expected cache hit")
                let segment = try XCTUnwrap(query["segment"] as? [String: Any])
                let startSample = try XCTUnwrap(segment["startSample"] as? Int)
                let endSample = try XCTUnwrap(segment["endSample"] as? Int)
                let offsetMs = query["offsetMs"] as? Double
                let audioEndMs = (query["audioEndMs"] as? NSNumber)?.int64Value

                // D55 (M9) placement through production MeetingTranscriber.placedStart / sessionMs.
                let offsetsAssumedZero = offsetMs == nil
                let trackFrame = MeetingTranscriber.placedStart(offsetMs: offsetMs)
                let baseMs = MeetingTranscriber.sessionMs(startSample: trackFrame, local: startSample)
                let segmentEndMs = baseMs + Int64(sampleCount) * 1000 / 16000
                let clampEndMs = audioEndMs.map { min(segmentEndMs, $0) } ?? segmentEndMs
                let clampLengthMs = max(0, clampEndMs - baseMs)

                XCTAssertEqual(baseMs, (expectedFinalized["baseMs"] as? NSNumber)?.int64Value, "\(id): baseMs")
                XCTAssertEqual(clampEndMs, (expectedFinalized["clampEndMs"] as? NSNumber)?.int64Value, "\(id): clampEndMs")
                XCTAssertEqual(offsetsAssumedZero, expectedFinalized["offsetsAssumedZero"] as? Bool, "\(id): offsetsAssumedZero")

                // G11 clamping through production MeetingTranscriber.clamped.
                var words = MeetingTranscriber.clamped(entry.relativeWords, startMs: baseMs, lengthMs: clampLengthMs)
                var text = entry.text

                // D63 #3 sessionPresence midpoint filter through production MeetingTranscriber.writes.
                if let presence = query["sessionPresence"] as? [[Int]] {
                    let keptRanges = presence.map { ($0[0] - trackFrame)..<($0[1] - trackFrame) }
                    let filtered = words.filter {
                        MeetingTranscriber.writes(startMs: $0.startMs, endMs: $0.endMs, kept: keptRanges, startSample: trackFrame)
                    }
                    if filtered.count != words.count {
                        text = filtered.map(\.text).joined(separator: " ")
                    }
                    words = filtered
                }

                // R71 noVadWindow energy gate and seam deduplication through production RecognitionFallback.
                if let r71 = query["r71Fallback"] as? [String: Any] {
                    XCTAssertEqual(endSample - startSample, sampleCount, id)
                    words = RecognitionFallback.energetic(words, samples: samples, baseMs: baseMs)
                    let prevRaw = try XCTUnwrap(r71["previousWords"] as? [[String: Any]])
                    let prevWords = try prevRaw.map { w -> RecognitionFallback.Word in
                        RecognitionFallback.Word(
                            text: try XCTUnwrap(w["text"] as? String),
                            startMs: try XCTUnwrap((w["startMs"] as? NSNumber)?.int64Value),
                            endMs: try XCTUnwrap((w["endMs"] as? NSNumber)?.int64Value)
                        )
                    }
                    let overlapMs = try XCTUnwrap((r71["overlapMs"] as? NSNumber)?.int64Value)
                    words = RecognitionFallback.mergeSeam(prevWords, words, windowStartMs: baseMs, overlapMs: overlapMs)
                    text = words.map(\.text).joined(separator: " ")
                }

                XCTAssertEqual(entry.language, expectedFinalized["language"] as? String, "\(id): language")
                XCTAssertEqual(text, expectedFinalized["text"] as? String, "\(id): text")
                let expectedWords = try XCTUnwrap(expectedFinalized["words"] as? [[String: Any]])
                XCTAssertEqual(words.count, expectedWords.count, "\(id): word count")
                for (actualWord, expectedWord) in zip(words, expectedWords) {
                    XCTAssertEqual(actualWord.startMs, (expectedWord["startMs"] as? NSNumber)?.int64Value, "\(id): word startMs")
                    XCTAssertEqual(actualWord.endMs, (expectedWord["endMs"] as? NSNumber)?.int64Value, "\(id): word endMs")
                    XCTAssertEqual(actualWord.text, expectedWord["text"] as? String, "\(id): word text")
                }
            } else {
                XCTAssertNil(lookup.entry, "\(id): expected cache miss/reject")
            }
        }
    }

    func testCacheStoreRejectsSymlinksAndNonFiniteSamplesAndCleansUp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = WhistleAssets.modelIdentity
        let samples: [Float] = [0.25, -0.25, 0.5, -0.5]
        XCTAssertNil(SegmentRecognitionCache.pcmF32Sha256([0.1, .nan, 0.2]))
        XCTAssertNil(SegmentRecognitionCache.pcmF32Sha256([0.1, .infinity]))
        XCTAssertNil(SegmentRecognitionCache.pcmF32Sha256([]))

        var store = SegmentRecognitionCache.Store(modelIdentity: model)
        let key = try XCTUnwrap(SegmentRecognitionCache.deriveKey(modelIdentity: model, samples: samples))
        let entry = try XCTUnwrap(SegmentRecognitionCache.entry(
            from: WhistleTranscript(text: "hello", language: "en", words: [.init(word: "hello", start: 0.1, end: 0.4, probability: 1)]),
            sampleCount: samples.count
        ))
        store.insert(key: key, entry: entry)
        try store.saveAtomically(to: dir)

        let loaded = SegmentRecognitionCache.Store.load(directory: dir, modelIdentity: model)
        XCTAssertEqual(loaded.lookup(samples: samples)?.entry, entry)

        // Model switch ignores previous cache cleanly.
        let otherModel = SegmentRecognitionCache.Store.load(directory: dir, modelIdentity: "parakeet-ultra-0.6b-int8-v2@deadbeef")
        XCTAssertEqual(otherModel.count, 0)

        // Remove cleans up regular cache file.
        SegmentRecognitionCache.Store.remove(in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(SegmentRecognitionCache.filename).path))

        // Symlink at `.recognition-cache.json` is never followed on read or write.
        let decoy = dir.appendingPathComponent("decoy.json")
        try store.encodedData().write(to: decoy)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(SegmentRecognitionCache.filename), withDestinationURL: decoy)
        let symlinkLoad = SegmentRecognitionCache.Store.load(directory: dir, modelIdentity: model)
        XCTAssertEqual(symlinkLoad.count, 0)
    }

    private func expandPCM(_ spec: [String: Any]) throws -> [Float] {
        let encoding = try XCTUnwrap(spec["encoding"] as? String)
        if encoding == "f32le-patterns" {
            let patterns = try XCTUnwrap(spec["patterns"] as? [[String: Any]])
            var out: [Float] = []
            for p in patterns {
                let values = try XCTUnwrap(p["values"] as? [Double]).map { Float($0) }
                let repeatCount = try XCTUnwrap(p["repeat"] as? Int)
                for _ in 0..<repeatCount { out.append(contentsOf: values) }
            }
            return out
        } else if encoding == "f32le-base64" {
            let b64 = try XCTUnwrap(spec["base64"] as? String)
            let bytes = try XCTUnwrap(Data(base64Encoded: b64))
            XCTAssertEqual(bytes.count % 4, 0)
            return bytes.withUnsafeBytes { raw in
                stride(from: 0, to: bytes.count, by: 4).map {
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
                }
            }
        }
        XCTFail("unsupported pcmSpec encoding: \(encoding)")
        return []
    }
}
