import AppKit
import CassiniKit

/// The transcript text: one TextKit 2 text view for the whole document. Highlights are drawn
/// behind the text from word ranges, so a time change restyles rects, not views.
final class TranscriptTextView: NSTextView {
    static let maxColumnWidth: CGFloat = 720
    static let sidePadding: CGFloat = 20

    var layoutInfo = TranscriptLayout(text: NSAttributedString())

    // What to highlight. Ranges are in the text storage.
    var currentWordRanges: [NSRange] = []
    var activeTurnIds: [Int] = []
    var activeChipIndices: Set<Int> = []
    var matchRanges: [NSRange] = []
    var currentMatchRange: NSRange?

    var onSeekWord: ((Int) -> Void)?
    var onSeekMs: ((Int) -> Void)?

    private var mouseDownPoint: NSPoint?

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let side = max(TranscriptTextView.sidePadding, (newSize.width - TranscriptTextView.maxColumnWidth) / 2)
        let inset = NSSize(width: side, height: 16)
        if textContainerInset != inset { textContainerInset = inset }
    }

    // MARK: Geometry

    func textRange(_ r: NSRange) -> NSTextRange? {
        guard let lm = textLayoutManager, let cm = lm.textContentManager else { return nil }
        let start = cm.documentRange.location
        guard let a = cm.location(start, offsetBy: r.location),
              let b = cm.location(start, offsetBy: r.location + r.length) else { return nil }
        return NSTextRange(location: a, end: b)
    }

    /// Rects covering a character range, in view coordinates. Lays the range out if needed.
    func rects(for range: NSRange) -> [NSRect] {
        guard let lm = textLayoutManager, let tr = textRange(range) else { return [] }
        lm.ensureLayout(for: tr)
        var out: [NSRect] = []
        let origin = textContainerOrigin
        lm.enumerateTextSegments(in: tr, type: .highlight, options: [.rangeNotRequired]) { _, frame, _, _ in
            out.append(frame.offsetBy(dx: origin.x, dy: origin.y))
            return true
        }
        return out
    }

    /// The index of the character under a point, or nil over empty space.
    func characterIndex(at point: NSPoint) -> Int? {
        guard let lm = textLayoutManager else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        guard let fragment = lm.textLayoutFragment(for: p), let element = fragment.textElement,
              let elementRange = element.elementRange else { return nil }
        let local = NSPoint(x: p.x - fragment.layoutFragmentFrame.minX, y: p.y - fragment.layoutFragmentFrame.minY)
        guard let line = fragment.textLineFragment(forVerticalOffset: local.y, requiresExactMatch: true) else { return nil }
        let bounds = line.typographicBounds
        guard local.x >= bounds.minX - 2, local.x <= bounds.maxX + 2 else { return nil }
        let ci = line.characterIndex(for: local)
        let base = lm.offset(from: lm.documentRange.location, to: elementRange.location)
        let index = base + ci
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        return index
    }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        super.mouseDown(with: event)  // tracks the drag; returns on mouse up
        guard selectedRange().length == 0, let down = mouseDownPoint else { return }
        let up = convert(window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow, from: nil)
        guard hypot(up.x - down.x, up.y - down.y) < 4 else { return }
        handleClick(at: point)
    }

    private func handleClick(at point: NSPoint) {
        guard let storage = textStorage, let index = characterIndex(at: point) else { return }
        let attrs = storage.attributes(at: index, effectiveRange: nil)
        if let word = attrs[.cassiniWord] as? Int {
            onSeekWord?(word)
        } else if let ms = attrs[.cassiniSeek] as? Int {
            onSeekMs?(ms)
        } else if let chip = attrs[.cassiniChip] as? Int, chip < layoutInfo.chips.count {
            onSeekMs?(layoutInfo.chips[chip].startMs)
        }
    }

    // MARK: Drawing

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let accent = NSColor.controlAccentColor
        let dark = isDark
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

        // Active turns: a soft block behind the whole turn.
        accent.withAlphaComponent(dark ? 0.12 : 0.06).setFill()
        for id in activeTurnIds {
            guard let r = layoutInfo.turnRanges[id] else { continue }
            let union = rects(for: r).reduce(NSRect.null) { $0.union($1) }
            guard !union.isNull else { continue }
            let block = NSRect(x: textContainerOrigin.x - 14, y: union.minY - 6,
                               width: textContainer!.size.width + 28, height: union.height + 8)
            guard block.intersects(rect) else { continue }
            NSBezierPath(roundedRect: block, xRadius: 10, yRadius: 10).fill()
        }

        // Interjection chips: a bordered pill; lit when its speaker is talking.
        for (i, chip) in layoutInfo.chips.enumerated() {
            let union = rects(for: chip.range).reduce(NSRect.null) { $0.union($1) }
            guard !union.isNull, union.intersects(rect) else { continue }
            let pill = union.insetBy(dx: -4, dy: 3)
            let path = NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6)
            if activeChipIndices.contains(i) {
                accent.withAlphaComponent(dark ? 0.5 : 0.22).setFill()
            } else {
                (dark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.035)).setFill()
            }
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }

        // Search matches.
        if !matchRanges.isEmpty {
            for r in matchRanges {
                for box in rects(for: r) where box.intersects(rect) {
                    let isCurrent = currentMatchRange.map { NSEqualRanges($0, r) } ?? false
                    (dark ? NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: isCurrent ? 0.7 : 0.45)
                          : NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: isCurrent ? 0.7 : 0.45)).setFill()
                    NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: 4), xRadius: 3, yRadius: 3).fill()
                }
            }
        }

        // Current words: accent behind the word, text color unchanged.
        for r in currentWordRanges {
            for box in rects(for: r) where box.intersects(rect) {
                let path = NSBezierPath(roundedRect: box.insetBy(dx: -2.5, dy: 3), xRadius: 4, yRadius: 4)
                if highContrast {
                    accent.setStroke()
                    path.lineWidth = 1.5
                    path.stroke()
                } else {
                    accent.withAlphaComponent(dark ? 0.5 : 0.22).setFill()
                    path.fill()
                }
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Accessibility

    override func accessibilityLabel() -> String? { "Transcript" }
}

/// A scroll view that tells its owner when the user, not the program, scrolls.
final class TranscriptScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        if event.scrollingDeltaY != 0 || event.deltaY != 0 { onUserScroll?() }
    }
}
