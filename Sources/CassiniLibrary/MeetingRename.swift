// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum MeetingRename {
    /// An explicit blank name is an explicit user choice of the shared untitled
    /// label. Keeping a nonempty title preserves v1 reader/schema compatibility
    /// and prevents the captured title or received filename from reappearing.
    public static func normalized(_ name: String, untitled: String) -> String {
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
        let limited = String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(500))).trimmingCharacters(in:.whitespacesAndNewlines)
        return limited.isEmpty ? untitled : limited
    }
    @discardableResult public static func apply(_ name: String, to meeting: LibraryMeeting, untitled: String) throws -> String {
        guard meeting.state.lifecycle == .saved, !meeting.metadataReadOnly else { throw POSIXError(.EPERM) }
        let title = normalized(name,untitled:untitled)
        guard !title.isEmpty, title.unicodeScalars.count <= 500 else { throw POSIXError(.EINVAL) }
        guard title != meeting.title else { return title }
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction {
            $0["title"] = title; $0["titleSource"] = "user"
        }
        return title
    }
}
