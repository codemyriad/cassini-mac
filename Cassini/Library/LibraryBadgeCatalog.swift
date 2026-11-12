// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniLibrary

/// Owns loading the pinned W2.2 BadgeLabels catalog outside SwiftUI View bodies
/// and projecting validated LibraryMeeting state into BadgeMeetingFields.
enum LibraryBadgeCatalog {
    private static let rawCatalogData: Data = {
        guard let url = Bundle.main.url(forResource: "strings", withExtension: "json", subdirectory: nil),
              let data = try? Data(contentsOf: url) else {
            preconditionFailure("Missing bundled Components/BadgeLabels/Contract/strings.json")
        }
        return data
    }()

    private static let lock = NSLock()
    private static var cached: BadgeLabelPresenter?

    static func presenter(language: CassiniLanguage = UXText.language, locale: Locale = UXText.locale) -> BadgeLabelPresenter {
        lock.lock(); defer { lock.unlock() }
        if let existing = cached, existing.language == language, existing.locale.identifier == locale.identifier {
            return existing
        }
        guard let built = try? BadgeLabelPresenter(data: rawCatalogData, language: language, locale: locale) else {
            preconditionFailure("Pinned BadgeLabels catalog failed validation for \(language.rawValue)")
        }
        cached = built
        return built
    }

    static func fields(for meeting: LibraryMeeting) -> BadgeMeetingFields {
        let state = meeting.state
        return BadgeMeetingFields(
            lifecycle: .init(rawValue: state.lifecycle.rawValue) ?? .saved,
            origin: .init(rawValue: state.origin.rawValue) ?? .own,
            interruptedAtMs: state.interruptedAtMs,
            transcript: .init(rawValue: state.transcript.rawValue) ?? .none,
            etaMinutes: state.etaMinutes,
            error: state.error.map { .init(id: $0.id, action: $0.action) },
            liveMs: state.liveMs,
            audioAvailable: state.audioAvailable ?? !meeting.audioFiles.isEmpty
        )
    }

    static func presentation(for meeting: LibraryMeeting, language: CassiniLanguage = UXText.language, locale: Locale = UXText.locale) -> CatalogBadgePresentation? {
        presenter(language: language, locale: locale).presentation(for: .meeting(fields(for: meeting)))
    }

    static var importingPresentation: CatalogBadgePresentation? {
        presenter().presentation(for: .importingEntry)
    }
}
