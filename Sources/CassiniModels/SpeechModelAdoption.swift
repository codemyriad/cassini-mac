// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D78: first verification adopts the recommended model. A later explicit choice
/// survives inventory refresh and relaunch until that installation goes away.
public struct SpeechModelAdoption: Sendable, Equatable {
    public enum Choice: String, Sendable { case whistle, parakeet }
    public private(set) var choice: Choice
    public private(set) var adoptedRevision: String?
    public private(set) var verifiedRevision: String?
    public private(set) var announcedRevision: String?
    public private(set) var pendingAnnouncementRevision: String?
    public var canAnnounce: Bool { choice == .parakeet && verifiedRevision != nil && pendingAnnouncementRevision == verifiedRevision && announcedRevision != verifiedRevision }
    public init(choice: Choice = .whistle, adoptedRevision: String? = nil,
                announcedRevision: String? = nil, pendingAnnouncementRevision: String? = nil) {
        self.choice = choice; self.adoptedRevision = adoptedRevision
        self.announcedRevision = announcedRevision; self.pendingAnnouncementRevision = pendingAnnouncementRevision
    }
    public mutating func verified(_ revision: String) {
        verifiedRevision = revision
        if adoptedRevision != revision {
            pendingAnnouncementRevision = choice != .parakeet && announcedRevision != revision ? revision : nil
            choice = .parakeet; adoptedRevision = revision
        }
    }
    public mutating func choose(_ value: Choice) {
        guard value == .whistle || verifiedRevision != nil else { return }
        choice = value
        if value == .whistle { pendingAnnouncementRevision = nil }
    }
    public mutating func unavailable() {
        choice = .whistle; adoptedRevision = nil; verifiedRevision = nil; pendingAnnouncementRevision = nil
    }
    public mutating func takeAnnouncement() -> Bool {
        guard canAnnounce else { return false }
        announcedRevision = verifiedRevision; pendingAnnouncementRevision = nil; return true
    }
}

/// A single persistent dismissal applies to both quiet recommendation surfaces.
public struct SpeechModelSuggestion: Sendable, Equatable {
    public private(set) var completedWhistle: Bool
    public private(set) var dismissed: Bool
    public private(set) var afterFirstShown: Bool
    public init(completedWhistle: Bool = false, dismissed: Bool = false, afterFirstShown: Bool = false) {
        self.completedWhistle = completedWhistle; self.dismissed = dismissed; self.afterFirstShown = afterFirstShown
    }
    public mutating func transcriptionFinished(engine: String, succeeded: Bool) {
        if engine == "whistle", succeeded { completedWhistle = true }
    }
    public mutating func dismiss() { dismissed = true }
    public mutating func takeAfterFirst() -> Bool {
        guard completedWhistle, !dismissed, !afterFirstShown else { return false }
        afterFirstShown = true; return true
    }
    public func show(capable: Bool, enoughDisk: Bool, installed: Bool, busy: Bool, afterFirst: Bool) -> Bool {
        capable && enoughDisk && !installed && !busy && !dismissed && (!afterFirst || completedWhistle && !afterFirstShown)
    }
}

/// D78's Mac suggestion threshold and the existing model downloader disk reserve.
public struct ParakeetSuggestionEligibility: Sendable {
    public static let minimumPhysicalMemory: UInt64 = 8 << 30
    public let capable: Bool
    public let enoughDisk: Bool
    public init(physicalMemory: UInt64, architectureSupported: Bool, runtimeAvailable: Bool,
                disk: ModelDiskSpace?, requiredStorage: UInt64) {
        capable = physicalMemory >= Self.minimumPhysicalMemory && architectureSupported && runtimeAvailable
        enoughDisk = disk.map { (try? $0.check(required:requiredStorage)) != nil } ?? false
    }
}
