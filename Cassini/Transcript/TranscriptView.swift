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

        /// The last time the player published. Seeded from the player, since the view may be
        /// created mid-session (a tab switch) while playback is paused.
        private var lastMs = 0
        private var lastWords: [String: Int] = [:]
        private var activeTurnIds: [Int] = []
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
            textView.wordLabel = { [weak self] i in self?.accessibilityLabel(forWord: i) ?? "" }
            textView.turnLabel = { [weak self] id in self?.accessibilityLabel(forTurn: id) ?? "" }
            scrollView.onUserScroll = { [weak self] in self?.userScrolled() }
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.userScrolled() } }
            session.transcriptSink = { [weak self] ms, words in self?.tick(ms: ms, words: words) }
            lastMs = session.player?.currentMs ?? 0
            sync()
            // The scroll view has no size yet; bring the playhead on screen once it has.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.session.follow, !self.session.followPaused, let r = self.primaryCurrentRange() else { return }
                self.scroll(toReveal: r, force: true)
            }
        }

        func detach() {
            session.transcriptSink = nil
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        /// Reconciles the text with the session's observable state.
        func sync() {
            guard textView != nil else { return }
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
            activeTurnIds = []
            textView.clearHighlights()
            lastWords = [:]
            var hint: [String: Int] = [:]
            applyTime(ms: lastMs, words: timeline.currentWords(at: lastMs, hint: &hint), announce: false)
            if !builtQuery.isEmpty { search(builtQuery) }
            textView.needsDisplay = true
        }

        // MARK: Time

        private func tick(ms: Int, words: [String: Int]) {
            let changed = words != lastWords
            lastMs = ms
            applyTime(ms: ms, words: words, announce: true)
            if changed, session.follow, !session.followPaused, let r = primaryCurrentRange() {
                scroll(toReveal: r, force: false)
            }
        }

        private func applyTime(ms: Int, words: [String: Int], announce: Bool) {
            guard let textView, let timeline = session.timeline else { return }
            let active = layout.visibleTurns.filter { timeline.isActive($0, at: ms) }.map(\.id)
            var wordRanges: [String: NSRange] = [:]
            var chips = Set<Int>()
            for (speaker, idx) in words {
                guard layout.displayTurnOfWord[idx] != nil else { continue }
                if let c = layout.chipOfWord[idx] {
                    chips.insert(c)
                } else if let r = layout.wordRanges[idx] {
                    wordRanges[speaker] = r
                }
            }
            let turnsChanged = active != activeTurnIds
            let wordsChanged = words != lastWords
            lastWords = words
            guard wordsChanged || turnsChanged else {
                // A seek inside a silent stretch still moves the spoken/upcoming boundary.
                restyleUpcoming(active: active, words: words, timeline: timeline)
                return
            }
            if announce, turnsChanged { announceNewTurns(Set(active).subtracting(activeTurnIds)) }
            activeTurnIds = active
            textView.activeChipIndices = chips
            textView.setHighlights(words: wordRanges, turns: active)
            restyleUpcoming(active: active, words: words, timeline: timeline)
        }

        /// Later words in an active turn use the secondary color; everything else the primary.
        private func restyleUpcoming(active: [Int], words: [String: Int], timeline: Timeline) {
            guard let storage = textView?.textStorage else { return }
            var wanted: [Int: Int] = [:]  // turn → spoken count
            for id in active {
                guard let body = layout.turnWords[id], let speaker = layout.turnSpeaker[id] else { continue }
                if let cur = words[speaker], let pos = body.firstIndex(of: cur) {
                    wanted[id] = pos + 1
                } else {
                    // Active with no current word (a pause, or a seek into one): spoken = started by now.
                    wanted[id] = body.filter { timeline.words[$0].startMs <= lastMs }.count
                }
            }
            guard wanted != spokenCount else { return }
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

        /// The word to keep on screen: the latest-starting current word that is actually shown.
        private func primaryCurrentRange() -> NSRange? {
            guard let timeline = session.timeline else { return nil }
            let shown = lastWords.values.compactMap { i in layout.displayRange(of: i).map { (word: i, range: $0) } }
            if let best = shown.max(by: { timeline.words[$0.word].startMs < timeline.words[$1.word].startMs }) {
                return best.range
            }
            // Nothing is being said: reveal the turn around the playhead, or the next one.
            if let turn = layout.visibleTurns.first(where: { $0.endMs > lastMs - Timeline.holdMs }) {
                return layout.turnRanges[turn.id].map { NSRange(location: $0.location, length: 1) }
            }
            return nil
        }

        // MARK: Scrolling

        /// Scrolls only when the range leaves the band from 48 pt below the top to 96 pt above the
        /// bottom; then it lands at about 35% of the view height. Returns whether it scrolled.
        @discardableResult
        private func scroll(toReveal range: NSRange, force: Bool) -> Bool {
            guard let textView, let scrollView else { return false }
            let boxes = textView.settledRects(for: range)
            guard let first = boxes.first else { return false }
            let target = boxes.dropFirst().reduce(first) { $0.union($1) }
            let visible = scrollView.contentView.bounds
            let inBand = target.minY >= visible.minY + 48 && target.maxY <= visible.maxY - 96
            guard force || !inBand else { return false }
            let y = target.midY - visible.height * 0.35
            let maxY = max(0, textView.frame.height - visible.height)
            let origin = NSPoint(x: 0, y: min(max(0, y), maxY))
            guard abs(origin.y - visible.origin.y) > 0.5 else { return false }
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
            return true
        }

        /// Any hand scroll while following pauses it; "Jump to current" offers the way back.
        private func userScrolled() {
            guard !programmaticScroll, session.follow, !session.followPaused, session.timeline != nil else { return }
            session.followPaused = true
        }

        // MARK: Search

        private func search(_ query: String) {
            guard let textView else { return }
            matchWords = []
            matchCursor = 0
            var ranges: [NSRange] = []
            if !query.isEmpty, let timeline = session.timeline {
                let needle = query.lowercased()
                for i in timeline.words.indices where timeline.words[i].text.lowercased().contains(needle) {
                    guard let r = layout.displayRange(of: i) else { continue }  // hidden speaker
                    matchWords.append(i)
                    ranges.append(r)
                }
            }
            textView.matchRanges = ranges
            session.matchCount = matchWords.count
            session.matchIndex = matchWords.isEmpty ? 0 : 1
            showMatch()
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
            let range = layout.displayRange(of: matchWords[matchCursor])
            textView.currentMatchRange = range
            textView.needsDisplay = true
            // Showing a match is like a hand scroll: following pauses until a seek or Jump to current.
            if let range, scroll(toReveal: range, force: true), session.follow, !session.followPaused,
               session.player?.isPlaying == true {
                session.followPaused = true
            }
        }

        // MARK: Accessibility

        private func accessibilityLabel(forWord i: Int) -> String {
            guard let timeline = session.timeline, i < timeline.words.count else { return "" }
            let w = timeline.words[i]
            return "\(w.text), \(session.label(for: w.speaker)), \(formatClock(w.startMs))"
        }

        private func accessibilityLabel(forTurn id: Int) -> String {
            guard let t = layout.visibleTurns.first(where: { $0.id == id }) else { return "" }
            return "\(session.label(for: t.speaker)), \(formatClock(t.startMs))"
        }

        /// Tells VoiceOver who started speaking; turn changes, not every word.
        private func announceNewTurns(_ ids: Set<Int>) {
            guard !ids.isEmpty, let textView, NSWorkspace.shared.isVoiceOverEnabled else { return }
            let names = layout.visibleTurns.filter { ids.contains($0.id) }.map { session.label(for: $0.speaker) }
            guard !names.isEmpty else { return }
            NSAccessibility.post(element: textView, notification: .announcementRequested, userInfo: [
                .announcement: names.joined(separator: ", "),
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
    }
}
