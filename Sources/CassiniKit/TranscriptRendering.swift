// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D84: the word-only viewer pipeline, ported from gocassini 1111155cb0017b47c072a8662c54f28ad7c44223:
/// portable.ts readable grouping, overlap.ts timing repair/turn model/rows, and
/// MeetingView.svelte continuation. Canonical words and stored text are never mutated.
public enum TranscriptRendering {
    public struct Word: Codable, Equatable, Sendable {
        public var speaker: String
        public var startMs: Int64
        public var endMs: Int64
        public var text: String
        public var lowConfidenceSpeaker: Bool?
        public init(speaker: String, startMs: Int64, endMs: Int64, text: String, lowConfidenceSpeaker: Bool? = nil) {
            self.speaker = speaker; self.startMs = startMs; self.endMs = endMs
            self.text = text; self.lowConfidenceSpeaker = lowConfidenceSpeaker
        }
    }
    public struct Block: Equatable, Sendable {
        public let id: Int
        public let speaker: String
        public var startMs: Int64
        public var endMs: Int64
        public var wordIndices: [Int]
    }
    public struct Run: Sendable {
        public let id: Int
        public let speaker: String
        public var blocks: [Int]
        public var startMs: Int64
        public var endMs: Int64
        public var host: Int?
        public var afterBlock: Int?
        public var over: [String] = []
    }
    public struct Member: Codable, Equatable, Sendable {
        public let kind: String
        public let speaker: String?
        public let crosstalk: Bool?
        public let wordIndices: [Int]
        public let text: String
        public let blockIDs: [Int]
    }
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: Int
        public let turnID: Int
        public let speaker: String
        public var continuation: Bool
        public let startMs: Int64
        public let endMs: Int64
        public let over: [String]
        public let crosstalk: Bool
        public let members: [Member]
        public func text(names: [String:String] = [:]) -> String {
            members.map { $0.kind == "words" ? $0.text : "(\(names[$0.speaker ?? ""] ?? $0.speaker ?? ""): \($0.text))" }.joined(separator:" ")
        }
    }
    public struct Result: Sendable {
        /// Derived display words, with only inflated ends repaired. Original input stays intact.
        public let words: [Word]
        public let blocks: [Block]
        public let runs: [Run]
        public let rows: [Row]
    }
    private struct Span { var start: Int64; var end: Int64 }
    private static func union(_ spans: [Span]) -> [Span] {
        var out: [Span] = []
        for span in spans.sorted(by:{ $0.start < $1.start }) {
            if let last = out.last, span.start <= last.end { out[out.count-1].end = max(last.end,span.end) }
            else { out.append(span) }
        }
        return out
    }
    private static func overlap(_ a: [Span], _ b: [Span]) -> Int64 {
        var i = 0, j = 0, total: Int64 = 0
        while i < a.count && j < b.count {
            total += max(0,min(a[i].end,b[j].end) - max(a[i].start,b[j].start))
            if a[i].end < b[j].end { i += 1 } else { j += 1 }
        }
        return total
    }
    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of:pattern,options:.regularExpression) != nil
    }
    private static func wordLike(_ text: String) -> Bool { matches(text,"[\\p{L}\\p{N}]") }
    private static func terminal(_ text: String) -> Bool {
        matches(text,"[.?!,;:…。，！？；：、।॥؛؟][)\\]}\"'’”»›」』〉》]*$")
    }
    private static func candidates(_ indices: [Int], _ words: [Word]) -> [[Int]] {
        var out: [[Int]] = [], i = 0
        while i < indices.count {
            guard wordLike(words[indices[i]].text) else { i += 1; continue }
            var end = i + 1
            while end < indices.count && !wordLike(words[indices[end]].text) { end += 1 }
            let run = Array(indices[i..<end])
            if terminal(run.map { words[$0].text }.joined()) { out.append(run) }
            i = end
        }
        return out
    }
    private static func median(_ values: [Int64]) -> Double {
        let sorted = values.sorted(), mid = sorted.count / 2
        return sorted.count.isMultiple(of:2) ? (Double(sorted[mid-1])+Double(sorted[mid]))/2 : Double(sorted[mid])
    }
    /// The readable writer runs before timing repair, exactly as in loadArtifact.ts.
    private static func readable(_ words: [Word]) -> [Block] {
        var grouped: [Block] = []
        for i in words.indices {
            let w = words[i]
            if let p = grouped.last {
                let gap = max(0,w.startMs-p.endMs)
                let target = p.wordIndices.count >= 96 || p.endMs-p.startMs >= 45_000
                let sentence = matches(words[p.wordIndices.last!].text,"[.!?][\"')\\]]*$")
                if p.speaker == w.speaker && gap <= 4200 && w.endMs-p.startMs <= 90_000 && p.wordIndices.count+1 <= 140 && !(target && (sentence || gap >= 2200)) {
                    grouped[grouped.count-1].wordIndices.append(i)
                    grouped[grouped.count-1].endMs = w.endMs
                    continue
                }
            }
            grouped.append(.init(id:i,speaker:w.speaker,startMs:w.startMs,endMs:w.endMs,wordIndices:[i]))
        }
        var merged: [Block] = []
        for b in grouped {
            if let p = merged.last {
                let small = p.wordIndices.count < 18 || b.wordIndices.count < 18 || p.endMs-p.startMs < 8000 || b.endMs-b.startMs < 8000
                if p.speaker == b.speaker && max(0,b.startMs-p.endMs) <= 4200 && p.wordIndices.count+b.wordIndices.count <= 140 && max(0,b.endMs-p.startMs) <= 90_000 && small {
                    merged[merged.count-1].endMs = b.endMs
                    merged[merged.count-1].wordIndices += b.wordIndices
                    continue
                }
            }
            merged.append(b)
        }
        return merged
    }
    public static func render(_ input: [Word], endsBoundedByAudio: Bool = false) -> Result {
        // Canonical order breaks timestamp ties. Indices always refer to the input, not the sort.
        var words = input
        // Portable's canonical items preserve input order; only display blocks are sorted later.
        var blocks = readable(words)
        if !endsBoundedByAudio {
            var population: [String:[Int64]] = [:], excluded: Set<Int> = []
            let repairs = blocks.map { candidates($0.wordIndices,words) }
            for run in repairs.flatMap({ $0 }) { excluded.formUnion(run) }
            for w in words where population[w.speaker] == nil { population[w.speaker] = [] }
            for i in words.indices where !excluded.contains(i) && wordLike(words[i].text) && words[i].endMs > words[i].startMs {
                population[words[i].speaker,default:[]].append(words[i].endMs-words[i].startMs)
            }
            let all = population.values.flatMap { $0 }, meetingMedian = all.count >= 8 ? median(all) : 250
            let budgets = population.mapValues { max(1000,4 * ($0.count >= 8 ? median($0) : meetingMedian)) }
            for (position,runs) in repairs.enumerated() {
                var changed = false
                for run in runs {
                    let start = run.map { words[$0].startMs }.min()!, end = run.map { words[$0].endMs }.max()!
                    let budget = Int64(budgets[blocks[position].speaker] ?? 1000)
                    if end-start > budget {
                        for i in run {
                            let clipped = max(words[i].startMs,min(words[i].endMs,start+budget))
                            changed = changed || clipped != words[i].endMs
                            words[i].endMs = clipped
                        }
                    }
                }
                if changed {
                    blocks[position].endMs = max(blocks[position].startMs,min(blocks[position].endMs,blocks[position].wordIndices.map { words[$0].endMs }.max()!))
                }
            }
        }
        blocks.sort { $0.startMs == $1.startMs ? $0.id < $1.id : $0.startMs < $1.startMs }
        let spans = blocks.map { b in union(b.wordIndices.compactMap { i in words[i].endMs > words[i].startMs ? Span(start:words[i].startMs,end:words[i].endMs) : nil }) }
        var runs: [Run] = [], open: [String:Int] = [:]
        func touches(_ a: [Span], _ b: [Span]) -> Bool {
            a.contains { x in b.contains { y in max(x.start,y.start)-min(x.end,y.end) <= 20 } }
        }
        for b in blocks.indices {
            let block = blocks[b], bound = spans[b]
            var joined = false
            if let previous = open[block.speaker], let first = bound.first, let lastBlock = runs[previous].blocks.last,
               !spans[lastBlock].isEmpty, abs(first.start-runs[previous].endMs) <= 400 {
                let between = spans[(lastBlock+1)..<b].flatMap { $0 }
                if b == lastBlock+1 || between.isEmpty || touches(between,spans[lastBlock]+bound) {
                    runs[previous].blocks.append(b)
                    runs[previous].endMs = max(runs[previous].endMs,bound.last!.end)
                    joined = true
                }
            }
            if !joined {
                let id = runs.count
                runs.append(.init(id:id,speaker:block.speaker,blocks:[b],startMs:bound.first?.start ?? block.startMs,endMs:bound.last?.end ?? block.endMs))
                open[block.speaker] = id
            }
        }
        let runSpans = runs.map { union($0.blocks.flatMap { spans[$0] }) }
        var candidates: [Int:(host:Int,after:Int)] = [:]
        let byStart = runs.indices.sorted { runs[$0].startMs == runs[$1].startMs ? $0 < $1 : runs[$0].startMs < runs[$1].startMs }
        var hosts: [Int] = [], pending = 0
        for r in byStart {
            while pending < byStart.count && runs[byStart[pending]].startMs < runs[r].startMs {
                let h = byStart[pending]
                if runs[h].blocks.count > 1 && !runSpans[h].isEmpty { hosts.append(h) }
                pending += 1
            }
            hosts.removeAll { runs[$0].endMs < runs[r].startMs }
            guard !runSpans[r].isEmpty && runSpans[r].reduce(Int64(0),{ $0+$1.end-$1.start }) <= 2000 else { continue }
            var best: (end:Int64,span:Int64,host:Int,after:Int)?
            for h in hosts.sorted() where runs[h].speaker != runs[r].speaker && runs[r].endMs <= runs[h].endMs {
                let host = runs[h]
                guard let before = host.blocks.lastIndex(where:{ spans[$0].first.map { $0.start < runs[r].startMs } ?? false }), before+1 < host.blocks.count,
                      let left = spans[host.blocks[before]].last, let right = spans[host.blocks[before+1]].first else { continue }
                let inside = host.blocks.filter { spans[$0].first.map { $0.start > runs[r].startMs && $0.start <= runs[r].endMs } ?? false }.count
                guard inside <= 1 && runs[r].startMs-left.end <= 500 && right.start-runs[r].endMs <= 500 else { continue }
                let duration = host.endMs-host.startMs
                if best == nil || left.end > best!.end || (left.end == best!.end && duration > best!.span) {
                    best = (left.end,duration,h,host.blocks[before])
                }
            }
            if let best { candidates[r] = (best.host,best.after) }
        }
        for (r,c) in candidates where candidates[c.host] == nil { runs[r].host = c.host; runs[r].afterBlock = c.after }
        var collisions: [(a:Int,b:Int,ms:Int64)] = []
        var sounding: [Int] = []
        for j in byStart {
            sounding.removeAll { runs[$0].endMs <= runs[j].startMs }
            for k in sounding {
                let a = min(k,j), b = max(k,j)
                guard runs[a].speaker != runs[b].speaker && runs[a].host != b && runs[b].host != a else { continue }
                let ms = overlap(runSpans[a],runSpans[b])
                if ms >= 150 { collisions.append((a,b,ms)) }
            }
            sounding.append(j)
        }
        // Viewer breaks equal-overlap ties by the first block's canonical id.
        collisions.sort { $0.ms == $1.ms ? blocks[runs[$0.a].blocks[0]].id < blocks[runs[$1.a].blocks[0]].id : $0.ms > $1.ms }
        for c in collisions {
            for (a,b) in [(c.a,c.b),(c.b,c.a)] where !runs[a].over.contains(runs[b].speaker) { runs[a].over.append(runs[b].speaker) }
        }
        func member(_ blockPositions: [Int], aside: Bool = false) -> Member {
            let indices = blockPositions.flatMap { blocks[$0].wordIndices }
            return .init(kind:aside ? "interjection" : "words",speaker:aside ? blocks[blockPositions[0]].speaker : nil,
                         crosstalk:aside ? (!indices.isEmpty && indices.allSatisfy { words[$0].lowConfidenceSpeaker == true }) : nil,
                         wordIndices:indices,text:indices.map { words[$0].text }.joined(separator:" "),blockIDs:blockPositions)
        }
        var childrenBySeam: [Int:[Int]] = [:]
        for child in byStart where runs[child].host != nil {
            childrenBySeam[runs[child].afterBlock!,default:[]].append(child)
        }
        var rows: [Row] = []
        for r in runs.indices where runs[r].host == nil {
            var paragraphs: [[Member]] = [], current: [Member] = [], previous: Int?
            for b in runs[r].blocks {
                if let previous, current.last?.kind == "words", b == previous+1 { paragraphs.append(current); current = [] }
                current.append(member([b])); previous = b
                for child in childrenBySeam[b] ?? [] { current.append(member(runs[child].blocks,aside:true)) }
            }
            if !current.isEmpty { paragraphs.append(current) }
            for (p,members) in paragraphs.enumerated() {
                let positions = members.flatMap(\.blockIDs), own = members.filter { $0.kind == "words" }.flatMap(\.wordIndices)
                let start = positions.map { blocks[$0].startMs }.min()!, end = positions.map { blocks[$0].endMs }.max()!
                let continuing = rows.last.map { $0.speaker == runs[r].speaker && start-$0.endMs <= 60_000 } ?? false
                rows.append(.init(id:blocks[positions[0]].id,turnID:r,speaker:runs[r].speaker,continuation:continuing,startMs:start,endMs:end,
                                  over:p == 0 ? runs[r].over : [],crosstalk:!own.isEmpty && own.allSatisfy { words[$0].lowConfidenceSpeaker == true },members:members))
            }
        }
        return .init(words:words,blocks:blocks,runs:runs,rows:rows)
    }
    /// MeetingView's human list, rather than exposing a comma-separated machine list.
    public static func speakerList(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator:", ") + " and " + names.last!
    }
}
