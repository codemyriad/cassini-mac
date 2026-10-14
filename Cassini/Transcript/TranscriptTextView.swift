import AppKit
import CassiniKit

/// The transcript text: one TextKit 2 text view for the whole document. Highlights are drawn
/// behind the text from word ranges, so a time change restyles rects, not views.
final class TranscriptTextView: NSTextView {
    static let maxColumnWidth: CGFloat = 720
    static let sidePadding: CGFloat = 20
    /// How long a highlight takes to move or fade.
    static let animationDuration: CFTimeInterval = 0.12

    var layoutInfo = TranscriptLayout(text: NSAttributedString())

    /// The accent block behind one speaker's current word, tweened between positions.
    struct WordHighlight {
        var from: NSRect
        var to: NSRect
        var start: CFTimeInterval
        /// A move to another line crossfades instead of sweeping across the column.
        var crossfade: Bool
    }

    /// The soft block behind an active turn, fading in or out.
    struct TurnHighlight {
        var alphaFrom: CGFloat
        var alphaTo: CGFloat
        var start: CFTimeInterval
    }

    private(set) var wordHighlights: [String: WordHighlight] = [:]
    private(set) var turnHighlights: [Int: TurnHighlight] = [:]
    var activeChipIndices: Set<Int> = []
    var matchRanges: [NSRange] = []
    var currentMatchRange: NSRange?
    /// Supplies the VoiceOver label of a word: speaker and time.
    var wordLabel: ((Int) -> String)?
    var turnLabel: ((Int) -> String)?

    var onSeekWord: ((Int) -> Void)?
    var onSeekMs: ((Int) -> Void)?

    private var mouseDownPoint: NSPoint?
    private var animationTimer: Timer?

    override var isFlipped: Bool { true }

    deinit { animationTimer?.invalidate() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let side = max(TranscriptTextView.sidePadding, (newSize.width - TranscriptTextView.maxColumnWidth) / 2)
        let inset = NSSize(width: side, height: 16)
        if textContainerInset != inset { textContainerInset = inset }
    }

    // MARK: Highlights

    /// Sets the current word per speaker and the active turns, animating from the previous state.
    func setHighlights(words: [String: NSRange], turns: [Int]) {
        let now = CACurrentMediaTime()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var next: [String: WordHighlight] = [:]
        for (speaker, range) in words {
            guard let to = union(rects(for: range)) else { continue }
            if let old = wordHighlights[speaker], !reduceMotion {
                let from = currentRect(of: old, at: now)
                next[speaker] = WordHighlight(from: from, to: to, start: now, crossfade: abs(from.minY - to.minY) > 1)
            } else {
                next[speaker] = WordHighlight(from: to, to: to, start: now, crossfade: false)
            }
        }
        wordHighlights = next

        let active = Set(turns)
        for id in active where turnHighlights[id] == nil || turnHighlights[id]!.alphaTo == 0 {
            let from = turnHighlights[id].map { currentAlpha(of: $0, at: now) } ?? 0
            turnHighlights[id] = TurnHighlight(alphaFrom: reduceMotion ? 1 : from, alphaTo: 1, start: now)
        }
        for (id, h) in turnHighlights where !active.contains(id) && h.alphaTo != 0 {
            turnHighlights[id] = TurnHighlight(alphaFrom: reduceMotion ? 0 : currentAlpha(of: h, at: now), alphaTo: 0, start: now)
        }
        needsDisplay = true
        if !reduceMotion { ensureAnimating() }
    }

    func clearHighlights() {
        wordHighlights = [:]
        turnHighlights = [:]
        activeChipIndices = []
        needsDisplay = true
    }

    private func progress(since start: CFTimeInterval, at now: CFTimeInterval) -> CGFloat {
        let p = min(1, max(0, (now - start) / TranscriptTextView.animationDuration))
        return CGFloat(1 - pow(1 - p, 2))  // ease-out
    }

    private func currentRect(of h: WordHighlight, at now: CFTimeInterval) -> NSRect {
        if h.crossfade { return h.to }
        let p = progress(since: h.start, at: now)
        return NSRect(x: h.from.minX + (h.to.minX - h.from.minX) * p, y: h.from.minY + (h.to.minY - h.from.minY) * p,
                      width: h.from.width + (h.to.width - h.from.width) * p, height: h.from.height + (h.to.height - h.from.height) * p)
    }

