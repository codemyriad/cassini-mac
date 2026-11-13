// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// L-45: desktop engines publish retained words, not a live draft for reading.
/// Do not infer audio processed, pipeline stages or battery drain from word timings:
/// silence, overlapping tracks and resumed jobs make those estimates misleading.
public struct TranscribingPresentation: Sendable {
    public let isActive: Bool
    public let canStop: Bool
    public let status: String
    public let timeLeft: String
    public let wordsSoFar: String
    public let audioDone: String
    public let batteryAtFinish: String
    public static let steps = ["transcribing.step.reading", "transcribing.step.preparing", "transcribing.step.words", "transcribing.step.speakers", "transcribing.step.saving"]
    public static func isActive(_ state: MeetingState) -> Bool {
        state.lifecycle == .saved && [.queued, .running].contains(state.transcript)
    }

    public init(state: MeetingState, readOnly: Bool, wordCount: Int, durationMs: Int64?,
                language: CassiniLanguage = .system, locale: Locale = .current) {
        isActive = Self.isActive(state)
        canStop = isActive && !readOnly
        let catalog = LibraryLocalization.shared
        func text(_ id: String, _ values: [String:String] = [:]) -> String {
            catalog.text(id, values, language:language, locale:locale)
        }
        if let eta = state.etaMinutes, eta > 0 {
            status = text("transcribing.heading") + " · " + text("transcribing.eta.minutes", ["n":String(eta)])
            timeLeft = text("transcribing.stat.timeLeftValue", ["n":String(eta)])
        } else if state.etaMinutes == 0 {
            // Keep the provisional under-minute catalog wording (STATUS-BADGES.md).
            status = text("states.badge.transcribing.underMinute")
            timeLeft = status
        } else {
            status = text("states.badge.transcribing.noEta")
            timeLeft = "—"
        }
        wordsSoFar = max(0, wordCount).formatted(.number.locale(locale))
        audioDone = durationMs.flatMap { $0 > 0 ? LibraryFormat.position($0) : nil }
            .map { text("transcribing.stat.audioDoneValue", ["done":"—", "total":$0]) } ?? "—"
        batteryAtFinish = "—"
    }
}
