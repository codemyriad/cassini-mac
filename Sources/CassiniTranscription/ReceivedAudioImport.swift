// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniLibrary

/// Compatibility entry point; Open and Write it down use the same R1.4 importer.
public enum ReceivedAudioImport {
    public static func copy(_ source: URL, into root: URL) throws -> LibraryMeeting {
        try LibraryImport.copy(source,into:root)
    }
}