    private func currentAlpha(of h: TurnHighlight, at now: CFTimeInterval) -> CGFloat {
        h.alphaFrom + (h.alphaTo - h.alphaFrom) * progress(since: h.start, at: now)
    }

    private var isAnimating: Bool {
        let now = CACurrentMediaTime()
        return wordHighlights.values.contains { now - $0.start < TranscriptTextView.animationDuration }
            || turnHighlights.values.contains { now - $0.start < TranscriptTextView.animationDuration }
    }

    private func ensureAnimating() {
        guard animationTimer == nil, isAnimating else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.needsDisplay = true
                if !self.isAnimating {
                    timer.invalidate()
                    self.animationTimer = nil
                    // Drop turns that have faded out.
                    self.turnHighlights = self.turnHighlights.filter { $0.value.alphaTo != 0 }
                }
            }
        }
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
            if !frame.isEmpty { out.append(frame.offsetBy(dx: origin.x, dy: origin.y)) }
            return true
        }
        return out
    }

    private func union(_ boxes: [NSRect]) -> NSRect? {
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Lays out everything from the start through `range`, so positions and the view's height are
    /// real rather than TextKit 2's estimates, then returns the range's rects.
    func settledRects(for range: NSRange) -> [NSRect] {
        if let lm = textLayoutManager, let tr = textRange(range),
           let through = NSTextRange(location: lm.documentRange.location, end: tr.endLocation) {
            lm.ensureLayout(for: through)
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        return rects(for: range)
    }

    /// The character range TextKit 2 has laid out for the viewport, or nil before the first layout.
    private func viewportCharacterRange() -> NSRange? {
        guard let lm = textLayoutManager, let vr = lm.textViewportLayoutController.viewportRange else { return nil }
        let start = lm.offset(from: lm.documentRange.location, to: vr.location)
        let end = lm.offset(from: lm.documentRange.location, to: vr.endLocation)
        return NSRange(location: start, length: max(0, end - start))
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

    // MARK: Clicks and keys

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        super.mouseDown(with: event)  // tracks the drag; returns on mouse up
        guard selectedRange().length == 0, let down = mouseDownPoint else { return }
        let up = convert(window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow, from: nil)
        guard hypot(up.x - down.x, up.y - down.y) < 4 else { return }
        if let index = characterIndex(at: point) { seek(atCharacter: index) }
    }

    /// Return on a focused (selected) word seeks to it.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let storage = textStorage, storage.length > 0 {
            let loc = min(selectedRange().location, storage.length - 1)
            if seek(atCharacter: loc) || (loc > 0 && seek(atCharacter: loc - 1)) { return }
        }
        super.keyDown(with: event)
    }

    @discardableResult
    private func seek(atCharacter index: Int) -> Bool {
        guard let storage = textStorage, index >= 0, index < storage.length else { return false }
        let attrs = storage.attributes(at: index, effectiveRange: nil)
        if let word = attrs[.cassiniWord] as? Int {
            onSeekWord?(word)
        } else if let ms = attrs[.cassiniSeek] as? Int {
            onSeekMs?(ms)
        } else if let chip = attrs[.cassiniChip] as? Int, chip < layoutInfo.chips.count {
            onSeekMs?(layoutInfo.chips[chip].startMs)
        } else {
            return false
        }
        return true
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
        let now = CACurrentMediaTime()
        let viewport = viewportCharacterRange()
        func mayBeVisible(_ r: NSRange) -> Bool {
            guard let viewport else { return true }
            return NSIntersectionRange(r, viewport).length > 0 || NSLocationInRange(r.location, viewport)
        }

        // Active turns: a soft block behind the whole turn.
        for (id, h) in turnHighlights {
            guard let r = layoutInfo.turnRanges[id], mayBeVisible(r), let box = union(rects(for: r)) else { continue }
            let block = NSRect(x: textContainerOrigin.x - 14, y: box.minY - 6,
                               width: textContainer!.size.width + 28, height: box.height + 8)
            guard block.intersects(rect) else { continue }
            let alpha = currentAlpha(of: h, at: now) * (dark ? 0.12 : 0.06)
            accent.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: block, xRadius: 10, yRadius: 10).fill()
        }

        // Interjection chips: a bordered pill per line piece; lit when its speaker is talking.
        for (i, chip) in layoutInfo.chips.enumerated() where mayBeVisible(chip.range) {
            let boxes = rects(for: chip.range)
            guard boxes.contains(where: { $0.insetBy(dx: -4, dy: 3).intersects(rect) }) else { continue }
            let fill = activeChipIndices.contains(i)
                ? accent.withAlphaComponent(dark ? 0.5 : 0.22)
                : (dark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.035))
            for box in boxes {
                let path = NSBezierPath(roundedRect: box.insetBy(dx: -4, dy: 3), xRadius: 6, yRadius: 6)
                fill.setFill()
                path.fill()
                NSColor.separatorColor.setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
        }

        // Search matches.
        for r in matchRanges where mayBeVisible(r) {
            let isCurrent = currentMatchRange.map { NSEqualRanges($0, r) } ?? false
            for box in rects(for: r) where box.intersects(rect) {
                (dark ? NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: isCurrent ? 0.7 : 0.45)
                      : NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: isCurrent ? 0.7 : 0.45)).setFill()
                NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: 4), xRadius: 3, yRadius: 3).fill()
            }
        }

        // Current words: accent behind the word, text color unchanged.
        let wordAlpha: CGFloat = dark ? 0.5 : 0.22
        func drawWord(_ box: NSRect, alpha: CGFloat) {
            let path = NSBezierPath(roundedRect: box.insetBy(dx: -2.5, dy: 3), xRadius: 4, yRadius: 4)
            if highContrast {
                accent.withAlphaComponent(alpha / wordAlpha).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            } else {
                accent.withAlphaComponent(alpha).setFill()
                path.fill()
            }
        }
        for h in wordHighlights.values {
            if h.crossfade {
                let p = progress(since: h.start, at: now)
                if p < 1, h.from.intersects(rect) { drawWord(h.from, alpha: wordAlpha * (1 - p)) }
                if h.to.intersects(rect) { drawWord(h.to, alpha: wordAlpha * p) }
            } else {
                let box = currentRect(of: h, at: now)
                if box.intersects(rect) { drawWord(box, alpha: wordAlpha) }
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Accessibility

    override func accessibilityLabel() -> String? { "Transcript" }

    private lazy var rotors: [NSAccessibilityCustomRotor] = [
        NSAccessibilityCustomRotor(label: "Turns", itemSearchDelegate: self),
        NSAccessibilityCustomRotor(label: "Words", itemSearchDelegate: self),
    ]

    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] { rotors }
}

