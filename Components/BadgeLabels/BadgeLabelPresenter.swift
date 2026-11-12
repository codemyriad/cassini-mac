// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(CassiniLibrary)
import CassiniLibrary
#endif

/// Validated projection inputs, not a metadata parser or a second manifest.
struct BadgeMeetingFields: Decodable {
    enum Lifecycle: String, Decodable { case recording, saving, saved }
    enum Origin: String, Decodable { case own, received }
    enum Transcript: String, Decodable { case none, queued, running, done, failed, damaged }
    struct Issue: Decodable { var id: String; var action: String? }
    var lifecycle: Lifecycle = .saved
    var origin: Origin = .own
    var interruptedAtMs: Int64?
    var transcript: Transcript = .none
    var etaMinutes: Int64?
    var error: Issue?
    var liveMs: Int64?
    var audioAvailable: Bool?

    var canWriteDown: Bool {
        lifecycle == .saved && [.none, .failed].contains(transcript) && audioAvailable != false
    }
}

/// Importing is an independent transient-entry scope under W0.4. It does not
/// compete with a recording, alter a meeting lifecycle or invent priority.
enum BadgeLabelInput {
    case meeting(BadgeMeetingFields)
    case importingEntry
}

struct CatalogBadgePresentation: Equatable {
    let kind: String
    let text: String
    let tint: String
    let glyph: String
}

/// Prepare once outside a View body; callers own catalog loading and live ticks.
struct BadgeLabelPresenter {
    enum InvalidCatalog: Error { case missingLabel(String), missingTranslation(String) }
    private let catalog: LibraryLocalization
    let language: CassiniLanguage
    let locale: Locale

    init(data: Data, language: CassiniLanguage, locale: Locale) throws {
        let catalog = try LibraryLocalization(data: data)
        for suffix in ["recording", "importing", "saving", "transcribing", "transcribing.noEta",
                       "transcribing.underMinute", "needsAttention", "interrupted", "received"] {
            let id = "states.badge." + suffix
            guard let entry = catalog.entries.first(where: { $0.id == id }) else {
                throw InvalidCatalog.missingLabel(id)
            }
            if language != .en && entry.l10n?[language.rawValue] == nil {
                throw InvalidCatalog.missingTranslation(id)
            }
        }
        self.catalog = catalog; self.language = language; self.locale = locale
    }

    func presentation(for input: BadgeLabelInput) -> CatalogBadgePresentation? {
        func badge(_ kind: String, _ key: String, _ tint: String, _ glyph: String,
                   _ args: [String: String] = [:]) -> CatalogBadgePresentation {
            .init(kind: kind, text: catalog.text("states.badge." + key, args, language: language, locale: locale),
                  tint: tint, glyph: glyph)
        }
        switch input {
        case .importingEntry:
            return badge("importing", "importing", "neutral", "spinner")
        case .meeting(let fields):
            if fields.lifecycle == .recording {
                return badge("recording", "recording", "red", "dot",
                             ["liveBadge": LibraryFormat.liveBadge(fields.liveMs ?? 0, locale: locale, language: language)])
            }
            if fields.lifecycle == .saving { return badge("saving", "saving", "neutral", "spinner") }
            if [.queued, .running].contains(fields.transcript) {
                guard let eta = fields.etaMinutes, eta >= 0 else {
                    return badge("transcribing", "transcribing.noEta", "neutral", "spinner")
                }
                if eta == 0 { return badge("transcribing", "transcribing.underMinute", "neutral", "spinner") }
                return badge("transcribing", "transcribing", "neutral", "spinner", ["n": String(eta)])
            }
            if fields.error?.action != nil { return badge("needsAttention", "needsAttention", "amber", "alert") }
            if fields.interruptedAtMs != nil { return badge("interrupted", "interrupted", "amber", "alert") }
            if fields.origin == .received { return badge("received", "received", "outline", "incoming") }
            return nil
        }
    }
}
