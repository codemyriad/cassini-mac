import Foundation
import CassiniKit

/// Original JSON decimal digits, so R5/D6.1 never rounds through a binary float.
/// Only floor(offset + frames*1000/rate) is needed; no general big-number library.
struct DisplayOffset {
    private var whole: Int64
    private var fraction: [UInt8]
    static let zero = DisplayOffset(whole: 0, fraction: [])
    private init(whole: Int64, fraction: [UInt8]) { self.whole = whole; self.fraction = fraction }
    init?(_ json: JSON?) {
        guard case .number(let literal)? = json else { return nil }
        var bytes = Array(literal.utf8)
        let negative = bytes.first == 45
        if negative { bytes.removeFirst() }
        let e = bytes.firstIndex { $0 == 69 || $0 == 101 } ?? bytes.count
        let exponentText = e < bytes.count ? String(decoding: bytes[(e + 1)...], as: UTF8.self) : "0"
        let mantissa = Array(bytes[..<e])
        let integerDigits = mantissa.firstIndex(of: 46) ?? mantissa.count
        let digits = mantissa.filter { $0 != 46 }.map { $0 - 48 }
        guard let first = digits.firstIndex(where: { $0 != 0 }) else { self = .zero; return }
        guard !negative else { return nil }
        guard let exponent = Int(exponentText) else {
            if exponentText.hasPrefix("-") { self = .zero; return }
            return nil
        }
        // Input JSON is bounded to 1 MiB. Larger exponents cannot cancel its
        // mantissa. A value below 10^-6 cannot carry at any supported WAV rate.
        if exponent > 2_000_000 { return nil }
        if exponent < -2_000_000 { self = .zero; return }
        let point = integerDigits + exponent - first
        let significant = Array(digits[first...])
        guard point <= 8 else { return nil }
        if point <= -6 { self = .zero; return }
        let integral: [UInt8]
        if point >= significant.count {
            integral = significant + Array(repeating: 0, count: point - significant.count)
            fraction = []
        } else if point > 0 {
            integral = Array(significant[..<point]); fraction = Array(significant[point...])
        } else {
            integral = [0]; fraction = Array(repeating: 0, count: -point) + significant
        }
        whole = integral.reduce(0) { $0 * 10 + Int64($1) }
        guard whole <= 86_400_000, whole < 86_400_000 || !fraction.contains(where: { $0 != 0 }) else { return nil }
    }
    /// Playback uses the actual validated source offset, never display's nil → 0.
    var milliseconds: Double { Double(whole) + (Double("0." + fraction.map(String.init).joined()) ?? 0) }
    func end(frames: UInt64, rate: Int) -> Int64 {
        let numerator = frames * 1000 // WAV size bounds keep this within UInt64.
        let quotient = numerator / UInt64(rate), remainder = Int(numerator % UInt64(rate))
        var carry = false
        if remainder != 0, !fraction.isEmpty {
            // fraction/10^n + remainder/rate >= 1 iff
            // fraction*rate >= (rate-remainder)*10^n. Compare exact digit strings.
            var product = fraction; var overflow = 0
            for i in product.indices.reversed() {
                let digit = Int(product[i]) * rate + overflow
                product[i] = UInt8(digit % 10); overflow = digit / 10
            }
            var prefix: [UInt8] = []
            while overflow > 0 { prefix.append(UInt8(overflow % 10)); overflow /= 10 }
            product = prefix.reversed() + product
            let left = Array(product.drop { $0 == 0 })
            let right = String(rate - remainder).utf8.map { $0 - 48 } + Array(repeating: UInt8(0), count: fraction.count)
            carry = left.count == right.count ? !left.lexicographicallyPrecedes(right) : left.count > right.count
        }
        return whole + Int64(quotient) + (carry ? 1 : 0)
    }
}
