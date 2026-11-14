// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniLibrary

public enum MeetingExportKind: String, Sendable, CaseIterable {
    case cassini, markdown, plainText, srt, vtt, originalAudio

    public var catalogName: String { self == .cassini ? "cassiniFile" : rawValue }
    public func suffix(for meeting: LibraryMeeting) -> String {
        switch self {
        case .cassini: "opus"
        case .markdown: "md"
        case .plainText: "txt"
        case .srt: "srt"
        case .vtt: "vtt"
        case .originalAudio: meeting.audioFiles.first?.pathExtension ?? "opus"
        }
    }
    public static func primary(for meeting: LibraryMeeting) -> [Self] {
        let audio: Self = meeting.state.origin == .received && !meeting.hasCassiniFile && meeting.state.transcript != .done ? .originalAudio : .cassini
        return meeting.state.transcript == .done ? [audio, .markdown] : [audio]
    }
    public static func more(for meeting: LibraryMeeting) -> [Self] {
        meeting.state.transcript == .done ? [.plainText, .srt, .vtt] : []
    }
}
