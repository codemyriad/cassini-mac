import AppKit
import CassiniKit
import SwiftUI

/// Hosts the transcript text view and keeps it in step with the session: time, speakers, search.
struct TranscriptView: NSViewRepresentable {
    let session: SessionModel

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> TranscriptScrollView {
        let scroll = TranscriptScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.autohidesScrollers = true

        let textView = TranscriptTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 20, height: 16)
        scroll.documentView = textView

        context.coordinator.attach(scrollView: scroll, textView: textView)
        return scroll
    }

    func updateNSView(_ nsView: TranscriptScrollView, context: Context) {
        context.coordinator.sync()
    }

    static func dismantleNSView(_ nsView: TranscriptScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        let session: SessionModel
        private weak var scrollView: TranscriptScrollView?
        private weak var textView: TranscriptTextView?
        private var layout = TranscriptLayout(text: NSAttributedString())

        // What the text currently reflects, to diff against the session.
        private var builtHidden: Set<String>?
        private var builtTranscriptId: String?
        private var builtQuery = ""
        private var seenJump = 0
        private var seenMatchStep = 0

        private var lastMs = 0
        private var lastWords: [String: Int] = [:]
        /// Turn id → number of body words styled as spoken (the rest are upcoming).
        private var spokenCount: [Int: Int] = [:]
        private var matchWords: [Int] = []
        private var matchCursor = 0
        private var programmaticScroll = false
        private var scrollObserver: NSObjectProtocol?

        init(session: SessionModel) { self.session = session }

        func attach(scrollView: TranscriptScrollView, textView: TranscriptTextView) {
            self.scrollView = scrollView
            self.textView = textView
            textView.onSeekWord = { [weak self] i in self?.session.seek(toWord: i) }
            textView.onSeekMs = { [weak self] ms in self?.session.seek(toMs: ms) }
            scrollView.onUserScroll = { [weak self] in self?.userScrolled() }
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.userScrolled() } }
            session.transcriptSink = { [weak self] ms, words in self?.tick(ms: ms, words: words) }
            sync()
        }

        func detach() {
            session.transcriptSink = nil
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        /// Reconciles the text with the session's observable state.
        func sync() {
            guard let textView else { return }
            if builtHidden != session.hiddenSpeakers || builtTranscriptId != session.selectedTranscriptId {
                rebuild()
            }
            let q = session.searchText.trimmingCharacters(in: .whitespaces)
            if q != builtQuery {
                builtQuery = q
                search(q)
            }
            if session.matchStep.serial != seenMatchStep {
                seenMatchStep = session.matchStep.serial
                stepMatch(session.matchStep.direction)
            }
            if session.jumpRequest != seenJump {
                seenJump = session.jumpRequest
                if let r = primaryCurrentRange() { scroll(toReveal: r, force: true) }
            }
            _ = textView
        }

        private func rebuild() {
            guard let textView, let timeline = session.timeline else { return }
            builtHidden = session.hiddenSpeakers
            builtTranscriptId = session.selectedTranscriptId
            layout = TranscriptBuilder.build(timeline: timeline, hidden: session.hiddenSpeakers,
                                             label: { [session] in session.label(for: $0) },
                                             color: { [session] in session.color(for: $0) })
            textView.layoutInfo = layout
            textView.textStorage?.setAttributedString(layout.text)
            spokenCount = [:]
            textView.currentWordRanges = []
            textView.activeTurnIds = []
            textView.activeChipIndices = []
            lastWords = [:]
            applyTime(ms: lastMs, words: lastWordsFromSession())
            if !builtQuery.isEmpty { search(builtQuery) }
            textView.needsDisplay = true
        }

        private func lastWordsFromSession() -> [String: Int] {
            guard let tl = session.timeline else { return [:] }
            var hint: [String: Int] = [:]
            return tl.currentWords(at: lastMs, hint: &hint)
        }

        // MARK: Time

        private func tick(ms: Int, words: [String: Int]) {
            let changed = words != lastWords
            lastMs = ms
            applyTime(ms: ms, words: words)
            if changed, session.follow, !session.followPaused, let r = primaryCurrentRange() {
                scroll(toReveal: r, force: false)
            }
        }

        private func applyTime(ms: Int, words: [String: Int]) {
            guard let textView, let timeline = session.timeline else { return }
            let visible = Set(layout.visibleTurnIds)
            let active = timeline.activeTurns(at: ms).filter { visible.contains($0) }
            var wordRanges: [NSRange] = []
            var chips = Set<Int>()
            for (_, idx) in words {
                guard visible.contains(timeline.turnOfWord[idx]) else { continue }
                if timeline.isChipWord[idx] {
                    if let c = layout.chips.firstIndex(where: { $0.words.contains(idx) }) { chips.insert(c) }
                } else if let r = layout.wordRanges[idx] {
                    wordRanges.append(r)
                }
            }
            let turnsChanged = active != textView.activeTurnIds
            let wordsChanged = words != lastWords || turnsChanged
            lastWords = words
            guard wordsChanged else { return }

            textView.activeTurnIds = active
            textView.activeChipIndices = chips
            textView.currentWordRanges = wordRanges
            restyleUpcoming(active: active, words: words, timeline: timeline)
            textView.needsDisplay = true
        }

        /// Later words in an active turn use the secondary color; everything else the primary.
        private func restyleUpcoming(active: [Int], words: [String: Int], timeline: Timeline) {
            guard let storage = textView?.textStorage else { return }
            var wanted: [Int: Int] = [:]  // turn → spoken count
            for id in active {
                guard let body = layout.turnWords[id] else { continue }
                let speaker = timeline.turns[id].speaker
                if let cur = words[speaker], let pos = body.firstIndex(of: cur) {
                    wanted[id] = pos + 1
                } else {
                    // Active with no current word (a pause inside the turn): keep what was spoken.
                    wanted[id] = spokenCount[id] ?? body.filter { timeline.words[$0].startMs <= lastMs }.count
                }
            }
            var edits: [(NSRange, NSColor)] = []
            for (id, old) in spokenCount where wanted[id] == nil {
                // Turn left the active set: everything back to primary.
                for i in (layout.turnWords[id] ?? []).dropFirst(old) { if let r = layout.wordRanges[i] { edits.append((r, .labelColor)) } }
            }
            for (id, count) in wanted {
                let body = layout.turnWords[id] ?? []
                let old = spokenCount[id] ?? body.count  // untouched turns are all primary
                if count > old {
                    for i in body[old..<count] { if let r = layout.wordRanges[i] { edits.append((r, .labelColor)) } }
                } else if count < old {
                    for i in body[count..<old] { if let r = layout.wordRanges[i] { edits.append((r, .secondaryLabelColor)) } }
                }
            }
            spokenCount = wanted
            guard !edits.isEmpty else { return }
            storage.beginEditing()
            for (r, c) in edits where NSMaxRange(r) <= storage.length {
                storage.addAttribute(.foregroundColor, value: c, range: r)
            }
            storage.endEditing()
        }

        /// The word to keep on screen: the latest-starting current word in a visible turn.
        private func primaryCurrentRange() -> NSRange? {
            guard let timeline = session.timeline else { return nil }
            let visible = Set(layout.visibleTurnIds)
            let best = lastWords.values
                .filter { visible.contains(timeline.turnOfWord[$0]) }
                .max { timeline.words[$0].startMs < timeline.words[$1].startMs }
            if let best {
                if timeline.isChipWord[best], let c = layout.chips.first(where: { $0.words.contains(best) }) { return c.range }
                return layout.wordRanges[best]
            }
            // Nothing is being said: reveal the turn around the playhead, or the next one.
            if let turn = timeline.turns.first(where: { visible.contains($0.id) && $0.endMs + Timeline.holdMs > lastMs }) {
                return layout.turnRanges[turn.id].map { NSRange(location: $0.location, length: 1) }
            }
            return nil
        }

        // MARK: Scrolling

        /// Scrolls only when the range leaves the band from 48 pt below the top to 96 pt above the
        /// bottom; then it lands at about 35% of the view height.
        private func scroll(toReveal range: NSRange, force: Bool) {
            guard let textView, let scrollView else { return }
            let boxes = textView.rects(for: range)
            guard let first = boxes.first else { return }
            let target = boxes.dropFirst().reduce(first) { $0.union($1) }
            let visible = scrollView.contentView.bounds
            let inBand = target.minY >= visible.minY + 48 && target.maxY <= visible.maxY - 96
            guard force || !inBand else { return }
            let y = target.midY - visible.height * 0.35
            let maxY = max(0, textView.frame.height - visible.height)
            let origin = NSPoint(x: 0, y: min(max(0, y), maxY))
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            programmaticScroll = true
            let clip = scrollView.contentView
            if reduceMotion {
                clip.setBoundsOrigin(origin)
                scrollView.reflectScrolledClipView(clip)
                programmaticScroll = false
            } else {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.3
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    ctx.allowsImplicitAnimation = true
                    clip.animator().setBoundsOrigin(origin)
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        scrollView.reflectScrolledClipView(clip)
                        self?.programmaticScroll = false
                    }
                })
            }
        }

        private func userScrolled() {
            guard !programmaticScroll, session.follow, !session.followPaused, !lastWords.isEmpty else { return }
            session.followPaused = true
        }

        // MARK: Search

        private func search(_ query: String) {
            guard let textView else { return }
            matchWords = []
            matchCursor = 0
            if !query.isEmpty, let timeline = session.timeline {
                let needle = query.lowercased()
                let visible = Set(layout.visibleTurnIds)
                matchWords = timeline.words.indices.filter {
                    visible.contains(timeline.turnOfWord[$0]) && timeline.words[$0].text.lowercased().contains(needle)
                }
            }
            textView.matchRanges = matchWords.compactMap { layout.wordRanges[$0] ?? chipRange(containing: $0) }
            session.matchCount = matchWords.count
            session.matchIndex = matchWords.isEmpty ? 0 : 1
            showMatch()
        }

        private func chipRange(containing word: Int) -> NSRange? {
            layout.chips.first { $0.words.contains(word) }?.range
        }

        private func stepMatch(_ direction: Int) {
            guard !matchWords.isEmpty else { return }
            matchCursor = (matchCursor + direction + matchWords.count) % matchWords.count
            session.matchIndex = matchCursor + 1
            showMatch()
        }

        private func showMatch() {
            guard let textView else { return }
            guard matchCursor < matchWords.count else {
                textView.currentMatchRange = nil
                textView.needsDisplay = true
                return
            }
            let w = matchWords[matchCursor]
            let range = layout.wordRanges[w] ?? chipRange(containing: w)
            textView.currentMatchRange = range
            textView.needsDisplay = true
            if let range { scroll(toReveal: range, force: true) }
        }
    }
}
