// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Protocol #65: first terminal extension cause, including future identifier
/// codes. Invalid diagnostics are ignored without changing Stop/fallback policy.
public struct BrowserCaptureLossCause: RawRepresentable, Equatable, Sendable {
    public let rawValue: String
    public init?(rawValue: String) {
        let bytes = Array(rawValue.utf8)
        guard (1...80).contains(bytes.count), let first = bytes.first,
              (65...90).contains(first) || (97...122).contains(first),
              bytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }) else { return nil }
        self.rawValue = rawValue
    }
}
