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
}

/// The words of one transcript arranged for display and for time lookup.
public struct Timeline: Sendable {
    /// The 300 ms hold that stops a highlight flickering off in short pauses.
    public static let holdMs = 300
    /// Interjection limits: at most this many words and this long.
    public static let interjectionMaxWords = 4
    public static let interjectionMaxMs = 2500
    /// A host turn split by an interjection is rejoined when its halves are this close.
    public static let rejoinGapMs = 2000

    public let words: [Word]
    public let turns: [Turn]
    /// For each word, the id of the turn that displays it (the host turn for an interjection).
    public let turnOfWord: [Int]
    /// For each word, whether it is shown as an interjection chip.
    public let isChipWord: [Bool]
    /// Per speaker id: that speaker's word indices sorted by start.
    let bySpeaker: [String: [Int]]

    public init(_ words: [Word]) {
        self.words = words
        let turns = Timeline.buildTurns(words)
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

    /// Raw turns: maximal runs of consecutive items with the same speaker.
    static func rawTurns(_ words: [Word]) -> [(speaker: String, words: [Int])] {
        var out: [(speaker: String, words: [Int])] = []
        for (i, w) in words.enumerated() {
            if let last = out.last, last.speaker == w.speaker {
                out[out.count - 1].words.append(i)
            } else {
                out.append((w.speaker, [i]))
            }
        }
        return out
    }

    static func buildTurns(_ words: [Word]) -> [Turn] {
        let raw = rawTurns(words)
        func span(_ idx: [Int]) -> (Int, Int) {
            (idx.map { words[$0].startMs }.min() ?? 0, idx.map { words[$0].endMs }.max() ?? 0)
        }
        func isShort(_ idx: [Int]) -> Bool {
            let (s, e) = span(idx)
            return idx.count <= interjectionMaxWords && e - s <= interjectionMaxMs
        }
        func anchor(in host: [Int], at ms: Int) -> Int {
            var a = -1
            for (k, i) in host.enumerated() where words[i].startMs <= ms { a = k }
            return a
        }
        func makeInterjection(_ idx: [Int], host: [Int]) -> Interjection {
            let (s, e) = span(idx)
            return Interjection(speaker: words[idx[0]].speaker, words: idx, anchor: anchor(in: host, at: s), startMs: s, endMs: e)
        }

        var turns: [Turn] = []
        var held: [[Int]] = []  // interjections waiting for the turn after them
        var k = 0
        while k < raw.count {
            let r = raw[k]
            let (s, e) = span(r.words)
            // Folds into the previous turn when it lies within that turn's span.
            if isShort(r.words), var host = turns.last, host.speaker != r.speaker,
               host.startMs <= s, e <= host.endMs + holdMs {
                host.interjections.append(makeInterjection(r.words, host: host.words))
                // The host may continue after the interjection: rejoin it.
                if k + 1 < raw.count, raw[k + 1].speaker == host.speaker {
                    let (ns, ne) = span(raw[k + 1].words)
                    if ns - host.endMs <= rejoinGapMs {
                        host.words += raw[k + 1].words
                        host.endMs = max(host.endMs, ne)
                        host.startMs = min(host.startMs, ns)
                        k += 1
                    }
                }
                turns[turns.count - 1] = host
                k += 1
                continue
            }
            // Or into the next turn, when it was written before the speech it overlaps.
            if isShort(r.words), k + 1 < raw.count, raw[k + 1].speaker != r.speaker {
                let (ns, ne) = span(raw[k + 1].words)
                if ns <= s, e <= ne + holdMs {
                    held.append(r.words)
                    k += 1
                    continue
                }
            }
            var turn = Turn(id: turns.count, speaker: r.speaker, words: r.words, interjections: [], startMs: s, endMs: e)
            turn.interjections = held.map { makeInterjection($0, host: r.words) }
            held = []
            turns.append(turn)
            k += 1
        }
        // An interjection held for a turn that never came stands on its own.
        for h in held {
            let (s, e) = span(h)
            turns.append(Turn(id: turns.count, speaker: words[h[0]].speaker, words: h, interjections: [], startMs: s, endMs: e))
        }
        return turns
    }

    /// Turns with hidden speakers removed. A visible interjection inside a hidden turn becomes a turn of its own.
    public func visibleTurns(hiding hidden: Set<String>) -> [Turn] {
        guard !hidden.isEmpty else { return turns }
        var out: [Turn] = []
        for t in turns {
            if hidden.contains(t.speaker) {
                for j in t.interjections where !hidden.contains(j.speaker) {
                    out.append(Turn(id: t.id * 1000 + out.count, speaker: j.speaker, words: j.words,
                                    interjections: [], startMs: j.startMs, endMs: j.endMs))
                }
            } else {
                var v = t
                v.interjections.removeAll { hidden.contains($0.speaker) }
                out.append(v)
            }
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
            if t < w.endMs + Timeline.holdMs { result[speaker] = idx[pos] }
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

    /// Ids of the turns active at `t`: those whose span, plus the hold, contains it.
    public func activeTurns(at t: Int) -> [Int] {
        turns.filter { isActive($0, at: t) }.map(\.id)
    }

    public func isActive(_ turn: Turn, at t: Int) -> Bool {
        t >= turn.startMs && t < turn.endMs + Timeline.holdMs
    }
}
