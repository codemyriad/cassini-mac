// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D15.1 durable intent. Pending includes busy folders and work interrupted by
/// Quit; failed folders are touched only by an explicit failed-meeting retry.
public struct LibraryPendingMove: Codable, Sendable, Equatable, Identifiable {
    public enum Phase: String, Codable, Sendable { case pending, failed }
    public var sourcePath: String
    public let folderName: String
    public var phase: Phase
    public var id: String { sourcePath + "/" + folderName }
    public init(source: URL, folderName: String, phase: Phase = .pending) {
        sourcePath = source.path; self.folderName = folderName; self.phase = phase
    }
    public var valid: Bool { LibraryScanner.identity(folderName) != nil }
}
