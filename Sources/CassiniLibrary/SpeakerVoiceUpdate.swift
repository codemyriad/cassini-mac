// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A missing preparation is never a request to forget a contribution.
public struct SpeakerVoiceChoice: Sendable {
    public private(set) var remember: Bool
    public private(set) var explicitlyDisabled = false
    public private(set) var userChanged = false
    public init(existing: Bool, enabled: Bool = false) { remember = existing || enabled }
    public mutating func choose(_ value: Bool) { remember=value; explicitlyDisabled = !value; userChanged=true }
    public enum Update: Sendable { case preserve, forget, enroll }
    public func update(prepared:Bool) -> Update {
        if explicitlyDisabled { return .forget }
        return remember && prepared ? .enroll : .preserve
    }
}

/// Library edits are the primary commit. Voice failures must never make them retryable.
public enum SpeakerEditTransaction {
    @MainActor public static func run<T>(
        library: () async throws -> T,
        committed: (T) -> Void,
        readOnly: () async throws -> Bool,
        voices: () async throws -> Void
    ) async throws -> Bool {
        let updated = try await library()
        committed(updated)
        do {
            guard try await !readOnly() else { return false }
            try await voices()
            return false
        } catch { return true }
    }
}
