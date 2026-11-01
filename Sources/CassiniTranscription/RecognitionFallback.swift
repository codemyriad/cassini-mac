// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D52.4 R71 (G10/M13): a VAD-free windowed decode for a track whose VAD pass found
/// too few words. Per track, never the mix. A port of GNOME cassini-gnome#149
/// (`recognition_fallback.py` at 26c1b0a8), itself from gocassini 5a5d77bb
/// (`dedupMergedFallbackWords`, `filterWordsByEnergy`, `nonVADWindowBounds`).
public enum RecognitionFallback {
    public static let rate = 16000
    public static let frame = 512
    public static let fewWords = 10
    public static let minActiveSeconds = 15.0
    public static let window = 15 * rate
    public static let overlap = rate / 2
    static let minWindowActiveSeconds = 0.5
    static let activeDBFS = -50.0
    static let floorMarginDB = 12.0
    static let floorPercentile = 0.10
    static let floorFrames = 10 * rate / frame
    static let minRunFrames = 5   // active runs shorter than 160 ms (clicks, taps) are not speech
    static let silent: UInt8 = 255
    // gocassini word energy gate.
    static let wordPeak = 0.001, wordRMS = 0.0001, wordActive = 0.0005
    static let wordActiveMs = 5, wordPreMs: Int64 = 100, wordPostMs: Int64 = 200
    // gocassini seam alignment tolerances.
    static let duplicateMs: Int64 = 400, singletonMs: Int64 = 200, shiftMs: Int64 = 100

    /// Per-frame mean-removed level codes of one track. On Mac, frames outside the
    /// track's present and owned time (D52.2) are fed as silence: they are inactive.
    public struct ActivityMeter: Sendable {
        public private(set) var codes: [UInt8] = []
        public private(set) var samples = 0
        private var tail: [Float] = []
        public init() {}
        public mutating func feed(_ block: [Float]) {
            samples += block.count
            var data = tail + block
            let whole = data.count / frame * frame
            tail = Array(data[whole...]); data.removeSubrange(whole...)
            for start in stride(from:0,to:whole,by:frame) {
                var sum = 0.0
                for i in start..<start+frame { sum += Double(data[i]) }
                let mean = sum / Double(frame)
                var energy = 0.0
                for i in start..<start+frame { let c = Double(data[i]) - mean; energy += c*c }
                let level = (energy / Double(frame)).squareRoot()
                codes.append(level <= 0 ? silent : UInt8(min(120,max(0,(120 + 20*log10(level)).rounded(.toNearestOrEven)))))
            }
        }
        /// max(-50 dBFS, floor + 12 dB); the floor is the 10th percentile of audible frames.
        public func thresholdDB() -> (floor: Double?, threshold: Double) {
            let levels = codes.filter { $0 != silent && Int($0) - 120 > -90 }.sorted()
            guard levels.count >= floorFrames else { return (nil,activeDBFS) }
            let floor = Double(levels[Int(floorPercentile * Double(levels.count - 1))]) - 120
            return (floor,max(activeDBFS,floor + floorMarginDB))
        }
        public func active() -> [Bool] {
            let threshold = thresholdDB().threshold
            let loud = codes.map { $0 != silent && Double(Int($0) - 120) >= threshold }
            var active = [Bool](repeating:false,count:loud.count), run = 0
            for (index,value) in (loud + [false]).enumerated() {
                if value { run += 1; continue }
                if run >= minRunFrames { for i in index-run..<index { active[i] = true } }
                run = 0
            }
            return active
        }
        public func activeSeconds(_ active: [Bool]? = nil) -> Double {
            Double((active ?? self.active()).filter { $0 }.count * frame) / Double(rate)
        }
    }

    /// 15 s windows overlapping by 0.5 s; the last one is short.
    public static func windowBounds(_ total: Int) -> [Range<Int>] {
        guard total > 0 else { return [] }
        guard total > window else { return [0..<total] }
        var bounds: [Range<Int>] = []
        for start in stride(from:0,to:total,by:window - overlap) {
            let end = start + window
            if end >= total { bounds.append(start..<total); break }
            bounds.append(start..<end)
        }
        return bounds
    }
    /// Windows holding at least half a second of active frames.
    public static func activeWindows(_ total: Int, active: [Bool]) -> [Range<Int>] {
        let needed = Int((minWindowActiveSeconds * Double(rate) / Double(frame)).rounded(.up))
        return windowBounds(total).filter { range in
            let a = range.lowerBound / frame, b = min(active.count,(range.upperBound + frame - 1) / frame)
            return a < b && active[a..<b].filter { $0 }.count >= needed
        }
    }

