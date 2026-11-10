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
    private static func firstEndingAfter(_ spans: [Span], _ time: Int64) -> Int {
        var lo = 0, hi = spans.count
        while lo < hi {
            let mid = lo + (hi-lo)/2
            if spans[mid].end <= time { lo = mid+1 } else { hi = mid }
        }
        return lo
    }
    private static func overlap(_ a: [Span], _ b: [Span]) -> Int64 {
        guard let first = b.first else { return 0 }
        var i = firstEndingAfter(a,first.start)
        guard i < a.count else { return 0 }
        var j = firstEndingAfter(b,a[i].start), total: Int64 = 0
        while i < a.count && j < b.count {
            total += max(0,min(a[i].end,b[j].end) - max(a[i].start,b[j].start))
            if a[i].end < b[j].end { i += 1 } else { j += 1 }
        }
        return total
    }
    private struct BlockStarts {
        let values: [Int64]
        let lastPositions: [Int]
        init(_ blocks: [Int], _ spans: [[Span]]) {
            let entries = blocks.enumerated().compactMap { position,block in
                spans[block].first.map { (start:$0.start,position:position) }
            }.sorted { $0.start < $1.start }
            values = entries.map(\.start)
            // Prefix maxima preserve the viewer's last matching block position,
            // even when leading zero-duration words reorder audible starts.
            var last = -1
            lastPositions = entries.map { last = max(last,$0.position); return last }
        }
        func bound(_ time: Int64, inclusive: Bool) -> Int {
            var lo = 0, hi = values.count
            while lo < hi {
                let mid = lo + (hi-lo)/2
                if values[mid] < time || inclusive && values[mid] == time { lo = mid+1 } else { hi = mid }
            }
            return lo
        }
        func before(_ time: Int64) -> Int? {
            let end = bound(time,inclusive:false)
            return end == 0 ? nil : lastPositions[end-1]
        }
        func inside(_ start: Int64, _ end: Int64) -> Int {
            bound(end,inclusive:true) - bound(start,inclusive:true)
        }
    }
    private static func wordLike(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            switch $0.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber: return true
            default: return false
            }
        }
    }
    private static let terminalMarks: Set<UInt32> = [46,63,33,44,59,58,0x2026,0x3002,0xFF0E,0xFF01,0xFF1F,0xFF1B,0xFF1A,0xFF0C,0x3001,0x0964,0x0965,0x061B,0x061F]
    private static let terminalClosers: Set<UInt32> = [41,93,125,34,39,0x2019,0x201D,0x00BB,0x203A,0x300D,0x300F,0x3009,0x300B]
    private static let sentenceMarks: Set<UInt32> = [46,33,63]
    private static let sentenceClosers: Set<UInt32> = [34,39,41,93]
    private static func endsWith(_ text: String, marks: Set<UInt32>, closers: Set<UInt32>) -> Bool {
        for scalar in text.unicodeScalars.reversed() where !closers.contains(scalar.value) {
            return marks.contains(scalar.value)
        }
        return false
    }
    private static func terminal(_ text: String) -> Bool {
        endsWith(text,marks:terminalMarks,closers:terminalClosers)
    }
    /// Only the literal producer boolean true may bypass timing repair.
    public static func endsBoundedByAudio(provenance: JSON?) -> Bool {
        provenance?["wordTimings"]?["endsBoundedByAudio"] == .bool(true)
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
    private static func readable(_ words: [Word], breaks: Set<Int>, check: () throws -> Void) rethrows -> [Block] {
        var grouped: [Block] = []
        for i in words.indices {
            try check()
            let w = words[i]
            if let p = grouped.last {
                let gap = max(0,w.startMs-p.endMs)
                let target = p.wordIndices.count >= 96 || p.endMs-p.startMs >= 45_000
                let sentence = endsWith(words[p.wordIndices.last!].text,marks:sentenceMarks,closers:sentenceClosers)
                if !breaks.contains(i) && p.speaker == w.speaker && gap <= 4200 && w.endMs-p.startMs <= 90_000 && p.wordIndices.count+1 <= 140 && !(target && (sentence || gap >= 2200)) {
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
                if !breaks.contains(b.wordIndices[0]) && p.speaker == b.speaker && max(0,b.startMs-p.endMs) <= 4200 && p.wordIndices.count+b.wordIndices.count <= 140 && max(0,b.endMs-p.startMs) <= 90_000 && small {
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
        (try? render(input,endsBoundedByAudio:endsBoundedByAudio,breakBefore:[],cancellable:false)) ?? .init(words:input,blocks:[],runs:[],rows:[])
    }
    /// App-owned source gaps are explicit boundaries, independent of the viewer's readable breaks.
    /// Cancellation is checked throughout preparation so superseded long transcripts stop promptly.
    public static func render(_ input: [Word], endsBoundedByAudio: Bool = false, breakBefore: Set<Int>, cancellable: Bool, separates: (Int,Int) -> Bool = { _,_ in false }) throws -> Result {
        let check: () throws -> Void = cancellable ? { try Task.checkCancellation() } : {}
        try check()
        // Canonical order breaks timestamp ties. Indices always refer to the input, not the sort.
        var words = input
        // Portable's canonical items preserve input order; only display blocks are sorted later.
        var blocks = try readable(words,breaks:breakBefore,check:check)
        if !endsBoundedByAudio {
            var population: [String:[Int64]] = [:], excluded: Set<Int> = []
            let repairs = blocks.map { Self.candidates($0.wordIndices,words) }
            for run in repairs.flatMap({ $0 }) { excluded.formUnion(run) }
            for w in words where population[w.speaker] == nil { population[w.speaker] = [] }
            for i in words.indices where !excluded.contains(i) && wordLike(words[i].text) && words[i].endMs > words[i].startMs {
                population[words[i].speaker,default:[]].append(words[i].endMs-words[i].startMs)
            }
            let all = population.values.flatMap { $0 }, meetingMedian = all.count >= 8 ? median(all) : 250
            let budgets = population.mapValues { max(1000,4 * ($0.count >= 8 ? median($0) : meetingMedian)) }
            for (position,runs) in repairs.enumerated() {
                try check()
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
            try check()
            let block = blocks[b], bound = spans[b]
            var joined = false
            if !breakBefore.contains(block.wordIndices[0]), let previous = open[block.speaker], let first = bound.first, let lastBlock = runs[previous].blocks.last,
               !spans[lastBlock].isEmpty, !separates(blocks[lastBlock].wordIndices.last!,block.wordIndices[0]), abs(first.start-runs[previous].endMs) <= 400 {
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
        let blockStarts = runs.map { $0.blocks.count > 1 ? BlockStarts($0.blocks,spans) : nil }
        var candidates: [Int:(host:Int,after:Int)] = [:]
        let byStart = runs.indices.sorted { runs[$0].startMs == runs[$1].startMs ? $0 < $1 : runs[$0].startMs < runs[$1].startMs }
        // Rejoining preserves the viewer's first-block startMs, but a later
        // block can sound earlier. Sweep audible spans independently of display order.
        let audibleByStart = runs.indices.filter { !runSpans[$0].isEmpty }.sorted {
            let a = runSpans[$0][0].start, b = runSpans[$1][0].start
            return a == b ? $0 < $1 : a < b
        }
        var hosts: [Int] = [], pending = 0
        for r in byStart {
            try check()
            while pending < audibleByStart.count && runSpans[audibleByStart[pending]][0].start < runs[r].startMs {
                let h = audibleByStart[pending]
                if runs[h].blocks.count > 1 { hosts.append(h) }
                pending += 1
            }
            hosts.removeAll { runs[$0].endMs < runs[r].startMs }
            guard !runSpans[r].isEmpty && runSpans[r].reduce(Int64(0),{ $0+$1.end-$1.start }) <= 2000 else { continue }
            var best: (end:Int64,span:Int64,host:Int,after:Int)?
            for h in hosts.sorted() where runs[h].speaker != runs[r].speaker && runs[r].endMs <= runs[h].endMs {
                let host = runs[h]
                guard let starts = blockStarts[h], let before = starts.before(runs[r].startMs), before+1 < host.blocks.count,
                      let left = spans[host.blocks[before]].last, let right = spans[host.blocks[before+1]].first else { continue }
                let inside = starts.inside(runs[r].startMs,runs[r].endMs)
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
        for j in audibleByStart {
            try check()
            let start = runSpans[j][0].start
            sounding.removeAll { runSpans[$0].last!.end <= start }
            for k in sounding {
                let a = min(k,j), b = max(k,j)
                guard runs[a].speaker != runs[b].speaker && runs[a].host != b && runs[b].host != a else { continue }
                let ms = overlap(runSpans[a],runSpans[b])
                if ms >= 150 { collisions.append((a,b,ms)) }
            }
            sounding.append(j)
        }
        // Viewer breaks equal-overlap ties by the first block's canonical id.
        collisions.sort {
            if $0.ms != $1.ms { return $0.ms > $1.ms }
            let a0 = blocks[runs[$0.a].blocks[0]].id, a1 = blocks[runs[$1.a].blocks[0]].id
            return a0 == a1 ? $0.b < $1.b : a0 < a1
        }
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
            try check()
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
