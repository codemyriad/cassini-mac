// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary
import SwiftUI

/// Native selection and the responder chain handle Copy/Select All. Seeking is
/// a plain click after TextKit has finished tracking, never a selection drag.
struct MeetingTranscriptText: NSViewRepresentable {
    let items: [LibraryTranscriptItem]
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
        for item in items {
            if text.length > 0 { text.append(NSAttributedString(string: " ")) }
            var attributes: [NSAttributedString.Key:Any] = [
                .font: NSFont.systemFont(ofSize: 13), .paragraphStyle: paragraph,
                .foregroundColor: item.startMs > positionMs ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .cassiniSeek: Int(item.startMs), .cursor: NSCursor.pointingHand
            ]
            if item.startMs <= positionMs && positionMs < item.endMs {
                attributes[.backgroundColor] = NSColor(srgbRed: 253/255, green: 230/255, blue: 138/255, alpha: 1)
            }
            text.append(NSAttributedString(string: item.text.trimmingCharacters(in: .whitespacesAndNewlines), attributes: attributes))
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
