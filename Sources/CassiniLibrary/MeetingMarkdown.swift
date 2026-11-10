// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Binding S-5 export. This consumes derived labels, never naming provenance or
/// voiceprints. Dates are absolute and never use the Library's Today/Yesterday.
public enum MeetingMarkdown {
    public static func render(_ meeting: LibraryMeeting, timeZone: TimeZone, locale: Locale = .current, language: CassiniLanguage = .system) -> String {
        render(title:meeting.title ?? LibraryLocalization.shared.text("library.untitled",language:language,locale:locale),start:meeting.start,durationMs:meeting.durationMs,
            timeZone:timeZone,names:Dictionary(uniqueKeysWithValues:meeting.speakers.map { ($0.id,$0.displayName) }),
            items:meeting.state.transcript == .done ? meeting.transcriptItems : [],notes:meeting.notes,gaps:meeting.speakerGaps,endsBoundedByAudio:meeting.wordEndsBoundedByAudio,locale:locale,language:language)
    }
    public static func render(title: String, start: Date?, durationMs: Int64?, timeZone: TimeZone,
                              names: [String:String], items: [LibraryTranscriptItem], notes: [MeetingNote], gaps: SpeakerGapRanges.Ranges = [:], endsBoundedByAudio: Bool = false,
                              locale: Locale = .current, language: CassiniLanguage = .system) -> String {
        let strings=LibraryLocalization.shared
        let title=title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? strings.text("library.untitled",language:language,locale:locale) : title
        var blocks = ["# " + escape(title)]
        // D50.3: words follow the document language; the clock follows `locale`.
        if let start { blocks.append(LibraryFormat(timeZone:timeZone,locale:locale,language:language).absoluteDateLine(start,durationMs:durationMs)) }
        let ordered = items // Group canonical words before sorting display blocks, as the viewer does.
        let all = MeetingPresentation.turns(ordered,gaps:gaps,endsBoundedByAudio:endsBoundedByAudio)
        let turns = MeetingPresentation.visibleTurns(all)
        var speaking: [String] = []
        for word in ordered.enumerated().sorted(by:{ $0.element.startMs == $1.element.startMs ? $0.offset < $1.offset : $0.element.startMs < $1.element.startMs }).map(\.element) where !speaking.contains(word.speaker) { speaking.append(word.speaker) }
        if !speaking.isEmpty { blocks.append(strings.text("export.markdown.speakersLine",["names":speaking.map { escape(names[$0] ?? $0) }.joined(separator:", ")],language:language,locale:locale)) }
        blocks.append("## "+strings.text("export.markdown.transcriptHeading",language:language,locale:locale))
        for turn in turns {
            let others = turn.over.map { names[$0] ?? $0 }
            let over = others.isEmpty ? "" : " " + strings.text("meeting.turn.over",["names":LibraryFormat(locale:locale,language:language).list(others)],language:language,locale:locale)
            blocks.append("**" + escape(names[turn.speaker] ?? turn.speaker) + "** · " + LibraryFormat.position(turn.startMs,locale:locale,language:language) + escape(over) + "\n" + escape(MeetingPresentation.prose(turn,in:all,names:names).text))
        }
        if !notes.isEmpty {
            blocks.append("## "+strings.text("export.markdown.notesHeading",language:language,locale:locale))
            let sorted = notes.enumerated().sorted { $0.element.atMs == $1.element.atMs ? $0.offset < $1.offset : $0.element.atMs < $1.element.atMs }.map(\.element)
            blocks.append(sorted.map { "- " + LibraryFormat.position($0.atMs,locale:locale,language:language) + " " + escape($0.text) }.joined(separator:"\n"))
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
    public static func filename(title: String, extension suffix: String = "md", collision: Int = 1, language: CassiniLanguage = .system, locale: Locale = .current) -> String {
        let replaced = title.unicodeScalars.map { scalar in
            scalar == "/" || scalar == "\\" || CharacterSet.controlCharacters.contains(scalar) ? "-" : String(scalar)
        }.joined().trimmingCharacters(in:.whitespacesAndNewlines)
        let stem = replaced.isEmpty ? LibraryLocalization.shared.text("library.untitled",language:language,locale:locale) : String(replaced.prefix(120))
        return stem + (collision > 1 ? " \(collision)" : "") + "." + suffix
    }
}