    public struct Word: Equatable, Sendable {
        public var text: String, startMs: Int64, endMs: Int64
        var window = 0
        public init(text: String, startMs: Int64, endMs: Int64) { self.text = text; self.startMs = startMs; self.endMs = endMs }
        public static func == (a: Word, b: Word) -> Bool { a.text == b.text && a.startMs == b.startMs && a.endMs == b.endMs }
    }

    /// Keep words whose own audio (100 ms before, 200 ms after) is not near-silence.
    /// The window's mean is removed first, so a DC offset is not energy.
    public static func energetic(_ words: [Word], samples: [Float], baseMs: Int64) -> [Word] {
        guard !samples.isEmpty else { return [] }
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        let centred = samples.map { Double($0) - mean }
        let audioEnd = Int64(centred.count) * 1000 / Int64(rate)
        let minimumActive = (rate * wordActiveMs + 999) / 1000
        return words.filter { word in
            var start = word.startMs - baseMs, end = word.endMs - baseMs
            if end < 0 || end < start || start > audioEnd { return false }
            start = max(0,max(0,start) - wordPreMs); end = min(audioEnd,end + wordPostMs)
            let first = Int(start * Int64(rate) / 1000), last = min(centred.count,Int((end * Int64(rate) + 999) / 1000))
            guard last > first else { return false }
            var peak = 0.0, energy = 0.0, loud = 0
            for value in centred[first..<last] {
                let a = abs(value); peak = max(peak,a); energy += a*a; if a >= wordActive { loud += 1 }
            }
            return peak >= wordPeak && energy / Double(last - first) >= wordRMS * wordRMS && loud >= minimumActive
        }
    }

