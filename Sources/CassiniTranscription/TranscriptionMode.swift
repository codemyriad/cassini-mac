// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D-1117 / D109 / D111 non-UI transcription policy seam.
/// Shipped default is `.transcribeWhileRecording` (D111); `.afterStop` and `.recordOnly`
/// remain supported canonical modes.
public enum TranscriptionMode: String, Codable, Equatable, Sendable, CaseIterable {
    case recordOnly = "recordOnly"
    case afterStop = "afterStop"
    case transcribeWhileRecording = "transcribeWhileRecording"

    public static let defaultMode: TranscriptionMode = .transcribeWhileRecording

    public struct Resolution: Equatable, Sendable {
        public let mode: TranscriptionMode
        public let fellBackToDefault: Bool

        public init(mode: TranscriptionMode, fellBackToDefault: Bool) {
            self.mode = mode
            self.fellBackToDefault = fellBackToDefault
        }
    }

    public struct Policy: Equatable, Sendable {
        public let resolvedMode: TranscriptionMode
        public let fellBackToDefault: Bool
        public let spawnWorkerDuringRecording: Bool
        public let autoEnqueueOnStop: Bool
        public let savedTranscriptStateOnStop: String
        public let enqueueOnManualRequest: Bool
        public let preemptActiveFollower: Bool

        public init(
            resolvedMode: TranscriptionMode,
            fellBackToDefault: Bool,
            spawnWorkerDuringRecording: Bool,
            autoEnqueueOnStop: Bool,
            savedTranscriptStateOnStop: String,
            enqueueOnManualRequest: Bool,
            preemptActiveFollower: Bool
        ) {
            self.resolvedMode = resolvedMode
            self.fellBackToDefault = fellBackToDefault
            self.spawnWorkerDuringRecording = spawnWorkerDuringRecording
            self.autoEnqueueOnStop = autoEnqueueOnStop
            self.savedTranscriptStateOnStop = savedTranscriptStateOnStop
            self.enqueueOnManualRequest = enqueueOnManualRequest
            self.preemptActiveFollower = preemptActiveFollower
        }
    }

    /// Resolves a persisted raw value (canonical, Python snake_case, or Kotlin UPPER_SNAKE_CASE,
    /// case-sensitive). Any null, empty, wrong-case, non-string, or unrecognized token resolves
    /// deterministically to `defaultMode` (`.transcribeWhileRecording`).
    public static func resolve(_ rawValue: Any?) -> Resolution {
        guard let token = rawValue as? String else {
            return Resolution(mode: defaultMode, fellBackToDefault: true)
        }
        switch token {
        case "recordOnly", "record_only", "RECORD_ONLY":
            return Resolution(mode: .recordOnly, fellBackToDefault: false)
        case "afterStop", "after_stop", "AFTER_STOP":
            return Resolution(mode: .afterStop, fellBackToDefault: false)
        case "transcribeWhileRecording", "transcribe_while_recording", "TRANSCRIBE_WHILE_RECORDING":
            return Resolution(mode: .transcribeWhileRecording, fellBackToDefault: false)
        default:
            return Resolution(mode: defaultMode, fellBackToDefault: true)
        }
    }

    public static func evaluate(
        rawMode: Any?,
        hasForegroundSavedJob: Bool,
        manualTranscribeRequested: Bool,
        platformSupportsPrecompute: Bool = true
    ) -> Policy {
        let resolution = resolve(rawMode)
        let preempt = hasForegroundSavedJob || manualTranscribeRequested
        let spawnDuringRecording = resolution.mode == .transcribeWhileRecording
            && platformSupportsPrecompute
            && !preempt
        let autoEnqueue = resolution.mode != .recordOnly
        return Policy(
            resolvedMode: resolution.mode,
            fellBackToDefault: resolution.fellBackToDefault,
            spawnWorkerDuringRecording: spawnDuringRecording,
            autoEnqueueOnStop: autoEnqueue,
            savedTranscriptStateOnStop: autoEnqueue ? "queued" : "none",
            enqueueOnManualRequest: manualTranscribeRequested,
            preemptActiveFollower: preempt
        )
    }
}
