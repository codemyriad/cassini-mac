import Foundation

/// A short overlapping utterance shown as a chip inside another speaker's turn.
public struct Interjection: Sendable, Equatable {
    public var speaker: String
    /// Indices into `Timeline.words`.
    public var words: [Int]
    /// The chip sits after this position in the host turn's `words` (-1: before the first word).
    public var anchor: Int
    public var startMs: Int
    public var endMs: Int
}

/// A turn as the transcript shows it: a maximal run of one speaker's items in file order, with
/// short overlapping interjections folded in as chips.
public struct Turn: Sendable, Equatable, Identifiable {
    public var id: Int
    public var speaker: String
    /// Indices into `Timeline.words`, in file order.
    public var words: [Int]
    public var interjections: [Interjection]
    public var startMs: Int
    /// The greatest end among its own words, which is not always the last word's.
    public var endMs: Int
    public var over: [String] = []
    public var continuation = false
}

/// The words of one transcript arranged for display and for time lookup.
///
/// Word times are untrusted input; every comparison keeps the constant on the clock side, so no
/// addition to a file-supplied value can overflow.
public struct Timeline: Sendable {
    /// The 300 ms hold that stops a highlight flickering off in short pauses.
    public static let holdMs = 300

    public let words: [Word]
    public let turns: [Turn]
    /// For each word, the id of the turn that displays it (the host turn for an interjection).
    public let turnOfWord: [Int]
    /// For each word, whether it is shown as an interjection chip.
    public let isChipWord: [Bool]
    /// Per speaker id: that speaker's word indices sorted by start.
    let bySpeaker: [String: [Int]]

    public init(_ words: [Word], endsBoundedByAudio: Bool = false) {
        let projection = TranscriptRendering.render(words.map { .init(speaker:$0.speaker,startMs:Int64($0.startMs),endMs:Int64($0.endMs),text:$0.text,lowConfidenceSpeaker:$0.lowConfidenceSpeaker) },endsBoundedByAudio:endsBoundedByAudio)
        self.init(words,projection:projection)
    }
    /// Background document preparation can stop before publishing a superseded selection.
    public static func preparing(_ words: [Word], endsBoundedByAudio: Bool = false) throws -> Timeline {
        let input = words.map { TranscriptRendering.Word(speaker:$0.speaker,startMs:Int64($0.startMs),endMs:Int64($0.endMs),text:$0.text,lowConfidenceSpeaker:$0.lowConfidenceSpeaker) }
        let projection = try TranscriptRendering.render(input,endsBoundedByAudio:endsBoundedByAudio,breakBefore:[],cancellable:true)
        return Timeline(words,projection:projection)
    }
    private init(_ words: [Word], projection: TranscriptRendering.Result) {
        self.words = zip(words,projection.words).map { original,display in var copy = original; copy.endMs = Int(display.endMs); return copy }
        let turns = Timeline.buildTurns(projection)
        self.turns = turns
        var tow = [Int](repeating: -1, count: words.count)
        var chip = [Bool](repeating: false, count: words.count)
        for t in turns {
            for i in t.words { tow[i] = t.id }
            for j in t.interjections { for i in j.words { tow[i] = t.id; chip[i] = true } }
        }
        turnOfWord = tow
        isChipWord = chip
        var by: [String: [Int]] = [:]
        for (i, w) in words.enumerated() { by[w.speaker, default: []].append(i) }
        bySpeaker = by.mapValues { idx in idx.enumerated().sorted { a, b in
            words[a.element].startMs != words[b.element].startMs
                ? words[a.element].startMs < words[b.element].startMs : a.offset < b.offset
        }.map(\.element) }
    }

