// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import CassiniLibrary

/// One optional value records both the answer and the future naming default.
/// Missing means unanswered; false is an explicit Not now or Settings choice.
@MainActor @Observable final class VoicePreferences {
    static let key = "CassiniRememberNamedVoices"
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var answer: Bool?
    init(defaults: UserDefaults, fallback: Bool? = nil) {
        self.defaults = defaults
        answer = defaults.object(forKey:Self.key) as? Bool ?? fallback
    }
    var remember: Bool {
        get { answer ?? false }
        set { defaults.set(newValue,forKey:Self.key); answer = newValue }
    }
    func choice(existing: Bool) -> SpeakerVoiceChoice { SpeakerVoiceChoice(existing:existing,enabled:remember) }
    func shouldAsk(speakerCount: Int) -> Bool { answer == nil && speakerCount > 1 }
}
