// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D25: select clean speech windows, trimming edges and bounding enrollment to
/// 45 s. Inputs belong to one separated audio group, after resolving merges.
public enum VoiceSelection {
    public static func windows(speaker: String, words: [LibraryTranscriptItem], durationMs: Int64, otherRanges:[Range<Int64>]? = nil) -> [Range<Int64>] {
        guard durationMs > 0 else { return [] }
        struct Event { let at: Int64; let own: Int; let other: Int }
        var events: [Event]=[]
        for turn in SpeakerTurn.grouping(words.filter { $0.endMs > $0.startMs }) {
            let start=turn.startMs, end=turn.endMs
            guard end > start else { continue }
            let own=turn.speaker == speaker
            if !own && otherRanges != nil { continue }
            events.append(.init(at:start,own:own ? 1:0,other:own ? 0:1))
            events.append(.init(at:end,own:own ? -1:0,other:own ? 0:-1))
        }
        for range in otherRanges ?? [] where !range.isEmpty {
            events.append(.init(at:range.lowerBound,own:0,other:1))
            events.append(.init(at:range.upperBound,own:0,other:-1))
        }
        events.sort { $0.at < $1.at }
        var selected: [Range<Int64>]=[], own=0, other=0, beginning: Int64?, i=0
        while i < events.count {
            let at=events[i].at, was=own > 0 && other == 0
            while i < events.count, events[i].at == at { own += events[i].own; other += events[i].other; i += 1 }
            let clean=own > 0 && other == 0
            if !was && clean { beginning=at }
            if was && !clean, let start=beginning {
                let a=start+200, b=at-200
                if b-a >= 1500 {
                    let parts=(b-a+9999)/10000
                    for part in 0..<parts { selected.append((a+(b-a)*part/parts)..<(a+(b-a)*(part+1)/parts)) }
                }
                beginning=nil
            }
        }
        var thirds=[[Range<Int64>]](repeating:[],count:3)
        for range in selected { thirds[min(2,Int((range.lowerBound+range.upperBound)/2 * 3 / durationMs))].append(range) }
        for index in 0..<3 { thirds[index].sort { $0.count == $1.count ? $0.lowerBound < $1.lowerBound : $0.count > $1.count } }
        var positions=[0,0,0], result:[Range<Int64>]=[], left:Int64=45000
        let first=0
        while left >= 1500 {
            var added=false
            for step in 0..<3 {
                let slot=(first+step)%3
                guard positions[slot] < thirds[slot].count else { continue }
                let range=thirds[slot][positions[slot]]; positions[slot] += 1
                let end=min(range.upperBound,range.lowerBound+left)
                result.append(range.lowerBound..<end); left -= end-range.lowerBound; added=true
            }
            if !added { break }
        }
        guard result.reduce(Int64(0),{ $0+Int64($1.count) }) >= 4000 else { return [] }
        return result.sorted { $0.lowerBound < $1.lowerBound }.compactMap {
            let a=max(0,min(durationMs,$0.lowerBound)), b=max(0,min(durationMs,$0.upperBound))
            return b > a ? a..<b:nil
        }
    }
    public static func matchingName(_ name: String, voices: [SavedVoice]) -> [SavedVoice] {
        func key(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator:" ").folding(options:[.diacriticInsensitive,.caseInsensitive],locale:Locale(identifier:"en_US_POSIX"))
        }
        let query=key(name)
        guard !query.isEmpty else { return [] }
        return voices.filter { key($0.name) == query || key($0.name).split(separator:" ").first.map(String.init) == query }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
