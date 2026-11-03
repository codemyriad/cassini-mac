// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary
import SwiftUI

/// Native selection and the responder chain handle Copy/Select All. Seeking is
/// a plain click after TextKit has finished tracking, never a selection drag.
struct MeetingTranscriptText: NSViewRepresentable {
    /// M11 (GNOME): another speaker's short turn shown inline after the host's item `after`.
    struct Aside {
        let after: Int, name: String, items: [LibraryTranscriptItem]
        /// D55.1 meeting.turn.aside: the visible text and accessible label.
        var label: String { UXText.text("meeting.turn.aside",["name":name,"text":items.map(\.text).joined(separator:" ")]) }
    }
    let items: [LibraryTranscriptItem]
    var asides: [Aside] = []
    let positionMs: Int
    let seek: (Int) -> Void

    func makeNSView(context: Context) -> MeetingTurnTextView {
        let view = MeetingTurnTextView(frame: .zero)
        view.isEditable = false; view.isSelectable = true; view.isRichText = true
        view.drawsBackground = false; view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        return view
    }
    func updateNSView(_ view: MeetingTurnTextView, context: Context) {
        view.seek = seek
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        let text = NSMutableAttributedString(string: "")
        let current = NSColor(srgbRed: 253/255, green: 230/255, blue: 138/255, alpha: 1)
        func word(_ item: LibraryTranscriptItem, size: CGFloat, chip: NSColor? = nil) -> NSAttributedString {
            var attributes: [NSAttributedString.Key:Any] = [
                .font: NSFont.systemFont(ofSize: size), .paragraphStyle: paragraph,
                .foregroundColor: item.startMs > positionMs ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .cassiniSeek: Int(item.startMs), .cursor: NSCursor.pointingHand
            ]
            if let chip { attributes[.backgroundColor] = chip }
            if item.startMs <= positionMs && positionMs < item.endMs { attributes[.backgroundColor] = current }
            return NSAttributedString(string: item.text.trimmingCharacters(in: .whitespacesAndNewlines), attributes: attributes)
        }
        /// GNOME's chip: smaller text on a light tint (the accent while it plays), the name in bold.
        func chip(_ aside: Aside) -> NSAttributedString {
            // GNOME Turn.is_active: from the aside's first word to 300 ms after its last (LINGER_MS),
            // so the tint holds through the gaps between its words.
            let start = aside.items.map(\.startMs).min() ?? 0, end = aside.items.map(\.endMs).max() ?? 0
            let playing = !aside.items.isEmpty && start <= positionMs && positionMs < end + 300
            let tint = playing ? NSColor.controlAccentColor.withAlphaComponent(0.25) : NSColor.labelColor.withAlphaComponent(0.07)
            let plain: [NSAttributedString.Key:Any] = [.font: NSFont.systemFont(ofSize: 11.5), .paragraphStyle: paragraph,
                                                        .foregroundColor: NSColor.labelColor, .backgroundColor: tint]
            var bold = plain; bold[.font] = NSFont.boldSystemFont(ofSize: 11.5)
            // The catalog orders the name and the words per language; the words stay seekable.
            let marker = "\u{E000}"
            let format = UXText.text("meeting.turn.aside",["name":aside.name,"text":marker])
            let result = NSMutableAttributedString(string: " ", attributes: plain)
            let parts = format.components(separatedBy: marker)
            for (index,part) in parts.enumerated() {
                if !part.isEmpty {
                    // The name and its punctuation in bold, as GNOME draws "<b>name:</b>".
                    result.append(NSAttributedString(string: part, attributes: part.contains(aside.name) ? bold : plain))
                }
                if index < parts.count - 1 {
                    for (position,item) in aside.items.enumerated() {
                        if position > 0 { result.append(NSAttributedString(string: " ", attributes: plain)) }
                        result.append(word(item, size: 11.5, chip: tint))
                    }
                }
            }
            result.append(NSAttributedString(string: " ", attributes: plain))
            return result
        }
        for (index,item) in items.enumerated() {
            if text.length > 0 { text.append(NSAttributedString(string: " ")) }
            text.append(word(item, size: 13))
            for aside in asides where aside.after == index {
                text.append(NSAttributedString(string: " ")); text.append(chip(aside))
            }
        }
        guard view.textStorage?.isEqual(to: text) != true else { return }
        // Playback changes attributes without destroying a person's selection.
        let ranges = view.selectedRanges
        let sameWords = view.string == text.string
        view.textStorage?.setAttributedString(text)
        if sameWords { view.selectedRanges = ranges }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MeetingTurnTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? max(1,$0) : nil } ?? 320
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return NSSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }
}

final class MeetingTurnTextView: NSTextView {
    var seek: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        guard event.clickCount == 1, selectedRange().length == 0 else { return }
        let up = convert(window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow, from: nil)
        guard hypot(up.x-point.x,up.y-point.y) < 4,
              let container = textContainer, let layout = layoutManager, let storage = textStorage else { return }
        let local = NSPoint(x: point.x-textContainerOrigin.x, y: point.y-textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph,length: 1), in: container).contains(local) else { return }
        let character = layout.characterIndexForGlyph(at: glyph)
        if let time = storage.attribute(.cassiniSeek, at: character, effectiveRange: nil) as? Int { seek?(time) }
    }
}
