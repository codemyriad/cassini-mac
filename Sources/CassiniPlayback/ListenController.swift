// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import CassiniLibrary

/// D70 step 2: speaker listening over the page's ordinary player. Turn indices
/// are zero-based within the target speaker; the words retain their global indices.
@MainActor @Observable public final class ListenController {
    public private(set) var speaker: String?
    public private(set) var index = -1
    public private(set) var count = 0
    public private(set) var finished = false
    public var active: Bool { speaker != nil }
    public var turn: SpeakerTurn? { targets.indices.contains(index) ? targets[index] : nil }
    public static let leadInMs = 1500.0, tailMs = 500.0, chainGapMs = 2000.0
    @ObservationIgnored private let playback: SessionPlayback
    @ObservationIgnored private var meeting: LibraryMeeting?
    private var bySpeaker: [String:[SpeakerTurn]] = [:]
    private var targets: [SpeakerTurn] = []
    @ObservationIgnored private var spanLast: Int?
    @ObservationIgnored private var explicitTurn: Int?
    @ObservationIgnored private var serial = 0

    public init(playback: SessionPlayback) { self.playback = playback }
    public func turns(of speaker: String) -> [SpeakerTurn] { bySpeaker[speaker] ?? [] }

    /// Called with the load worker's resolved turns after transcript/merge changes.
    /// Keep an already finished target finished when its last tail is still behind
    /// the playhead, so an unrelated merge cannot remove Play again.
    @discardableResult public func setTurns(_ turns: [SpeakerTurn]) -> Bool {
        bySpeaker = Dictionary(grouping:turns,by: \.speaker)
        guard let speaker else { return true }
        guard let updated = bySpeaker[speaker], !updated.isEmpty else { stop(); return false }
        guard updated != targets else { return true }
        let wasFinished = finished
        // A boundary completion records the exact stop. The native media clock can
        // differ by a fraction of a sample; that must not erase Play again on merge.
        let position = wasFinished ? playback.positionMs : playback.playheadMs
        targets = updated; count = updated.count; serial += 1
        if wasFinished, position >= end(of:updated.count-1,through:updated.count-1) {
            playback.clearSpan(); spanLast = nil; explicitTurn = updated.count-1
            index = updated.count-1; finished = true
        } else { playback.seek(toMs:position) }
        return true
    }

    @discardableResult public func start(_ speaker: String, in meeting: LibraryMeeting, turnIndex: Int? = nil) -> Bool {
        guard let turns = bySpeaker[speaker], !turns.isEmpty, meeting.canPlaySession else { return false }
        playback.prepare(meeting)
        if let previous = playback.listener, previous !== self { previous.stop() }
        playback.listener = self; self.meeting = meeting
        self.speaker = speaker; targets = turns; count = turns.count
        let wanted = turnIndex ?? turns.firstIndex(where: { Double($0.endMs) > playback.playheadMs }) ?? 0
        return play(max(0,min(count-1,wanted)))
    }
    /// Stop the listening mode; ordinary audio and its position stay as they are.
    public func stop() {
        if playback.listener === self { playback.listener = nil; playback.clearSpan() }
        reset()
    }
    /// Page close/switch, library outage, or a new recording uses the ordinary
    /// player's stop path. Its lifecycle notification also clears listening.
    public func pageChanged() { stop(); playback.stop() }
    func playbackStopped() { reset() }
    private func reset() {
        serial += 1; speaker = nil; index = -1; count = 0; finished = false
        meeting = nil; targets = []; spanLast = nil; explicitTurn = nil
    }

