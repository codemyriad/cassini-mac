// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
@testable import CassiniLibrary

/// #118 review: the aside and overlap passes sweep time instead of comparing every pair of
/// turns, so a long transcript prepares quickly and off the main actor, and a superseded
/// preparation stops when cancelled. The sweeps give exactly the pair scans' results.
struct M11SweepTests {
    /// 10,000 alternating one-second turns with no overlap: the pair scans needed about
    /// 200 million iterations here. The bound is only a failure bound for a sweep that takes
    /// milliseconds.
    @Test func aLongAlternatingTranscriptPreparesQuickly() throws {
        let items = (0..<10_000).map { index in
            LibraryTranscriptItem(speaker:index % 2 == 0 ? "a" : "b",startMs:Int64(index) * 1500,endMs:Int64(index) * 1500 + 1000,text:"word\(index)")
        }
        let started = ProcessInfo.processInfo.systemUptime
        let turns = try MeetingPresentation.turns(items,cancellable:true)
        #expect(ProcessInfo.processInfo.systemUptime - started < 5)
        #expect(turns.count == 10_000 && turns.allSatisfy { $0.host == nil && $0.over.isEmpty })
    }
    /// A preparation whose task was cancelled stops with CancellationError instead of finishing.
    @Test func aCancelledPreparationStops() async throws {
        let items = (0..<10_000).map { LibraryTranscriptItem(speaker:$0 % 2 == 0 ? "a" : "b",startMs:Int64($0) * 1500,endMs:Int64($0) * 1500 + 1000,text:"Word.") }
        let gate = AsyncStream<Void>.makeStream()
        let task = Task.detached { () async throws -> [MeetingPresentation.Turn] in
            for await _ in gate.stream { break }   // starts only once it has been cancelled
            return try MeetingPresentation.turns(items,cancellable:true)
        }
        task.cancel(); gate.continuation.yield(); gate.continuation.finish()
        await #expect(throws:CancellationError.self) { _ = try await task.value }
    }
    /// The sweeps against the pair scans they replace, on random overlapping transcripts.
    @Test func theSweepsMatchThePairScans() {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(bound)) }
        var hosted = 0, overlapping = 0
        for _ in 0..<300 {
            var at: Int64 = 0
            let items: [LibraryTranscriptItem] = (0..<(5 + next(40))).map { index in
                at += Int64(next(900)) - 200; at = max(0,at)
                return .init(speaker:["a","b","c"][next(3)],startMs:at,endMs:at + Int64(next(2500)),text:"w\(index)")
            }.sorted { $0.startMs < $1.startMs }
            let rendered = TranscriptRendering.render(items.map { .init(speaker:$0.speaker,startMs:$0.startMs,endMs:$0.endMs,text:$0.text) })
            var scanned: [MeetingPresentation.Turn] = rendered.runs.map { run in
                let blocks = run.blocks.map { rendered.blocks[$0] }
                var at = 0
                let parts = blocks.map { block -> Range<Int> in defer { at += block.wordIndices.count }; return at..<(at+block.wordIndices.count) }
                let words = blocks.map { $0.wordIndices.map { i in let w = rendered.words[i]; return LibraryTranscriptItem(speaker:w.speaker,startMs:w.startMs,endMs:w.endMs,text:w.text) } }
                return .init(id:run.id,speaker:run.speaker,items:words.flatMap { $0 },startMs:run.startMs,endMs:run.endMs,fragments:parts,pools:words.map(MeetingPresentation.spans))
            }
            Reference.attachAsides(&scanned); Reference.markOverlap(&scanned)
            #expect(rendered.runs.map(\.host) == scanned.map(\.host))
            let actualAsides = rendered.runs.map { host in
                rendered.runs.filter { $0.host == host.id }.map { child -> [Int] in
                    let seam = host.blocks.firstIndex(of:child.afterBlock!)!
                    let after = host.blocks.prefix(seam+1).reduce(0) { $0+rendered.blocks[$1].wordIndices.count }-1
                    return [after,child.id]
                }
            }
            #expect(actualAsides == scanned.map { $0.asides.map { [$0.after,$0.turn] } })
            #expect(rendered.runs.map(\.over) == scanned.map(\.over))
            hosted += scanned.filter { $0.host != nil }.count; overlapping += scanned.filter { !$0.over.isEmpty }.count
        }
        #expect(hosted > 0 && overlapping > 0,"the samples exercise both passes")
    }
}

/// The pair scans as #118 first wrote them (GNOME's loops), kept only to check the sweeps.
private enum Reference {
    typealias P = MeetingPresentation
    static func attachAsides(_ turns: inout [P.Turn]) {
        var candidates: [(turn: Int, host: Int, after: Int)] = []
        for turn in turns {
            let spans = P.union(turn.pools)
            guard !spans.isEmpty, spans.reduce(Int64(0),{ $0 + $1.end - $1.start }) <= P.asideMaxMs else { continue }
            var best: (score: (Int64,Int64), host: Int, after: Int)?
            for host in turns where host.speaker != turn.speaker && turn.endMs <= host.endMs {
                let pools = host.pools
                guard let before = pools.indices.last(where:{ !pools[$0].isEmpty && pools[$0][0].start < turn.startMs }),
                      before + 1 < pools.count, let left = pools[before].last, let right = pools[before + 1].first else { continue }
                if pools.filter({ !$0.isEmpty && turn.startMs < $0[0].start && $0[0].start <= turn.endMs }).count > 1 { continue }
                if turn.startMs - left.end > P.sideGapMs || right.start - turn.endMs > P.sideGapMs { continue }
                let score = (left.end,host.endMs - host.startMs)
                if best == nil || score > best!.score { best = (score,host.id,host.fragments[before].upperBound - 1) }
            }
            if let best { candidates.append((turn.id,best.host,best.after)) }
        }
        let asides = Set(candidates.map(\.turn))
        for candidate in candidates.sorted(by:{ turns[$0.turn].startMs == turns[$1.turn].startMs ? $0.turn < $1.turn : turns[$0.turn].startMs < turns[$1.turn].startMs }) where !asides.contains(candidate.host) {
            turns[candidate.turn].host = candidate.host
            turns[candidate.host].asides.append((candidate.after,candidate.turn))
        }
    }
    static func markOverlap(_ turns: inout [P.Turn]) {
        let pools = turns.map { P.union($0.pools) }
        var collisions: [(i:Int,j:Int,ms:Int64)] = []
        for i in turns.indices {
            for j in turns.indices where j > i {
                let left = turns[i], right = turns[j]
                guard left.host != j, right.host != i, left.speaker != right.speaker, max(left.startMs,right.startMs) < min(left.endMs,right.endMs) else { continue }
                var a = 0, b = 0, overlap: Int64 = 0
                while a < pools[i].count && b < pools[j].count {
                    let x = pools[i][a], y = pools[j][b]
                    overlap += max(0,min(x.end,y.end) - max(x.start,y.start))
                    if x.end < y.end { a += 1 } else { b += 1 }
                }
                guard overlap >= P.overlapMinMs else { continue }
                collisions.append((i,j,overlap))
            }
        }
        collisions.sort { $0.ms == $1.ms ? ($0.i == $1.i ? $0.j < $1.j : $0.i < $1.i) : $0.ms > $1.ms }
        for c in collisions {
            for (i,j) in [(c.i,c.j),(c.j,c.i)] where !turns[i].over.contains(turns[j].speaker) { turns[i].over.append(turns[j].speaker) }
        }
    }
}
