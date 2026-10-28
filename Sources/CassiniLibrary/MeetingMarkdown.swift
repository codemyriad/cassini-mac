// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Binding S-5 export. This consumes derived labels, never naming provenance or
/// voiceprints. Dates are absolute and never use the Library's Today/Yesterday.
public enum MeetingMarkdown {
    public static func render(_ meeting: LibraryMeeting, timeZone: TimeZone) -> String {
        render(title:meeting.title ?? "Untitled meeting",start:meeting.start,durationMs:meeting.durationMs,
            timeZone:timeZone,names:Dictionary(uniqueKeysWithValues:meeting.speakers.map { ($0.id,$0.displayName) }),
            items:meeting.state.transcript == .done ? meeting.transcriptItems : [],notes:meeting.notes)
    }
    public static func render(title: String, start: Date?, durationMs: Int64?, timeZone: TimeZone,
                              names: [String:String], items: [LibraryTranscriptItem], notes: [MeetingNote]) -> String {
        var blocks = ["# " + escape(title)]
        if let start {
            let date = DateFormatter(); date.locale = Locale(identifier:"en_GB")
            date.calendar = Calendar(identifier:.gregorian); date.timeZone = timeZone
            date.dateFormat = "EEEE d MMMM yyyy, HH:mm"
            blocks.append(date.string(from:start) + (durationMs.map { " · " + LibraryFormat.meetingDuration($0) } ?? ""))
        }
        let ordered = items.enumerated().sorted {
            $0.element.startMs == $1.element.startMs ? $0.offset < $1.offset : $0.element.startMs < $1.element.startMs
        }.map(\.element)
        let turns = LibraryTranscriptTurn.coalescing(ordered)
        var speaking: [String] = []
        for turn in turns where !speaking.contains(turn.speaker) { speaking.append(turn.speaker) }
        if !speaking.isEmpty { blocks.append("Speakers: " + speaking.map { escape(names[$0] ?? $0) }.joined(separator:", ")) }
        blocks.append("## Transcript")
        for turn in turns {
            blocks.append("**" + escape(names[turn.speaker] ?? turn.speaker) + "** · " + LibraryFormat.position(turn.startMs) + "\n" + escape(turn.text))
        }
        if !notes.isEmpty {
            blocks.append("## Notes")
            let sorted = notes.enumerated().sorted { $0.element.atMs == $1.element.atMs ? $0.offset < $1.offset : $0.element.atMs < $1.element.atMs }.map(\.element)
            blocks.append(sorted.map { "- " + LibraryFormat.position($0.atMs) + " " + escape($0.text) }.joined(separator:"\n"))
        }
        return blocks.joined(separator:"\n\n") + "\n"
    }
    public static func escape(_ value: String) -> String {
        let normalized = value.split(whereSeparator:\.isWhitespace).joined(separator:" ")
        var result = ""
        for scalar in normalized.unicodeScalars {
            if "\\`*_[]<>".unicodeScalars.contains(scalar) { result += "\\" }
            result.unicodeScalars.append(scalar)
        }
        if let first = result.first, "#-+".contains(first) { result = "\\" + result }
        else if let dot = result.firstIndex(of:"."), dot != result.startIndex,
                result[..<dot].allSatisfy({ $0 >= "0" && $0 <= "9" }) { result.insert("\\",at:dot) }
        return result
    }
    public static func filename(title: String, extension suffix: String = "md", collision: Int = 1) -> String {
        let replaced = title.unicodeScalars.map { scalar in
            scalar == "/" || scalar == "\\" || CharacterSet.controlCharacters.contains(scalar) ? "-" : String(scalar)
        }.joined().trimmingCharacters(in:.whitespacesAndNewlines)
        let stem = replaced.isEmpty ? "Untitled meeting" : String(replaced.prefix(120))
        return stem + (collision > 1 ? " \(collision)" : "") + "." + suffix
    }
}
