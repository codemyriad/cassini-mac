// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D69 native writer loss, shared by the writer (RecordingSession) and every reader, so the
/// stored problem sentence and its recognition can never drift apart.
///
/// D69.2: the file stays as D69 says (writer ranges, droppedFrames, the stored sentence, io,
/// interrupted, end reason error), but a recording whose only problem is writer loss is
/// presented as a normal recording, with one quiet Recording details line per source of at
/// least 1 s. The stored sentence is for diagnostics and other readers, never shown.
public enum WriterLoss {
    /// D69: one shared problem sentence per source.
    public static func sentence(milliseconds: UInt64, kind: String) -> String {
        "\(milliseconds) ms of \(kind) audio was lost because the computer could not keep up; the gaps contain silence."
    }
    private static let trailingSentence = try! NSRegularExpression(
        pattern:"(?:^| )[0-9]+ ms of [A-Za-z]+ audio was lost because the computer could not keep up; the gaps contain silence\\.$")
    /// The stored problem without its D69 sentences. The writer appends them after every other
    /// diagnostic, so they are removed from the end; anything else stays in `rest`.
    public static func strip(_ problem: String) -> (rest: String, count: Int) {
        var rest = problem, count = 0
        while let match = trailingSentence.firstMatch(in:rest,range:NSRange(rest.startIndex...,in:rest)),
              let range = Range(match.range,in:rest) {
            rest.removeSubrange(range); count += 1
        }
        return (rest.trimmingCharacters(in:.whitespaces),count)
    }
    /// D69.2, from stored facts only (D47): session.json would read as a completed recording
    /// with D69's writer additions taken out. The only problem is writer loss: no other
    /// diagnostic in `problem`, no failed track, no input or jump gap of 1 s or more (none
    /// possibly hidden after an overflow marker), and some audio was received.
    public static func isWriterOnly(_ session: JSON) -> Bool {
        guard session["state"]?.string == "interrupted", session["problemKind"]?.string == "io",
              let problem = session["problem"]?.string else { return false }
        let stripped = strip(problem)
        guard stripped.count > 0, stripped.rest.isEmpty, let tracks = session["tracks"]?.array else { return false }
        var received = false
        for track in tracks {
            if let kind = track["problemKind"], !kind.isNull { return false }
            guard let rate = track["sampleRate"]?.double, rate > 0, let frames = track["frames"]?.double else { return false }
            let gapFrames = track["gapFrames"]?.double ?? 0
            var padding = 0.0, listedInput = 0.0, overflow = false
            if let gaps = track["gaps"] {
                guard let ranges = gaps.array else { return false }
                for range in ranges {
                    let kind = range["kind"]?.string ?? ""
                    if kind == "overflow" { overflow = true; continue }
                    let length = range["frames"]?.double
                    padding += length ?? 0
                    guard !["prefix","writer"].contains(kind) else { continue }
                    listedInput += length ?? 0
                    if let length { if length >= rate { return false } }
                    else if (range["durationMs"]?.double ?? 0) >= 1000 { return false }
                }
                // Input or jump frames counted but not listed after the marker may hide a long gap.
                if overflow, gapFrames - listedInput >= rate { return false }
            } else {
                guard gapFrames == 0 else { return false }
                padding = track["droppedFrames"]?.double ?? 0
            }
            let got = track["receivedFrames"]?.double ?? (frames - padding)
            if got > 0 { received = true }
        }
        return received
    }

    /// Exact half-up rounding of summed frame durations, including a source whose spans
    /// use different rates. Fractional milliseconds stay rational until the final round.

    public static func roundedMilliseconds(_ framesByRate: [Int:UInt64]) -> UInt64 {
        var whole: UInt64 = 0, numerator = Natural(0), denominator = Natural(1)
        for (rate,frames) in framesByRate {
            let divisor = UInt64(rate)
            whole += frames / divisor * 1000
            let units = frames % divisor * 1000
            whole += units / divisor
            numerator = numerator.multiplied(by:UInt32(rate)).adding(denominator.multiplied(by:UInt32(units % divisor)))
            denominator = denominator.multiplied(by:UInt32(rate))
            // Both fractions were below one, so at most one millisecond carries.
            if numerator >= denominator { numerator = numerator.subtracting(denominator); whole += 1 }
        }
        return whole + (numerator.multiplied(by:2) >= denominator ? 1 : 0)
    }

    /// Small unbounded integers: rates are at most 192 kHz and there are at most
    /// 64 spans. Multiplication needs only one small factor; no general division.
    private struct Natural: Comparable {
        var words: [UInt32]
        init(_ value: UInt32) { words = [value] }
        private init(words: [UInt32]) {
            self.words = words
            while self.words.count > 1 && self.words.last == 0 { self.words.removeLast() }
        }
        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.words.count != rhs.words.count { return lhs.words.count < rhs.words.count }
            for (left,right) in zip(lhs.words.reversed(),rhs.words.reversed()) where left != right { return left < right }
            return false
        }
        func multiplied(by factor: UInt32) -> Self {
            var result: [UInt32] = [], carry: UInt64 = 0
            for word in words {
                let value = UInt64(word) * UInt64(factor) + carry
                result.append(UInt32(truncatingIfNeeded:value)); carry = value >> 32
            }
            if carry > 0 { result.append(UInt32(carry)) }
            return Self(words:result)
        }
        func adding(_ other: Self) -> Self {
            var result: [UInt32] = [], carry: UInt64 = 0
            for index in 0..<max(words.count,other.words.count) {
                let value = UInt64(index < words.count ? words[index] : 0) + UInt64(index < other.words.count ? other.words[index] : 0) + carry
                result.append(UInt32(truncatingIfNeeded:value)); carry = value >> 32
            }
            if carry > 0 { result.append(UInt32(carry)) }
            return Self(words:result)
        }
        func subtracting(_ other: Self) -> Self {
            precondition(self >= other)
            var result: [UInt32] = [], borrow: UInt64 = 0
            for index in words.indices {
                let left = UInt64(words[index]), right = UInt64(index < other.words.count ? other.words[index] : 0) + borrow
                result.append(UInt32(truncatingIfNeeded:left &- right)); borrow = left < right ? 1 : 0
            }
            return Self(words:result)
        }
    }
}
