import AppKit
import CassiniKit

extension NSAttributedString.Key {
    /// Int: index into `Timeline.words`, on a word's characters.
    static let cassiniWord = NSAttributedString.Key("cassiniWord")
    /// Int: ms to seek to, on a turn's timestamp.
    static let cassiniSeek = NSAttributedString.Key("cassiniSeek")
    /// Int: index into `TranscriptLayout.chips`, on an interjection chip.
    static let cassiniChip = NSAttributedString.Key("cassiniChip")
}

struct ChipInfo {
    var range: NSRange
    var speaker: String
    var words: [Int]
    var startMs: Int
}

/// The transcript as one attributed string, with the ranges the view needs to restyle words.
struct TranscriptLayout {
    var text: NSAttributedString
    var wordRanges: [Int: NSRange] = [:]
    /// Turn id → the whole turn (header and body).
    var turnRanges: [Int: NSRange] = [:]
    /// Turn id → its body words in display order (interjection words excluded).
    var turnWords: [Int: [Int]] = [:]
    var chips: [ChipInfo] = []
    var visibleTurnIds: [Int] = []
}

enum TranscriptBuilder {
    static let bodyFont = NSFont.systemFont(ofSize: 15)
    static let bodyLineHeight: CGFloat = 26  // 15 pt × 1.75
    static let nameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let chipNameFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let chipFont = NSFont.systemFont(ofSize: 12)
    static let noteFont = NSFont.systemFont(ofSize: 12)

    static func build(timeline: Timeline, hidden: Set<String>, label: (String) -> String, color: (String) -> NSColor) -> TranscriptLayout {
        let out = NSMutableAttributedString()
        var layout = TranscriptLayout(text: out)
        let turns = timeline.visibleTurns(hiding: hidden)
        layout.visibleTurnIds = turns.map(\.id)

        let note = NSMutableParagraphStyle()
        note.paragraphSpacing = 6
        out.append(NSAttributedString(string: "Click any word to play from there.\n", attributes: [
            .font: noteFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: note,
        ]))

        let header = NSMutableParagraphStyle()
        header.paragraphSpacingBefore = 14
        header.paragraphSpacing = 2
        header.lineBreakMode = .byTruncatingTail

        let body = NSMutableParagraphStyle()
        body.minimumLineHeight = bodyLineHeight
        body.maximumLineHeight = bodyLineHeight
        body.paragraphSpacing = 4

        for turn in turns {
            let start = out.length
            // Header: ● Name  0:00
            out.append(NSAttributedString(string: "●", attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: color(turn.speaker),
                .baselineOffset: 1.5, .paragraphStyle: header,
            ]))
            out.append(NSAttributedString(string: "  " + label(turn.speaker), attributes: [
                .font: nameFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: header,
            ]))
            out.append(NSAttributedString(string: "  " + formatClock(turn.startMs), attributes: [
                .font: timeFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: header,
                .cassiniSeek: turn.startMs, .cursor: NSCursor.pointingHand,
                .toolTip: "Play from \(formatClock(turn.startMs))",
            ]))
            out.append(NSAttributedString(string: "\n", attributes: [.font: nameFont, .paragraphStyle: header]))

            // Body
            let chipsBefore = turn.interjections.filter { $0.anchor < 0 }
            for j in chipsBefore { appendChip(j, to: out, &layout, timeline: timeline, label: label, style: body) }
            var bodyWords: [Int] = []
            for (k, wordIndex) in turn.words.enumerated() {
                if k > 0 || !chipsBefore.isEmpty {
                    out.append(NSAttributedString(string: " ", attributes: [.font: bodyFont, .paragraphStyle: body]))
                }
                let w = timeline.words[wordIndex]
                let loc = out.length
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: body,
                    .kern: -0.075, .cassiniWord: wordIndex, .cursor: NSCursor.pointingHand,
                ]
                if w.lowConfidenceSpeaker { attrs[.underlineStyle] = NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue; attrs[.underlineColor] = NSColor.tertiaryLabelColor }
                out.append(NSAttributedString(string: w.text, attributes: attrs))
                layout.wordRanges[wordIndex] = NSRange(location: loc, length: out.length - loc)
                bodyWords.append(wordIndex)
                for j in turn.interjections where j.anchor == k {
                    appendChip(j, to: out, &layout, timeline: timeline, label: label, style: body)
                }
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont, .paragraphStyle: body]))
            layout.turnRanges[turn.id] = NSRange(location: start, length: out.length - start)
            layout.turnWords[turn.id] = bodyWords
        }
        layout.text = out
        return layout
    }

    private static func appendChip(_ j: Interjection, to out: NSMutableAttributedString, _ layout: inout TranscriptLayout,
                                   timeline: Timeline, label: (String) -> String, style: NSParagraphStyle) {
        guard !j.words.isEmpty else { return }
        let chipIndex = layout.chips.count
        out.append(NSAttributedString(string: " ", attributes: [.font: bodyFont, .paragraphStyle: style]))
        let loc = out.length
        let words = j.words.map { timeline.words[$0].text }.joined(separator: " ")
        // Thin spaces pad the chip inside its drawn border.
        out.append(NSAttributedString(string: "\u{2009}" + label(j.speaker), attributes: [
            .font: chipNameFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
            .cassiniChip: chipIndex, .cursor: NSCursor.pointingHand, .baselineOffset: 0.5,
        ]))
        out.append(NSAttributedString(string: " " + words + "\u{2009}", attributes: [
            .font: chipFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
            .cassiniChip: chipIndex, .cursor: NSCursor.pointingHand, .baselineOffset: 0.5,
            .toolTip: "\(label(j.speaker)) at \(formatClock(j.startMs)): \(words)",
        ]))
        layout.chips.append(ChipInfo(range: NSRange(location: loc, length: out.length - loc), speaker: j.speaker,
                                     words: j.words, startMs: j.startMs))
    }
}
