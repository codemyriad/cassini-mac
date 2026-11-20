// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import CassiniTranscription
import CassiniLibrary
import CassiniRecording
import CassiniWhistle

/// Paired `afterStop` (batch) vs. `transcribeWhileRecording` (incremental read-only `SessionFollower`
/// + `.recognition-cache.json` + warm `PrecomputedTrackPrefix` handoff) equivalence tests for both
/// **Whistle** and **Parakeet**, opening zero audio devices (D-1117 / D-1122).
final class HeadStartPrecomputeEquivalenceTests: XCTestCase {
    private static let parakeetModel = "parakeet-ultra-0.6b-int8-v2@50c15b94ea9cb1c2f8dbcdcbc0f15b450169154deeb206923cb5388f60892366"

    private struct EngineSpec {
        let name: String
        let transcriptModel: String
        let modelIdentity: String
        let initialETA: Double
        let initialLanguage: String
    }

    private static let engines: [EngineSpec] = [
        EngineSpec(
            name: "whistle",
            transcriptModel: "whistle",
            modelIdentity: WhistleAssets.modelIdentity,
            initialETA: 0.15,
            initialLanguage: "auto"
        ),
        EngineSpec(
            name: "parakeet",
            transcriptModel: parakeetModel,
            modelIdentity: parakeetModel,
            initialETA: 0.3,
            initialLanguage: "und"
        )
    ]

    /// Deterministic offline probability provider carrying the real `SileroInputHighPass`
    /// so incremental prefix carry + `SpeechGate` behavior matches batch bit-for-bit without
    /// requiring external ONNX weights or audio hardware.
    private final class DeterministicSpeechDetector: SpeechProbabilityProvider {
        private var hpf = SileroInputHighPass()
        private let threshold: Float
        private let forceSilent: Bool

        init(threshold: Float = 0.05, forceSilent: Bool = false) {
            self.threshold = threshold
            self.forceSilent = forceSilent
        }

        func reset() {
            hpf = SileroInputHighPass()
        }

        func probability(_ frame: [Float]) throws -> Float {
            guard frame.count == 512 else { throw TranscriptionFailure.audioFormat }
            let filtered = hpf.process(frame)
            if forceSilent { return 0.01 }
            var sumSq: Float = 0
            for s in filtered { sumSq += s * s }
            let rms = (sumSq / Float(filtered.count)).squareRoot()
            return rms >= threshold ? 0.92 : 0.02
        }
    }

    /// Pure deterministic recognizer keyed strictly on the exact 16 kHz PCM samples.
    private static func pureRecognize(engineTag: String, language: String) -> ([Float]) -> WhistleTranscript {
        return { samples in
            let hash = SegmentRecognitionCache.pcmF32Sha256(samples) ?? "invalid"
            let token = "\(engineTag)_\(hash.prefix(8))"
            let durationSec = Double(samples.count) / 16000.0
            let w1End = min(0.35, durationSec * 0.45)
            let w2Start = min(durationSec * 0.5, max(0.02, w1End + 0.02))
            let w2End = min(durationSec, max(w2Start + 0.05, durationSec * 0.9))
            return WhistleTranscript(
                text: "\(token) ok",
                language: language,
                words: [
                    .init(word: token, start: 0.05, end: max(0.06, w1End), probability: 0.99),
                    .init(word: "ok", start: w2Start, end: max(w2Start + 0.01, w2End), probability: 0.99)
                ]
            )
        }
    }