/// VoiceOver rotors over turns and words: each result's label gives the speaker and time.
extension TranscriptTextView: NSAccessibilityCustomRotorItemSearchDelegate {
    func rotor(_ rotor: NSAccessibilityCustomRotor,
               resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        let byWords = rotor.label == "Words"
        let entries: [(id: Int, range: NSRange)] = byWords
            ? layoutInfo.wordRanges.map { ($0.key, $0.value) }.sorted { $0.range.location < $1.range.location }
            : layoutInfo.visibleTurns.compactMap { t in layoutInfo.turnRanges[t.id].map { (t.id, $0) } }
        guard !entries.isEmpty, let storage = textStorage else { return nil }
        let current = searchParameters.currentItem?.targetRange.location ?? selectedRange().location
        let forward = searchParameters.searchDirection == .next
        let filter = searchParameters.filterString.lowercased()
        func text(_ r: NSRange) -> String {
            NSMaxRange(r) <= storage.length ? storage.attributedSubstring(from: r).string : ""
        }
        func matches(_ e: (id: Int, range: NSRange)) -> Bool {
            filter.isEmpty || text(e.range).lowercased().contains(filter)
                || (byWords ? wordLabel?(e.id) : turnLabel?(e.id))?.lowercased().contains(filter) == true
        }
        let candidates = forward
            ? entries.filter { $0.range.location > current && matches($0) }
            : entries.filter { $0.range.location < current && matches($0) }.reversed()
        guard let hit = (searchParameters.currentItem == nil && forward
            ? entries.first { $0.range.location >= current && matches($0) } : nil) ?? candidates.first else { return nil }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        result.targetRange = hit.range
        result.customLabel = (byWords ? wordLabel?(hit.id) : turnLabel?(hit.id)) ?? text(hit.range)
        return result
    }
}

/// A scroll view that tells its owner when the user, not the program, scrolls.
final class TranscriptScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        if event.scrollingDeltaY != 0 || event.deltaY != 0 { onUserScroll?() }
    }
}
