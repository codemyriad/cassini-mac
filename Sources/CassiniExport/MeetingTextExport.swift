// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniLibrary

/// L-11 plain text and subtitle exports. Canonical words are kept once, including
/// overlaps and zero-duration items. Cue ordering uses playback start, stably.
public enum MeetingTextExport {
    private struct Segment {
        var speaker: String
        var start: Int64
        var end: Int64
        var words: [String]
        var length: Int
    }
    public static func render(_ meeting: LibraryMeeting, kind: MeetingExportKind) throws -> String {
        guard meeting.state.transcript == .done, [.plainText, .srt, .vtt].contains(kind) else {
            throw MeetingExportError.invalidSource
        }
        let names = meeting.speakerDisplayNames.mapValues { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        var fallback: [String: String] = [:]
        var segments: [Segment] = []
        for word in meeting.transcriptItems {
            if names[word.speaker] == nil && fallback[word.speaker] == nil {
                fallback[word.speaker] = LibraryLocalization.shared.text("common.speaker.unnamed", ["n": String(fallback.count + names.count + 1)])
            }
            let text = word.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty else { continue }
            let start = max(0, word.startMs), end = max(start, word.endMs)
            let name = names[word.speaker] ?? fallback[word.speaker]!
            let index = segments.count - 1
            if index >= 0, segments[index].speaker == word.speaker,
               kind == .plainText || (max(segments[index].end, end) - min(segments[index].start, start) <= 7000 && segments[index].length + text.count + 1 <= 84) {
                segments[index].start = min(segments[index].start, start)
                segments[index].end = max(segments[index].end, end)
                segments[index].words.append(text)
                segments[index].length += text.count + 1
            } else {
                segments.append(.init(speaker: word.speaker, start: start, end: end, words: [text], length: name.count + 2 + text.count))
            }
        }
        let ordered = segments.enumerated().sorted { $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start }.map(\.element)
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var blocks: [String] = []
        for (index, segment) in ordered.enumerated() {
            let name = names[segment.speaker] ?? fallback[segment.speaker]!
            let words = segment.words.joined(separator: " ")
            if kind == .plainText {
                blocks.append("\(name) · \(clock(segment.start))\n\(words)")
            } else {
                let caption = wrap(kind == .srt ? "\(name): \(words)" : words)
                let cue = kind == .srt ? caption : "<v \(escaped(name))>\(escaped(caption))</v>"
                let delimiter = kind == .srt ? "," : "."
                let times = "\(clock(segment.start, delimiter: delimiter)) --> \(clock(max(segment.start + 1, min(segment.end, segment.start + 7000)), delimiter: delimiter))"
                blocks.append((kind == .srt ? "\(index + 1)\n" : "") + times + "\n" + cue)
            }
        }
        return (kind == .vtt ? "WEBVTT\n\n" : "") + blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n")
    }
    private static func wrap(_ text: String) -> String {
        guard text.count > 42 else { return text }
        let words = text.split(separator: " ")
        var first: [Substring] = [], second: [Substring] = []
        var length = 0
        for word in words {
            if second.isEmpty && (first.isEmpty || length + 1 + word.count <= 42) {
                first.append(word); length += word.count + (first.count > 1 ? 1 : 0)
            } else { second.append(word) }
        }
        return first.joined(separator: " ") + (second.isEmpty ? "" : "\n" + second.joined(separator: " "))
    }
    private static func clock(_ ms: Int64, delimiter: String? = nil) -> String {
        let seconds = ms / 1000
        let base = String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
        return delimiter.map { base + $0 + String(format: "%03lld", ms % 1000) } ?? base
    }
}
