import Foundation

public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case plainText, markdown, webVTT, srt

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .plainText: return "Plain Text"
        case .markdown: return "Markdown"
        case .webVTT: return "WebVTT Subtitles"
        case .srt: return "SRT Subtitles"
        }
    }

    public var fileExtension: String {
        switch self {
        case .plainText: return "txt"
        case .markdown: return "md"
        case .webVTT: return "vtt"
        case .srt: return "srt"
        }
    }
}

/// `m:ss`, or `h:mm:ss` from an hour.
public func formatClock(_ ms: Int) -> String {
    let s = max(0, ms / 1000)
    let h = s / 3600, m = (s % 3600) / 60, ss = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss) : String(format: "%d:%02d", m, ss)
}

public enum TranscriptExporter {
    /// Subtitle cues are cut at this many words or this long, whichever comes first.
    static let cueMaxWords = 14
    static let cueMaxMs = 6000

    public static func export(_ format: ExportFormat, title: String, timeline: Timeline, speakers: [Speaker]) -> String {
        let label: (String) -> String = { id in speakers.first { $0.id == id }?.label ?? "Unknown speaker" }
        let turns = timeline.turns
        func text(_ idx: [Int]) -> String { idx.map { timeline.words[$0].text }.joined(separator: " ") }

        switch format {
        case .plainText:
            return turns.map { t in
                "\(label(t.speaker)) [\(formatClock(t.startMs))]\n\(textWithInterjections(t, timeline, label))"
            }.joined(separator: "\n\n") + "\n"
        case .markdown:
            let body = turns.map { t in
                "**\(label(t.speaker))** `\(formatClock(t.startMs))`\n\n\(textWithInterjections(t, timeline, label))"
            }
            return "# \(title)\n\n" + body.joined(separator: "\n\n") + "\n"
        case .webVTT, .srt:
            var cues: [(start: Int, end: Int, speaker: String, body: String)] = []
            // Interjections become their own cues, so cue times stay true.
            var groups: [(speaker: String, words: [Int])] = []
            for t in turns {
                groups.append((t.speaker, t.words))
                for j in t.interjections { groups.append((j.speaker, j.words)) }
            }
            for g in groups {
                var cur: [Int] = []
                func flush() {
                    guard let f = cur.first else { return }
                    let end = cur.map { timeline.words[$0].endMs }.max() ?? timeline.words[f].endMs
                    cues.append((timeline.words[f].startMs, max(end, timeline.words[f].startMs + 1), g.speaker, text(cur)))
                    cur = []
                }
                for i in g.words {
                    if let f = cur.first, cur.count >= cueMaxWords || timeline.words[i].endMs - timeline.words[f].startMs > cueMaxMs {
                        flush()
                    }
                    cur.append(i)
                }
                flush()
            }
            cues.sort { $0.start < $1.start }
            if format == .webVTT {
                return "WEBVTT\n\n" + cues.map { "\(vttTime($0.start)) --> \(vttTime($0.end))\n<v \(label($0.speaker))>\($0.body)" }
                    .joined(separator: "\n\n") + "\n"
            }
            return cues.enumerated().map { n, c in "\(n + 1)\n\(srtTime(c.start)) --> \(srtTime(c.end))\n\(label(c.speaker)): \(c.body)" }
                .joined(separator: "\n\n") + "\n"
        }
    }

    static func textWithInterjections(_ t: Turn, _ timeline: Timeline, _ label: (String) -> String) -> String {
        var parts: [String] = []
        for j in t.interjections where j.anchor < 0 {
            parts.append("[\(label(j.speaker)): \(j.words.map { timeline.words[$0].text }.joined(separator: " "))]")
        }
        for (k, i) in t.words.enumerated() {
            parts.append(timeline.words[i].text)
            for j in t.interjections where j.anchor == k {
                parts.append("[\(label(j.speaker)): \(j.words.map { timeline.words[$0].text }.joined(separator: " "))]")
            }
        }
        return parts.joined(separator: " ")
    }

    static func vttTime(_ ms: Int) -> String {
        String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    static func srtTime(_ ms: Int) -> String {
        String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
