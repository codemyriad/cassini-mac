// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Exact half-up rounding of summed frame durations, including a source whose spans
/// use different rates. Fractional milliseconds stay rational until the final round.
struct WriterLossDuration {
    static func roundedMilliseconds(_ framesByRate: [Int:UInt64]) -> UInt64 {
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
