// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Physical source indices are retained until after classification. A shared
/// speaker name must never make two separate microphone spans one source.
enum MicrophoneEcho {
    struct Word {
        let track: Int
        let startMs: Int64
        let endMs: Int64
        let normalizedText: String
        let rmsDbfs: Double?
        init(track: Int, startMs: Int64, endMs: Int64, text: String, rmsDbfs: Double?) {
            self.track = track; self.startMs = startMs; self.endMs = endMs
            normalizedText = MicrophoneEcho.normalized(text); self.rmsDbfs = rmsDbfs
        }
    }
    static func normalized(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX"))
        let scalars = Array(folded.unicodeScalars)
        var first = 0, last = scalars.count
        while first < last && CharacterSet.punctuationCharacters.contains(scalars[first]) { first += 1 }
        while last > first && CharacterSet.punctuationCharacters.contains(scalars[last-1]) { last -= 1 }
        return String(String.UnicodeScalarView(scalars[first..<last]))
    }
    /// The callback measures any other source over [word.start-600, word.end].
    /// It is needed only for unmatched words bracketed by direct echo anchors.
    static func flags(_ words: [Word], microphones: Set<Int>, others: Set<Int>,
                      windowIsLouder: (Int) throws -> Bool) rethrows -> [Bool] {
        guard !microphones.isEmpty, !others.isEmpty else { return Array(repeating:false,count:words.count) }
        var grouped: [String:[(Int64,Double)]] = [:]
        for word in words where others.contains(word.track) {
            if let level = word.rmsDbfs, level.isFinite { grouped[word.normalizedText,default:[]].append((word.startMs,level)) }
        }
        let levels = grouped.mapValues(LevelIndex.init)
        var direct = Array(repeating:false,count:words.count)
        for (index,word) in words.enumerated() where microphones.contains(word.track) {
            guard let level = word.rmsDbfs, level.isFinite, let other = levels[word.normalizedText] else { continue }
            let (lower,overflow) = word.startMs.subtractingReportingOverflow(600)
            direct[index] = level <= other.maximum(from:overflow ? .min : lower,through:word.startMs)-6
        }
        var result = direct
        for track in microphones {
            let ordered = words.indices.filter { words[$0].track == track }.sorted {
                words[$0].startMs == words[$1].startMs ? $0 < $1 : words[$0].startMs < words[$1].startMs
            }
            var next = Array<Int?>(repeating:nil,count:ordered.count), anchor: Int?
            for position in ordered.indices.reversed() {
                next[position] = anchor
                if direct[ordered[position]] { anchor = ordered[position] }
            }
            anchor = nil
            for (position,index) in ordered.enumerated() {
                if direct[index] { anchor = index; continue }
                guard let before = anchor, let after = next[position],
                      words[index].rmsDbfs?.isFinite == true else { continue }
                let (gap,overflow) = words[after].startMs.subtractingReportingOverflow(words[before].endMs)
                if !overflow && gap < 1000 {
                    if try windowIsLouder(index) { result[index] = true }
                }
            }
        }
        return result
    }

    /// Range maxima avoid comparing every repeated word against every other
    /// occurrence, even when many sources share the same word and timestamp.
    private struct LevelIndex {
        let starts: [Int64]
        let size: Int
        let tree: [Double]
        init(_ values: [(Int64,Double)]) {
            let ordered = values.sorted { $0.0 < $1.0 }
            starts = ordered.map(\.0)
            var size = 1
            while size < ordered.count { size *= 2 }
            self.size = size
            var tree = Array(repeating:-Double.infinity,count:size*2)
            for (index,value) in ordered.enumerated() { tree[size+index] = value.1 }
            if size > 1 { for index in stride(from:size-1,through:1,by:-1) { tree[index] = max(tree[index*2],tree[index*2+1]) } }
            self.tree = tree
        }
        func bound(_ time: Int64, inclusive: Bool) -> Int {
            var low = 0, high = starts.count
            while low < high {
                let middle = low+(high-low)/2
                if starts[middle] < time || (inclusive && starts[middle] == time) { low = middle+1 } else { high = middle }
            }
            return low
        }
        func maximum(from lower: Int64, through upper: Int64) -> Double {
            var first = size+bound(lower,inclusive:false), last = size+bound(upper,inclusive:true)
            var result = -Double.infinity
            while first < last {
                if first%2 == 1 { result = max(result,tree[first]); first += 1 }
                if last%2 == 1 { last -= 1; result = max(result,tree[last]) }
                first /= 2; last /= 2
            }
            return result
        }
    }
}