    public func stepTarget(_ direction: Int) -> Int? {
        guard active, direction == -1 || direction == 1 else { return nil }
        let position = playback.playheadMs
        let current: Int?
        if let actual = containing(position) { current = actual }
        else if let explicitTurn, targets.indices.contains(explicitTurn),
           leadStart(explicitTurn) <= position, position <= Double(targets[explicitTurn].endMs)+Self.tailMs {
            current = explicitTurn
        } else { current = containing(position) }
        let result: Int
        if let current { result = current+direction }
        else if direction > 0 { result = targets.firstIndex { Double($0.startMs) > position } ?? count }
        else { result = targets.lastIndex { Double($0.startMs) < position } ?? -1 }
        return targets.indices.contains(result) ? result : nil
    }
    @discardableResult public func nextTurn() -> Bool { stepTarget(1).map(play) ?? false }
    @discardableResult public func previousTurn() -> Bool { stepTarget(-1).map(play) ?? false }
    @discardableResult public func playAgain() -> Bool { active && play(0) }
    public func speakerStepTarget(_ direction: Int, order: [String]) -> String? {
        guard let speaker, direction == -1 || direction == 1 else { return nil }
        let available = order.filter { !(bySpeaker[$0] ?? []).isEmpty }
        guard let at = available.firstIndex(of:speaker), available.indices.contains(at+direction) else { return nil }
        return available[at+direction]
    }
    @discardableResult public func stepSpeaker(_ direction: Int, order: [String]) -> Bool {
        guard let next = speakerStepTarget(direction,order:order), let meeting else { return false }
        return start(next,in:meeting,turnIndex:0)
    }
    private func leadStart(_ index: Int) -> Double {
        let start = Double(targets[index].startMs)
        if index > 0, start-Double(targets[index-1].endMs) < Self.chainGapMs { return start }
        return max(0,start-Self.leadInMs)
    }
    private func chainLast(_ index: Int) -> Int {
        var last = index
        while last+1 < count, Double(targets[last+1].startMs)-Double(targets[last].endMs) < Self.chainGapMs { last += 1 }
        return last
    }
    private func end(of first: Int, through last: Int) -> Double {
        let end = Double(targets[first...last].map(\.endMs).max() ?? 0)+Self.tailMs
        return playback.durationMs > 0 ? min(end,playback.durationMs) : end
    }
    private func completion(_ last: Int) -> @MainActor @Sendable () -> Void {
        serial += 1
        let token = serial
        return { [weak self] in
            guard let self, self.active, self.serial == token, self.spanLast == last else { return }
            if last+1 < self.count { _ = self.play(last+1) }
            else {
                self.spanLast = nil; self.explicitTurn = last
                self.index = last; self.finished = true
            }
        }
    }
    private func play(_ index: Int) -> Bool {
        guard let meeting, targets.indices.contains(index) else { return false }
        let last = chainLast(index)
        self.index = index; finished = false; spanLast = last; explicitTurn = index
        let done = completion(last)
        let accepted = playback.play(meeting,fromMs:leadStart(index),untilMs:end(of:index,through:last),onDone:done)
        if !accepted { stop() }
        return accepted
    }
    /// Every ordinary seek follows the target from the new playhead. An upcoming
    /// turn is displayed, but its lead-in is not treated as an explicitly selected
    /// turn: Next from a manual seek there must select it, rather than skip it.
    func follow(_ position: Double) -> SessionPlayback.Span? {
        guard active else { return nil }
        explicitTurn = nil; finished = false
        let next = containing(position) ?? targets.firstIndex { Double($0.startMs) > position }
        guard let next else { serial += 1; spanLast = nil; index = count-1; return nil }
        index = next; let last = chainLast(next); spanLast = last
        return .init(endMs:end(of:next,through:last),done:completion(last))
    }
    private func containing(_ position: Double) -> Int? {
        targets.indices.reversed().first { Double(targets[$0].startMs) <= position && position < Double(targets[$0].endMs)+Self.tailMs }
    }
    func positionChanged(_ position: Double) {
        guard active, playback.isPlaying, let spanLast else { return }
        if let next = targets.lastIndex(where: { Double($0.startMs) <= position }), next > index, next <= spanLast {
            index = next
        }
    }
}
