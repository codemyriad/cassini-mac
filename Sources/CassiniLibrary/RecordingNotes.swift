// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Editing lines preserves their original capture time. Blank lines acquire a
/// timestamp only when their first non-whitespace character is typed.
public struct RecordingNotes: Sendable {
    public struct Line: Equatable, Sendable {
        public var atMs: Int64?
        public var text: String
        public init(atMs: Int64?, text: String) { self.atMs = atMs; self.text = text }
    }
    public private(set) var lines: [Line]
    private var displayed: [String]
    public init(lines: [Line], displayed: String) {
        self.lines = lines; self.displayed = displayed.components(separatedBy:"\n")
        if lines.isEmpty { self.lines = [.init(atMs:nil,text:"")] }
    }
    public mutating func reformat(_ text: String) { displayed = text.components(separatedBy:"\n") }
    public mutating func edit(_ text: String, atMs: Int64, prefix: (Int64) -> String) {
        let next = text.components(separatedBy:"\n")
        var first = 0, suffix = 0
        while first < min(displayed.count,next.count), displayed[first] == next[first] { first += 1 }
        while suffix < min(displayed.count,next.count) - first,
              displayed[displayed.count - suffix - 1] == next[next.count - suffix - 1] { suffix += 1 }
        let old = lines
        lines = next.enumerated().map { index,line in
            let oldIndex: Int?
            if index < first { oldIndex = index }
            else if index >= next.count - suffix { oldIndex = old.count - (next.count - index) }
            else if index - first < old.count - first - suffix { oldIndex = index }
            else { oldIndex = nil }
            let previous = oldIndex.flatMap { old.indices.contains($0) ? old[$0] : nil }
            let stamp = previous?.atMs.map(prefix)
            let body = stamp.flatMap { stamp -> String? in
                if line.hasPrefix(stamp) { return String(line.dropFirst(stamp.count)) }
                let time = stamp.trimmingCharacters(in:.whitespaces)
                guard line.hasPrefix(time) else { return nil }
                let remainder = line.dropFirst(time.count)
                guard remainder.isEmpty || remainder.first?.isWhitespace == true else { return nil }
                return String(remainder.drop(while:\.isWhitespace))
            } ?? line
            let empty = body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
            return Line(atMs:empty ? nil : previous?.atMs ?? max(0,atMs),text:body)
        }
        displayed = next
    }
}