    /// Generates PCM16LE tone/silence chunks at `sampleRate` and `channels`.
    private static func pcm16Chunk(
        sampleRate: Int,
        channels: Int,
        seconds: Double,
        frequencyHz: Double?,
        amplitude: Double = 0.35
    ) -> Data {
        let frames = Int((seconds * Double(sampleRate)).rounded())
        var data = Data(count: frames * channels * 2)
        data.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for f in 0..<frames {
                let value: Int16
                if let freq = frequencyHz {
                    let s = sin(2.0 * .pi * freq * Double(f) / Double(sampleRate)) * amplitude
                    value = Int16(max(-32767, min(32767, Int((s * 32767.0).rounded()))))
                } else {
                    value = 0
                }
                for c in 0..<channels {
                    samples[f * channels + c] = value
                }
            }
        }
        return data
    }

    /// Appends a PCM16LE buffer to `RecordingSession` in bounded <= 250 ms chunks with advancing offsets.
    private static func appendChunked(
        to session: RecordingSession,
        id: String,
        pcm: Data,
        sampleRate: Int,
        channels: Int,
        startOffsetMs: Double
    ) throws -> Double {
        let stride = channels * 2
        let maxChunkFrames = max(1, sampleRate / 4) // 250 ms per append
        let totalFrames = pcm.count / stride
        var frameOffset = 0
        while frameOffset < totalFrames {
            let count = min(maxChunkFrames, totalFrames - frameOffset)
            let byteStart = frameOffset * stride
            let byteEnd = (frameOffset + count) * stride
            let offsetMs = startOffsetMs + Double(frameOffset) * 1000.0 / Double(sampleRate)
            try session.appendNative(id: id, pcm: Data(pcm[byteStart..<byteEnd]), offsetMs: offsetMs)
            frameOffset += count
        }
        return startOffsetMs + Double(totalFrames) * 1000.0 / Double(sampleRate)
    }

    /// Compares `transcript.json` bytes and `meeting.json` speakers/transcript/writingDown (ignoring `wallDurationMs`).
    private func assertEquivalentMeetingOutputs(batchDir: URL, precomputeDir: URL, label: String) throws {
        let batchTranscript = try Data(contentsOf: batchDir.appendingPathComponent("transcript.json"))
        let precomputeTranscript = try Data(contentsOf: precomputeDir.appendingPathComponent("transcript.json"))
        XCTAssertEqual(precomputeTranscript, batchTranscript, "\(label): transcript.json bytes must be identical")

        let batchMeta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: batchDir.appendingPathComponent("meeting.json"))) as? [String: Any])
        let preMeta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: precomputeDir.appendingPathComponent("meeting.json"))) as? [String: Any])

        let batchSpeakers = try JSONSerialization.data(withJSONObject: batchMeta["speakers"] ?? [], options: [.sortedKeys])
        let preSpeakers = try JSONSerialization.data(withJSONObject: preMeta["speakers"] ?? [], options: [.sortedKeys])
        XCTAssertEqual(preSpeakers, batchSpeakers, "\(label): speakers metadata must be identical")

        let batchTr = try JSONSerialization.data(withJSONObject: batchMeta["transcript"] ?? [:], options: [.sortedKeys])
        let preTr = try JSONSerialization.data(withJSONObject: preMeta["transcript"] ?? [:], options: [.sortedKeys])
        XCTAssertEqual(preTr, batchTr, "\(label): transcript metadata must be identical")

        var batchWriting = ((batchMeta["recordingDetails"] as? [String: Any])?["writingDown"] as? [String: Any]) ?? [:]
        var preWriting = ((preMeta["recordingDetails"] as? [String: Any])?["writingDown"] as? [String: Any]) ?? [:]
        batchWriting.removeValue(forKey: "wallDurationMs")
        preWriting.removeValue(forKey: "wallDurationMs")
        let batchWritingData = try JSONSerialization.data(withJSONObject: batchWriting, options: [.sortedKeys])
        let preWritingData = try JSONSerialization.data(withJSONObject: preWriting, options: [.sortedKeys])
        XCTAssertEqual(preWritingData, batchWritingData, "\(label): writingDown provenance must be identical")

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: precomputeDir.appendingPathComponent(SegmentRecognitionCache.filename).path),
            "\(label): .recognition-cache.json must be removed on completion"
        )
    }

    func testPairedSingleTrack48kStereoEquivalenceForBothWhistleAndParakeet() throws {
        for engine in Self.engines {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-pair-1t-\(engine.name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let speech1 = Self.pcm16Chunk(sampleRate: 48000, channels: 2, seconds: 1.5, frequencyHz: 440)
            let silence1 = Self.pcm16Chunk(sampleRate: 48000, channels: 2, seconds: 1.0, frequencyHz: nil)
            let speech2 = Self.pcm16Chunk(sampleRate: 48000, channels: 2, seconds: 1.4, frequencyHz: 660)
            let silence2 = Self.pcm16Chunk(sampleRate: 48000, channels: 2, seconds: 0.8, frequencyHz: nil)
            let tailSpeech = Self.pcm16Chunk(sampleRate: 48000, channels: 2, seconds: 1.0, frequencyHz: 520)

            // Lane A: batch (`afterStop`)
            let batchRoot = root.appendingPathComponent("batch", isDirectory: true)
            try FileManager.default.createDirectory(at: batchRoot, withIntermediateDirectories: true)
            let batchSession = try RecordingSession(parent: batchRoot, title: "Single Track", source: "macos")
            try batchSession.addTrack(id: "mic", label: "Mic", kind: "microphone", sampleRate: 48000, channels: 2)
            var batchCursorMs = 0.0
            for chunk in [speech1, silence1, speech2, silence2, tailSpeech] {
                batchCursorMs = try Self.appendChunked(to: batchSession, id: "mic", pcm: chunk, sampleRate: 48000, channels: 2, startOffsetMs: batchCursorMs)
            }
            try batchSession.finish()
            try MeetingMetadataWriter(directory: batchSession.directory, id: batchSession.manifest.id).createIfNeeded()

            var batchCalls = 0
            let recognizer = Self.pureRecognize(engineTag: engine.name, language: engine.initialLanguage == "auto" ? "en" : "und")
            try MeetingTranscriber.run(
                directory: batchSession.directory,
                detector: DeterministicSpeechDetector(),
                model: engine.transcriptModel,
                modelIdentity: engine.modelIdentity,
                initialETA: engine.initialETA,
                initialLanguage: engine.initialLanguage
            ) { samples in
                batchCalls += 1
                return recognizer(samples)
            }
            XCTAssertGreaterThanOrEqual(batchCalls, 3, "\(engine.name): expected >= 3 speech segments")

            // Lane B: precompute (`transcribeWhileRecording` + warm prefix handoff)
            let preRoot = root.appendingPathComponent("precompute", isDirectory: true)
            try FileManager.default.createDirectory(at: preRoot, withIntermediateDirectories: true)
            let preSession = try RecordingSession(parent: preRoot, title: "Single Track", source: "macos")
            try preSession.addTrack(id: "mic", label: "Mic", kind: "microphone", sampleRate: 48000, channels: 2)
            try MeetingMetadataWriter(directory: preSession.directory, id: preSession.manifest.id).createIfNeeded()

            let follower = try SessionFollower(
                directory: preSession.directory,
                modelIdentity: engine.modelIdentity,
                makeDetector: { DeterministicSpeechDetector() },
                recognize: recognizer
            )

            // Incrementally grow WAV and step follower during recording (before Stop).
            var preCursorMs = 0.0
            for chunk in [speech1, silence1, speech2, silence2] {
                preCursorMs = try Self.appendChunked(to: preSession, id: "mic", pcm: chunk, sampleRate: 48000, channels: 2, startOffsetMs: preCursorMs)
                while try follower.step() {}
            }
            XCTAssertGreaterThanOrEqual(follower.stats.tracksFollowed, 1, "\(engine.name): stats=\(follower.stats)")
            XCTAssertGreaterThanOrEqual(follower.stats.segmentsRecognized, 2, "\(engine.name): follower must precompute closed segments (stats=\(follower.stats))")

            // Final tail arrives right before Stop.
            _ = try Self.appendChunked(to: preSession, id: "mic", pcm: tailSpeech, sampleRate: 48000, channels: 2, startOffsetMs: preCursorMs)
            try preSession.finish()

            follower.cancel()
            let prefixes = follower.takeVerifiedPrefixes()
            XCTAssertEqual(prefixes.count, 1)

            var postStopCalls = 0
            try MeetingTranscriber.run(
                directory: preSession.directory,
                detector: DeterministicSpeechDetector(),
                model: engine.transcriptModel,
                modelIdentity: engine.modelIdentity,
                initialETA: engine.initialETA,
                initialLanguage: engine.initialLanguage,
                precomputedPrefixes: prefixes
            ) { samples in
                postStopCalls += 1
                return recognizer(samples)
            }

            XCTAssertLessThan(postStopCalls, batchCalls, "\(engine.name): precompute must reduce post-Stop recognizer calls")
            try assertEquivalentMeetingOutputs(batchDir: batchSession.directory, precomputeDir: preSession.directory, label: "single-track-\(engine.name)")
        }
    }

    func testPairedSimultaneousTwoTrackWithOffsetsGapsAndOwnershipForBothEngines() throws {
        for engine in Self.engines {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-pair-2t-\(engine.name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let micSpeech1 = Self.pcm16Chunk(sampleRate: 48000, channels: 1, seconds: 1.4, frequencyHz: 380)
            let micSilence = Self.pcm16Chunk(sampleRate: 48000, channels: 1, seconds: 1.0, frequencyHz: nil)
            let micSpeech2 = Self.pcm16Chunk(sampleRate: 48000, channels: 1, seconds: 1.2, frequencyHz: 420)

            let sysSpeech1 = Self.pcm16Chunk(sampleRate: 48000, channels: 2, seconds: 1.3, frequencyHz: 700)
            let sysSilence = Self.pcm16Chunk(sampleRate: 48000, channels: 2, seconds: 1.0, frequencyHz: nil)
            let sysSpeech2 = Self.pcm16Chunk(sampleRate: 48000, channels: 2, seconds: 1.3, frequencyHz: 820)

            let recognizer = Self.pureRecognize(engineTag: engine.name, language: engine.initialLanguage == "auto" ? "en" : "und")

            func makeSession(in dir: URL, follow: Bool) throws -> (RecordingSession, [String: PrecomputedTrackPrefix], Int) {
                let session = try RecordingSession(parent: dir, title: "Two Track", source: "macos")
                try session.addTrack(id: "mic", label: "Mic", kind: "microphone", sampleRate: 48000, channels: 1)
                try session.addTrack(id: "sys", label: "System", kind: "system", sampleRate: 48000, channels: 2)
                try MeetingMetadataWriter(directory: session.directory, id: session.manifest.id).createIfNeeded()

                let follower: SessionFollower? = follow ? try SessionFollower(
                    directory: session.directory,
                    modelIdentity: engine.modelIdentity,
                    makeDetector: { DeterministicSpeechDetector() },
                    recognize: recognizer
                ) : nil

                // Non-zero startOffsetMs + gap on mic + ownership switch event.
                try session.appendNative(id: "mic", pcm: micSpeech1, offsetMs: 500)
                try session.appendNative(id: "sys", pcm: sysSpeech1, offsetMs: 1234.5)
                if let follower { while try follower.step() {} }

                try session.appendNative(id: "mic", pcm: micSilence, offsetMs: 1900)
                try session.appendNative(id: "sys", pcm: sysSilence, offsetMs: 2534.5)
                if let follower { while try follower.step() {} }

                // Introduce a gap on mic and a second burst on both tracks.
                try session.appendNative(id: "mic", pcm: micSpeech2, offsetMs: 3600)
                try session.appendNative(id: "sys", pcm: sysSpeech2, offsetMs: 3534.5)
                try session.finish()

                // Add an ownership switch event into session.json so OthersOwnership trims system audio.
                let manifestURL = session.directory.appendingPathComponent("session.json")
                var manifestObj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
                manifestObj["events"] = [
                    ["atMs": 3200.0, "kind": "companionConnected", "source": "chromium"]
                ]
                try JSONSerialization.data(withJSONObject: manifestObj, options: [.sortedKeys]).write(to: manifestURL)

                var prefixes: [String: PrecomputedTrackPrefix] = [:]
                var preRecognized = 0
                if let follower {
                    follower.cancel()
                    preRecognized = follower.stats.segmentsRecognized
                    prefixes = follower.takeVerifiedPrefixes()
                }
                return (session, prefixes, preRecognized)
            }

            let batchRoot = root.appendingPathComponent("batch", isDirectory: true)
            let preRoot = root.appendingPathComponent("pre", isDirectory: true)
            try FileManager.default.createDirectory(at: batchRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: preRoot, withIntermediateDirectories: true)

            let (batchSession, _, _) = try makeSession(in: batchRoot, follow: false)
            var batchCalls = 0
            try MeetingTranscriber.run(
                directory: batchSession.directory,
                detector: DeterministicSpeechDetector(),
                model: engine.transcriptModel,
                modelIdentity: engine.modelIdentity,
                initialETA: engine.initialETA,
                initialLanguage: engine.initialLanguage
            ) { samples in
                batchCalls += 1
                return recognizer(samples)
            }

            let (preSession, prefixes, preRecognized) = try makeSession(in: preRoot, follow: true)
            XCTAssertGreaterThanOrEqual(preRecognized, 2, "\(engine.name): follower must precompute across both tracks")
            var postStopCalls = 0
            try MeetingTranscriber.run(
                directory: preSession.directory,
                detector: DeterministicSpeechDetector(),
                model: engine.transcriptModel,
                modelIdentity: engine.modelIdentity,
                initialETA: engine.initialETA,
                initialLanguage: engine.initialLanguage,
                precomputedPrefixes: prefixes
            ) { samples in
                postStopCalls += 1
                return recognizer(samples)
            }

            XCTAssertLessThan(postStopCalls, batchCalls, "\(engine.name): two-track precompute must reduce post-Stop calls")
            try assertEquivalentMeetingOutputs(batchDir: batchSession.directory, precomputeDir: preSession.directory, label: "two-track-ownership-\(engine.name)")
        }
    }

    func testPairedR71FallbackEquivalenceForBothEngines() throws {
        for engine in Self.engines {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-pair-r71-\(engine.name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            // 18 seconds of audible 440 Hz tone at 16 kHz mono where VAD returns silence -> triggers R71 fallback windows.
            let chunk1 = Self.pcm16Chunk(sampleRate: 16000, channels: 1, seconds: 10.0, frequencyHz: 440, amplitude: 0.25)
            let chunk2 = Self.pcm16Chunk(sampleRate: 16000, channels: 1, seconds: 8.0, frequencyHz: 520, amplitude: 0.25)
            let recognizer = Self.pureRecognize(engineTag: engine.name, language: engine.initialLanguage == "auto" ? "en" : "und")

            let batchRoot = root.appendingPathComponent("batch", isDirectory: true)
            let preRoot = root.appendingPathComponent("pre", isDirectory: true)
            try FileManager.default.createDirectory(at: batchRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: preRoot, withIntermediateDirectories: true)

            let batchSession = try RecordingSession(parent: batchRoot, title: "R71", source: "macos")
            try batchSession.addTrack(id: "mic", label: "Mic", kind: "microphone", sampleRate: 16000, channels: 1)
            let afterChunk1 = try Self.appendChunked(to: batchSession, id: "mic", pcm: chunk1, sampleRate: 16000, channels: 1, startOffsetMs: 0)
            _ = try Self.appendChunked(to: batchSession, id: "mic", pcm: chunk2, sampleRate: 16000, channels: 1, startOffsetMs: afterChunk1)
            try batchSession.finish()
            try MeetingMetadataWriter(directory: batchSession.directory, id: batchSession.manifest.id).createIfNeeded()

            try MeetingTranscriber.run(
                directory: batchSession.directory,
                detector: DeterministicSpeechDetector(forceSilent: true),
                model: engine.transcriptModel,
                modelIdentity: engine.modelIdentity,
                initialETA: engine.initialETA,
                initialLanguage: engine.initialLanguage,
                recognize: recognizer
            )

            let preSession = try RecordingSession(parent: preRoot, title: "R71", source: "macos")
            try preSession.addTrack(id: "mic", label: "Mic", kind: "microphone", sampleRate: 16000, channels: 1)
            try MeetingMetadataWriter(directory: preSession.directory, id: preSession.manifest.id).createIfNeeded()

            let follower = try SessionFollower(
                directory: preSession.directory,
                modelIdentity: engine.modelIdentity,
                makeDetector: { DeterministicSpeechDetector(forceSilent: true) },
                recognize: recognizer
            )
            let preAfterChunk1 = try Self.appendChunked(to: preSession, id: "mic", pcm: chunk1, sampleRate: 16000, channels: 1, startOffsetMs: 0)
            while try follower.step() {}
            _ = try Self.appendChunked(to: preSession, id: "mic", pcm: chunk2, sampleRate: 16000, channels: 1, startOffsetMs: preAfterChunk1)
            try preSession.finish()
            follower.cancel()
            let prefixes = follower.takeVerifiedPrefixes()

            try MeetingTranscriber.run(
                directory: preSession.directory,
                detector: DeterministicSpeechDetector(forceSilent: true),
                model: engine.transcriptModel,
                modelIdentity: engine.modelIdentity,
                initialETA: engine.initialETA,
                initialLanguage: engine.initialLanguage,
                precomputedPrefixes: prefixes,
                recognize: recognizer
            )

            try assertEquivalentMeetingOutputs(batchDir: batchSession.directory, precomputeDir: preSession.directory, label: "r71-\(engine.name)")
        }
    }

    func testMidRecordingKillModelSwitchTamperedPrefixAndStopForUser() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let speech1 = Self.pcm16Chunk(sampleRate: 48000, channels: 1, seconds: 1.5, frequencyHz: 440)
        let silence1 = Self.pcm16Chunk(sampleRate: 48000, channels: 1, seconds: 1.0, frequencyHz: nil)
        let speech2 = Self.pcm16Chunk(sampleRate: 48000, channels: 1, seconds: 1.3, frequencyHz: 600)

        // 1. Mid-recording worker kill (cache survives on disk, no warm prefix) -> crash-resume hits cache.
        let crashRoot = root.appendingPathComponent("crash", isDirectory: true)
        try FileManager.default.createDirectory(at: crashRoot, withIntermediateDirectories: true)
        let crashSession = try RecordingSession(parent: crashRoot, title: "Crash Resume", source: "macos")
        try crashSession.addTrack(id: "mic", label: "Mic", kind: "microphone", sampleRate: 48000, channels: 1)
        try MeetingMetadataWriter(directory: crashSession.directory, id: crashSession.manifest.id).createIfNeeded()

        let whistleRecognizer = Self.pureRecognize(engineTag: "whistle", language: "en")
        let follower = try SessionFollower(
            directory: crashSession.directory,
            modelIdentity: WhistleAssets.modelIdentity,
            makeDetector: { DeterministicSpeechDetector() },
            recognize: whistleRecognizer
        )
        try crashSession.appendNative(id: "mic", pcm: speech1, offsetMs: 0)
        try crashSession.appendNative(id: "mic", pcm: silence1, offsetMs: 1500)
        while try follower.step() {}
        XCTAssertGreaterThanOrEqual(follower.stats.segmentsRecognized, 1)

        // Simulate abrupt kill: cancel and discard prefixes (only `.recognition-cache.json` survives on disk).
        follower.cancel()
        _ = follower.takeVerifiedPrefixes()
        XCTAssertTrue(FileManager.default.fileExists(atPath: crashSession.directory.appendingPathComponent(SegmentRecognitionCache.filename).path))

        // stopForUser must succeed immediately without lock contention while cache exists.
        try crashSession.appendNative(id: "mic", pcm: speech2, offsetMs: 2500)
        try crashSession.finish()
        let stoppedRev = try MeetingTranscriber.stopForUser(directory: crashSession.directory, id: crashSession.manifest.id)
        XCTAssertNotNil(stoppedRev)
        // `.recognition-cache.json` stays retained on user pause.
        XCTAssertTrue(FileManager.default.fileExists(atPath: crashSession.directory.appendingPathComponent(SegmentRecognitionCache.filename).path))

        // Re-queue explicitly and resume: first segment must hit `.recognition-cache.json`.
        XCTAssertTrue(try MeetingTranscriber.queueIfEligible(directory: crashSession.directory, id: crashSession.manifest.id, automatic: false, explicitRetry: true))
        var resumeCalls = 0
        try MeetingTranscriber.run(
            directory: crashSession.directory,
            detector: DeterministicSpeechDetector(),
            model: "whistle",
            modelIdentity: WhistleAssets.modelIdentity,
            initialETA: 0.15,
            initialLanguage: "auto"
        ) { samples in
            resumeCalls += 1
            return whistleRecognizer(samples)
        }
        XCTAssertEqual(resumeCalls, 1, "only the uncached tail segment should invoke recognize()")

        // 2. Model switch (Parakeet precompute -> Whistle finalization): cache rejected cleanly, Whistle decodes all segments.
        let switchRoot = root.appendingPathComponent("switch", isDirectory: true)
        try FileManager.default.createDirectory(at: switchRoot, withIntermediateDirectories: true)
        let switchSession = try RecordingSession(parent: switchRoot, title: "Model Switch", source: "macos")
        try switchSession.addTrack(id: "mic", label: "Mic", kind: "microphone", sampleRate: 48000, channels: 1)
        try MeetingMetadataWriter(directory: switchSession.directory, id: switchSession.manifest.id).createIfNeeded()

        let parakeetFollower = try SessionFollower(
            directory: switchSession.directory,
            modelIdentity: Self.parakeetModel,
            makeDetector: { DeterministicSpeechDetector() },
            recognize: Self.pureRecognize(engineTag: "parakeet", language: "und")
        )
        try switchSession.appendNative(id: "mic", pcm: speech1, offsetMs: 0)
        try switchSession.appendNative(id: "mic", pcm: silence1, offsetMs: 1500)
        while try parakeetFollower.step() {}
        parakeetFollower.cancel()
        _ = parakeetFollower.takeVerifiedPrefixes()
        try switchSession.finish()

        var switchCalls = 0
        try MeetingTranscriber.run(
            directory: switchSession.directory,
            detector: DeterministicSpeechDetector(),
            model: "whistle",
            modelIdentity: WhistleAssets.modelIdentity,
            initialETA: 0.15,
            initialLanguage: "auto"
        ) { samples in
            switchCalls += 1
            return whistleRecognizer(samples)
        }
        XCTAssertGreaterThanOrEqual(switchCalls, 1, "model switch must ignore Parakeet cache and decode with Whistle")
        let switchedTranscript = try String(contentsOf: switchSession.directory.appendingPathComponent("transcript.json"), encoding: .utf8)
        XCTAssertTrue(switchedTranscript.contains("whistle_"))
        XCTAssertFalse(switchedTranscript.contains("parakeet_"))

        // 3. Tampered WAV prefix before Stop: `PrecomputedTrackPrefix.verifyMatchesDisk` rejects cleanly and falls back to full decode.
        let tamperRoot = root.appendingPathComponent("tamper", isDirectory: true)
        try FileManager.default.createDirectory(at: tamperRoot, withIntermediateDirectories: true)
        let tamperSession = try RecordingSession(parent: tamperRoot, title: "Tamper", source: "macos")
        try tamperSession.addTrack(id: "mic", label: "Mic", kind: "microphone", sampleRate: 48000, channels: 1)
        try MeetingMetadataWriter(directory: tamperSession.directory, id: tamperSession.manifest.id).createIfNeeded()

        let tamperFollower = try SessionFollower(
            directory: tamperSession.directory,
            modelIdentity: WhistleAssets.modelIdentity,
            makeDetector: { DeterministicSpeechDetector() },
            recognize: whistleRecognizer
        )
        try tamperSession.appendNative(id: "mic", pcm: speech1, offsetMs: 0)
        try tamperSession.appendNative(id: "mic", pcm: silence1, offsetMs: 1500)
        while try tamperFollower.step() {}
        tamperFollower.cancel()
        let tamperedPrefixes = tamperFollower.takeVerifiedPrefixes()
        try tamperSession.finish()

        // Flip one byte inside the committed WAV prefix (simulating prefix repair/clock warp).
        let trackFile = try XCTUnwrap(tamperSession.manifest.tracks.first?.file)
        let wavURL = tamperSession.directory.appendingPathComponent(trackFile)
        let handle = try FileHandle(forUpdating: wavURL)
        try handle.seek(toOffset: 100)
        let originalByte = (try handle.read(upToCount: 1))?.first ?? 0
        try handle.seek(toOffset: 100)
        try handle.write(contentsOf: Data([originalByte ^ 0xFF]))
        try handle.close()

        let prefix = try XCTUnwrap(tamperedPrefixes.values.first)
        XCTAssertFalse(prefix.verifyMatchesDisk(url: wavURL), "mutated WAV prefix must fail SHA-256 verification")

        let segAudio = try SegmentedAudio(url: wavURL, detector: DeterministicSpeechDetector(), precomputedPrefix: prefix)
        XCTAssertFalse(segAudio.reusedVerifiedPrefix, "mutated prefix must fall back cleanly to full decode")
        XCTAssertGreaterThan(segAudio.sampleCount, 0)
    }
}
