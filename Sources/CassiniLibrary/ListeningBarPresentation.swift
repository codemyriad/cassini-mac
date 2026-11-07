// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

/// D70's bounded, plain-text context; paragraph splits never affect the turn counter.
public struct ListeningBarPresentation {
    public let speakerName: String
    public let label: String
    public let announcement: String
    public let speakerAnnouncement: String
    public let accessibilityLabel: String
    public let previousExcerpt: String
    public let currentExcerpt: String

    public init(name: String, turn: SpeakerTurn, previous: SpeakerTurn?, index: Int, count: Int, firstStartMs: Int64,
                language: CassiniLanguage = .system, locale: Locale = .current) {
        speakerName = name
        let strings = LibraryLocalization.shared
        let values = ["index":String(index+1),"count":String(count),
                      "position":LibraryFormat.position(turn.startMs,locale:locale,language:language)]
        label = strings.text("listen.turn",values,language:language,locale:locale)
        announcement = strings.text("listen.turn.announce",values,language:language,locale:locale)
        let when = strings.text(count == 1 ? "speakers.when.once" : "speakers.when.times",
                                ["position":LibraryFormat.position(firstStartMs,locale:locale,language:language),
                                 "count":String(count),"n":String(count)],language:language,locale:locale)
        speakerAnnouncement = [name,when].joined(separator:", ")
        accessibilityLabel = strings.text("listen.bar.a11y",["name":name],language:language,locale:locale)
        var leading: [String] = [], current: [String] = []
        if let previous {
            for item in previous.words.reversed() {
                let words = item.text.split(whereSeparator: \.isWhitespace)
                leading.insert(contentsOf:words.suffix(5-leading.count).map(String.init),at:0)
                if leading.count == 5 { break }
            }
        }
        for item in turn.words {
            current.append(contentsOf:item.text.split(maxSplits:8,whereSeparator: \.isWhitespace).prefix(8-current.count).map(String.init))
            if current.count == 8 { break }
        }
        previousExcerpt = TranscriptText.quotes(leading).joined(separator:" ")
        currentExcerpt = TranscriptText.quotes(current).joined(separator:" ")
    }
}