    /// D84: the legacy document and QuickLook adapt the same viewer rows as Meeting/Search.
    private static func buildTurns(_ rendered: TranscriptRendering.Result) -> [Turn] {
        rendered.rows.enumerated().map { id,row in
            var own: [Int] = [], chips: [Interjection] = []
            for member in row.members {
                if member.kind == "words" { own += member.wordIndices }
                else {
                    chips.append(.init(speaker:member.speaker!,words:member.wordIndices,anchor:own.count-1,
                                       startMs:Int(member.wordIndices.map { rendered.words[$0].startMs }.min()!),endMs:Int(member.wordIndices.map { rendered.words[$0].endMs }.max()!)))
                }
            }
            return .init(id:id,speaker:row.speaker,words:own,interjections:chips,startMs:Int(row.startMs),endMs:Int(row.endMs),over:row.over,continuation:row.continuation)
        }
    }
    /// Copy and preview text keep short interjections inline, with no lost words.
    public func text(_ turn: Turn, names: [String:String] = [:], aside: (String,String) -> String = { $0 + ": " + $1 }) -> String {
        var pieces: [String] = []
        for (position,index) in turn.words.enumerated() {
            pieces.append(words[index].text)
            for chip in turn.interjections where chip.anchor == position {
                pieces.append("(" + aside(names[chip.speaker] ?? chip.speaker,chip.words.map { words[$0].text }.joined(separator:" ")) + ")")
            }
        }
        return pieces.joined(separator:" ")
    }

    /// Turns with hidden speakers removed. A visible interjection inside a hidden turn becomes a
    /// turn of its own, with an id no real turn uses (ids at or above `turns.count`).
    public func visibleTurns(hiding hidden: Set<String>) -> [Turn] {
        guard !hidden.isEmpty else { return turns }
        var out: [Turn] = []
        for t in turns {
            if hidden.contains(t.speaker) {
                for j in t.interjections where !hidden.contains(j.speaker) {
                    out.append(Turn(id: turns.count + out.count, speaker: j.speaker, words: j.words,
                                    interjections: [], startMs: j.startMs, endMs: j.endMs))
                }
            } else {
                var v = t
                v.interjections.removeAll { hidden.contains($0.speaker) }
                v.over.removeAll { hidden.contains($0) }
                out.append(v)
            }
        }
        for i in out.indices {
            out[i].continuation = i > 0 && out[i-1].speaker == out[i].speaker && out[i].startMs-out[i-1].endMs <= 60_000
        }
        return out
    }

    /// The word each speaker is saying at `t`: the last of their words with `start <= t`, while `t < end + hold`.
    public func currentWords(at t: Int, hint: inout [String: Int]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (speaker, idx) in bySpeaker {
            let pos = lastStarted(idx, at: t, hint: hint[speaker])
            hint[speaker] = pos
            guard let pos else { continue }
            let w = words[idx[pos]]
            if t - Timeline.holdMs < w.endMs { result[speaker] = idx[pos] }
        }
        return result
    }

    /// Position in `idx` of the last word with `start <= t`. Checks the cached position and its
    /// neighbours first, since playback time almost always moves forward.
    func lastStarted(_ idx: [Int], at t: Int, hint: Int?) -> Int? {
        func ok(_ p: Int) -> Bool {
            words[idx[p]].startMs <= t && (p + 1 == idx.count || words[idx[p + 1]].startMs > t)
        }
        if let h = hint {
            for p in [h, h + 1, h + 2] where p >= 0 && p < idx.count && ok(p) { return p }
        }
        var lo = 0, hi = idx.count  // first position with start > t
        while lo < hi {
            let mid = (lo + hi) / 2
            if words[idx[mid]].startMs <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    /// Upcoming display atoms, independent of canonical/timestamp order.
    public func upcomingWords(_ indices: [Int], at t: Int) -> Set<Int> {
        Set(indices.filter { words[$0].startMs > t })
    }

    /// Ids of the turns active at `t`: those whose span, plus the hold, contains it.
    public func activeTurns(at t: Int) -> [Int] {
        turns.filter { isActive($0, at: t) }.map(\.id)
    }

    public func isActive(_ turn: Turn, at t: Int) -> Bool {
        t >= turn.startMs && t - Timeline.holdMs < turn.endMs
    }
}
