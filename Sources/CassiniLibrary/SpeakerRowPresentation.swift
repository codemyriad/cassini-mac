// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D70: captions use listening turns, including aside voices, rather than reading rows.
public struct SpeakerRowPresentation {
    public let provenance: String?
    public let when: String?
    public let caption: String?
    /// The localized suffix gets layout priority over the provenance in the narrow pane.
    public let captionSuffix: String?
    public let accessibilityLabel: String
    public let playAccessibilityLabel: String
    public let share: String

    public init(speaker: MeetingSpeaker, turns: [SpeakerTurn], percent: Int,
                language: CassiniLanguage = .system, locale: Locale = .current) {
        let strings = LibraryLocalization.shared
        func text(_ id: String, _ values: [String:String] = [:]) -> String {
            strings.text(id,values,language:language,locale:locale)
        }
        let key: String?
        switch speaker.provenance {
        case .user: key = "meeting.speakerCaption.namedByYou"
        case .recognised: key = "meeting.speakerCaption.recognised"
        case .unnamed: key = "meeting.speakerCaption.notNamed"
        case .source: key = speaker.id == "me" ? "common.yourMicrophone" : (speaker.id == "others" ? "recordFirst.sound.title" : nil)
        case nil: key = speaker.name == nil ? "meeting.speakerCaption.notNamed" : nil
        }
        provenance = key.map { text($0) }
        if let first = turns.first {
            let position = LibraryFormat.position(first.startMs,locale:locale,language:language)
            when = text(turns.count == 1 ? "speakers.when.once" : "speakers.when.times",
                        ["position":position,"count":String(turns.count),"n":String(turns.count)])
        } else { when = nil }
        if let when {
            caption = provenance.map { text("speakers.row.caption",["provenance":$0,"when":when]) } ?? when
            captionSuffix = text("speakers.row.caption",["provenance":"","when":when])
            accessibilityLabel = provenance.map { text("speakers.row.a11y",["name":speaker.displayName,"provenance":$0,"when":when]) }
                ?? [speaker.displayName,when].joined(separator:", ")
            playAccessibilityLabel = text("speakers.listen.a11y",["name":speaker.displayName,"when":when])
        } else {
            caption = provenance; captionSuffix = nil
            accessibilityLabel = ([speaker.displayName] + (provenance.map { [$0] } ?? [])).joined(separator:", ")
            playAccessibilityLabel = text("speakers.listen")
        }
        share = percent == 0 && turns.contains { $0.endMs > $0.startMs }
            ? text("meeting.speakerShare.underOne") : text("meeting.speakerShare",["percent":String(percent)])
    }
}
