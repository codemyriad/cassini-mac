// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Relates exact listening words to presentation paragraphs and embedded asides.
/// Prepared once with both turn lists; changes to the target are dictionary reads.
public struct TranscriptListening: Sendable {
    private struct Word: Hashable {
        let speaker: String
        let start: Int64
        let text: String
        init(_ item: LibraryTranscriptItem) { speaker = item.speaker; start = item.startMs; text = item.text }
    }
    private var targets: [Int:[Int:Set<Int>]] = [:] // listening index → reading id → local words
    private var runs: [Int:[SpeakerTurn]] = [:]
    private var hosts: [Int:Int] = [:]
    public init(rows: [MeetingPresentation.Turn] = [], turns: [SpeakerTurn] = []) {
        var words: [Word:[(original: Int,turn: Int)]] = [:]
        for turn in turns {
            for (word,original) in zip(turn.words,turn.wordIndices) {
                words[Word(word),default:[]].append((original,turn.index))
            }
        }
        for key in words.keys { words[key]?.sort { $0.original < $1.original } }
        var used: [Word:Int] = [:], rowRuns: [Int:Set<Int>] = [:]
        for row in rows {
            hosts[row.id] = row.host ?? row.id
            for (offset,item) in row.items.enumerated() {
                let key = Word(item), at = used[key,default:0]
                guard let matches = words[key], matches.indices.contains(at) else { continue }
                let target = matches[at].turn; used[key] = at+1
                targets[target,default:[:]][row.id,default:[]].insert(offset)
                rowRuns[row.id,default:[]].insert(target)
            }
        }
        let byID = Dictionary(uniqueKeysWithValues:turns.map { ($0.index,$0) })
        runs = rowRuns.mapValues { $0.sorted().compactMap { byID[$0] } }
    }
    public func words(in row: Int, listeningTo target: Int?) -> Set<Int> {
        target.flatMap { targets[$0]?[row] } ?? []
    }
    public func host(forReading row: Int) -> Int? { hosts[row] }
    public func host(forListening target: Int) -> Int? {
        // Prefer the first chronological reading row, even when its target is a chip.
        targets[target]?.keys.sorted().first.flatMap { hosts[$0] }
    }
    public func hosts(forListening target: Int) -> Set<Int> {
        guard let rows = targets[target] else { return [] }
        return Set(rows.keys.compactMap { hosts[$0] })
    }
    /// Ordinary playback follows the playhead. Listening follows only its own
    /// host paragraphs; other voices in lead-in, overlap or tail cannot move it.
    public func followHost(forReading row: Int?, listeningTo target: Int?) -> Int? {
        guard let row, let host = hosts[row] else { return nil }
        if let target, !hosts(forListening:target).contains(host) { return nil }
        return host
    }
    public func listeningIndex(forReading row: Int, at position: Int64) -> Int? {
        guard let candidates = runs[row] else { return nil }
        return candidates.last { $0.startMs <= position && position < $0.endMs }?.index ?? candidates.first?.index
    }
}

/// Monotonic media-independent follow policy. Tests advance the injected clock,
/// never a sleep. Explicit steps resume immediately, including within one host row.
public struct TranscriptFollow: Sendable {
    private var resumeAt = -Double.infinity
    public init() { }
    public mutating func handScrolled(at now: Double) { resumeAt = now+4 }
    public func allowsFollow(at now: Double) -> Bool { now >= resumeAt }
    public mutating func stepped() { resumeAt = -Double.infinity }
}