    /// gocassini normalizeOverlapWord, with NFC and Unicode case folding.
    public static func normal(_ text: String) -> String {
        var value = text.precomposedStringWithCanonicalMapping.replacingOccurrences(of:"\u{2018}",with:"'").replacingOccurrences(of:"\u{2019}",with:"'")
            .folding(options:[.caseInsensitive],locale:nil)
        let strip = Set(" \t\n\r\u{0C}\u{0B},!?;:\"“”()[]{}<>")
        while let c = value.first, strip.contains(c) { value.removeFirst() }
        while let c = value.last, strip.contains(c) { value.removeLast() }
        while value.last == "." { value.removeLast() }
        return value.contains(where:{ $0.isLetter || $0.isNumber }) ? value : ""
    }
    static func midpoint(_ w: Word) -> Int64 { w.endMs <= w.startMs ? w.startMs : w.startMs + (w.endMs - w.startMs) / 2 }
    static func inOverlap(_ words: [Word], _ left: Int64, _ right: Int64) -> Bool {
        words.contains { w in
            guard w.endMs >= w.startMs, !normal(w.text).isEmpty else { return false }
            return w.endMs == w.startMs ? (left...right).contains(w.startMs) : w.endMs > left && w.startMs < right
        }
    }
    static func references(_ words: [Word], _ left: Int64, _ right: Int64) -> [(Int,String,Int64)] {
        words.enumerated().compactMap { index,w in
            let n = normal(w.text)
            return w.endMs >= w.startMs && w.endMs >= left - duplicateMs && w.startMs <= right + duplicateMs && !n.isEmpty ? (index,n,w.startMs) : nil
        }
    }
    /// Order-preserving alignment of equal normalized words starting within 400 ms.
    static func align(_ previous: [Word], _ following: [Word], _ left: Int64, _ right: Int64) -> [(Int,Int)] {
        let a = references(previous,left,right), b = references(following,left,right)
        guard !a.isEmpty, !b.isEmpty else { return [] }
        struct Cell { var matches = 0, distance: Int64 = 0, step: Character = " " }
        var cells = [[Cell]](repeating:[Cell](repeating:Cell(),count:b.count+1),count:a.count+1)
        for i in 1...a.count { cells[i][0] = Cell(matches:cells[i-1][0].matches,distance:cells[i-1][0].distance,step:"l") }
        for j in 1...b.count { cells[0][j] = Cell(matches:cells[0][j-1].matches,distance:cells[0][j-1].distance,step:"r") }
        for i in 1...a.count {
            for j in 1...b.count {
                var best = Cell(matches:cells[i-1][j].matches,distance:cells[i-1][j].distance,step:"l")
                let right = cells[i][j-1]
                if right.matches > best.matches || right.matches == best.matches && right.distance < best.distance {
                    best = Cell(matches:right.matches,distance:right.distance,step:"r")
                }
                let distance = abs(a[i-1].2 - b[j-1].2)
                if a[i-1].1 == b[j-1].1 && distance <= duplicateMs {
                    let diagonal = cells[i-1][j-1]
                    let matched = Cell(matches:diagonal.matches + 1,distance:diagonal.distance + distance,step:"m")
                    if matched.matches > best.matches || matched.matches == best.matches && matched.distance <= best.distance { best = matched }
                }
                cells[i][j] = best
            }
        }
        var matches: [(Int,Int)] = [], i = a.count, j = b.count
        while i > 0 || j > 0 {
            switch cells[i][j].step {
            case "m": matches.append((a[i-1].0,b[j-1].0)); i -= 1; j -= 1
            case "l": i -= 1
            case "r": j -= 1
            default: i = 0; j = 0
            }
        }
        return matches.reversed()
    }
    static func confident(_ matches: [(Int,Int)], _ previous: [Word], _ following: [Word], _ right: Int64) -> [(Int,Int)] {
        var keep = [Bool](repeating:false,count:matches.count)
        for (index,(old,new)) in matches.enumerated() {
            let a = previous[old], b = following[new]
            if abs(a.startMs - b.startMs) <= singletonMs || (a.startMs == a.endMs && a.endMs == right) { keep[index] = true }
        }
        if matches.count > 1 {
            for index in 0..<matches.count-1 {
                let (old,new) = matches[index], (nextOld,nextNew) = matches[index+1]
                guard nextOld == old + 1, nextNew == new + 1 else { continue }
                let shift = following[new].startMs - previous[old].startMs, nextShift = following[nextNew].startMs - previous[nextOld].startMs
                if abs(shift - nextShift) <= shiftMs { keep[index] = true; keep[index+1] = true }
            }
        }
        return zip(matches,keep).filter { $0.1 }.map(\.0)
    }
    /// Merge the next window's words into the previous ones across one overlap.
    public static func mergeSeam(_ previous: [Word], _ following: [Word], windowStartMs: Int64, overlapMs: Int64) -> [Word] {
        guard !previous.isEmpty, !following.isEmpty else { return previous + following }
        let right = windowStartMs + overlapMs
        let matches = confident(align(previous,following,windowStartMs,right),previous,following,right)
        if matches.isEmpty && inOverlap(previous,windowStartMs,right) && inOverlap(following,windowStartMs,right) {
            // Two populated readings that cannot be aligned: one owner each side of the midpoint.
            let cut = windowStartMs + overlapMs / 2
            var kept = previous
            while let last = kept.last, last.startMs >= cut { kept.removeLast() }
            return kept + following.filter { $0.startMs >= cut }
        }
        var droppedPrevious = Set<Int>(), droppedFollowing = Set<Int>()
        for (old,new) in matches {
            let a = previous[old], b = following[new]
            let aTimed = a.endMs > a.startMs, bTimed = b.endMs > b.startMs
            if aTimed != bTimed {
                if bTimed { droppedPrevious.insert(old) } else { droppedFollowing.insert(new) }
                continue
            }
            let oldContext = max(0,right - midpoint(a)), newContext = max(0,midpoint(b) - windowStartMs)
            if newContext > oldContext { droppedPrevious.insert(old) } else { droppedFollowing.insert(new) }
        }
        let merged = previous.enumerated().filter { !droppedPrevious.contains($0.offset) }.map(\.element)
            + following.enumerated().filter { !droppedFollowing.contains($0.offset) }.map(\.element)
        // Python's sorted() is stable: equal starts keep their order.
        return merged.enumerated().sorted { $0.element.startMs != $1.element.startMs ? $0.element.startMs < $1.element.startMs : $0.offset < $1.offset }.map(\.element)
    }
    /// gocassini margin: the fallback must clearly beat the VAD pass to replace it.
    public static func need(_ vadWords: Int) -> Int { vadWords == 0 ? 1 : vadWords + max(2,Int((Double(vadWords) / 5).rounded(.up))) }
}
