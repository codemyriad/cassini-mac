// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// UTF-16 ranges address the exact paragraph displayed by TextKit, including
/// inline asides. Call off the main actor; cancellation discards an obsolete query.
public enum TranscriptFind {
    public struct Paragraph: Sendable, Equatable {
        public let id: Int
        public let text: String
        public init(id: Int, text: String) { self.id = id; self.text = text }
    }
    public struct Match: Sendable, Equatable, Hashable {
        public let paragraph: Int
        public let range: NSRange
        public init(paragraph: Int, range: NSRange) { self.paragraph = paragraph; self.range = range }
    }
    public enum Direction { case previous, next }

    public static func matches(in paragraphs: [Paragraph], query: String, locale: Locale) throws -> [Match] {
        try Task.checkCancellation()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var matches: [Match] = []
        for paragraph in paragraphs {
            try Task.checkCancellation()
            let text = paragraph.text as NSString
            var remaining = NSRange(location: 0, length: text.length)
            while remaining.length > 0 {
                try Task.checkCancellation()
                let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: remaining, locale: locale)
                guard range.location != NSNotFound, range.length > 0 else { break }
                matches.append(Match(paragraph: paragraph.id, range: range))
                let end = NSMaxRange(range)
                remaining = NSRange(location: end, length: text.length - end)
            }
        }
        return matches
    }

    public static func adjacent(to selected: Match?, direction: Direction, in matches: [Match]) -> Match? {
        guard !matches.isEmpty else { return nil }
        guard let selected, let index = matches.firstIndex(of: selected) else {
            return direction == .next ? matches.first : matches.last
        }
        return matches[(index + (direction == .next ? 1 : matches.count - 1)) % matches.count]
    }
}
