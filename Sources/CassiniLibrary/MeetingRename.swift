// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum MeetingRename {
    /// A blank editor removes the user override. The scanner derives the
    /// automatic display name; no localised fallback is ever written to metadata.
    public static func normalized(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
        let limited = String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(500))).trimmingCharacters(in:.whitespacesAndNewlines)
        return limited.isEmpty ? nil : limited
    }
    public static func apply(_ name: String, to meeting: LibraryMeeting) throws {
        guard meeting.state.lifecycle == .saved, !meeting.metadataReadOnly else { throw POSIXError(.EPERM) }
        let title = normalized(name)
        if let title, title == meeting.title { return }
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction {
            $0["title"] = title.map { $0 as Any } ?? NSNull()
            $0["titleSource"] = title == nil ? "meeting-window" : "user"
        }
    }
}
