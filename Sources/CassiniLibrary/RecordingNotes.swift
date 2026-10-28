// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

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
    public enum Restoration { case undo, redo }
    private struct Stamp: Equatable { let atMs: Int64?; let prefixCount: Int }
    private struct Snapshot { let digest: Data; let stamps: [Stamp] }
    // Only hashes and timestamp maps are retained, not copies of the note text.
    // Equal maps share array storage across ordinary character edits.
    private var history: [Snapshot] = []
    private var historyPosition = -1
    public init(lines: [Line], displayed: String) {
        self.lines = lines; self.displayed = displayed.components(separatedBy:"\n")
        if lines.isEmpty { self.lines = [.init(atMs:nil,text:"")] }
        remember(displayed)
    }
    public mutating func reformat(_ text: String) { displayed = text.components(separatedBy:"\n"); remember(text) }
    public mutating func edit(_ text: String, atMs: Int64, restoration: Restoration? = nil, prefix: (Int64) -> String) {
        let next = text.components(separatedBy:"\n")
        if let restoration {
            let digest = Data(SHA256.hash(data:Data(text.utf8)))
            let indices = restoration == .undo ? Array((0..<max(0,historyPosition)).reversed()) : Array((historyPosition + 1)..<history.count)
            if let index = indices.first(where:{ history[$0].digest == digest && history[$0].stamps.count == next.count }) {
                lines = zip(next,history[index].stamps).map { Line(atMs:$1.atMs,text:String($0.dropFirst($1.prefixCount))) }
                displayed = next; historyPosition = index; return
            }
        }
        var first = 0, suffix = 0
        while first < min(displayed.count,next.count), displayed[first] == next[first] { first += 1 }
        while suffix < min(displayed.count,next.count) - first,
              displayed[displayed.count - suffix - 1] == next[next.count - suffix - 1] { suffix += 1 }
        let old = lines
        // Recognise prefixes belonging to rendered old notes before assigning
        // line identities. An inserted line must not steal the edited note's
        // timestamp merely because it occupies that note's previous index.
        var rendered: [Int:(stamp:String,clock:String)] = [:], prefixSources: [String:[Int]] = [:]
        for index in old.indices where displayed.indices.contains(index) {
            let count = historyPosition >= 0 && history[historyPosition].stamps.indices.contains(index) ? history[historyPosition].stamps[index].prefixCount : 0
            let stamp = count > 0 ? String(displayed[index].prefix(count)) : (old[index].atMs.map(prefix) ?? "")
            let clock = stamp.trimmingCharacters(in:.whitespaces)
            guard !clock.isEmpty, displayed[index].hasPrefix(clock), displayed[index] != old[index].text else { continue }
            rendered[index] = (stamp,clock); prefixSources[clock,default:[]].append(index)
        }
        func candidates(_ line: String) -> [Int] { prefixSources[String(line.prefix(while:{ !$0.isWhitespace }))] ?? [] }
        func stripped(_ line: String, oldIndex: Int) -> String? {
            guard let render = rendered[oldIndex] else { return nil }
            if line.hasPrefix(render.stamp) { return String(line.dropFirst(render.stamp.count)) }
            guard line.hasPrefix(render.clock) else { return nil }
            let rest = line.dropFirst(render.clock.count)
            guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
            return String(rest.drop(while:\.isWhitespace))
        }
        let bodies = next.map { line in candidates(line).compactMap { stripped(line,oldIndex:$0) }.first ?? line }
        let bodySources = Dictionary(grouping:old.indices,by:{ old[$0].text })
        var matches: [Int:Int] = [:], used = Set<Int>()
        func assign(_ index: Int, _ previous: Int) { matches[index] = previous; used.insert(previous) }
        for index in next.indices {
            if index < first, old.indices.contains(index) { assign(index,index) }
            else if index >= next.count - suffix {
                let previous = old.count - (next.count - index)
                if old.indices.contains(previous) { assign(index,previous) }
            }
        }
        for index in next.indices where matches[index] == nil && !bodies[index].trimmingCharacters(in:.whitespaces).isEmpty {
            if let previous = candidates(next[index]).first(where:{ !used.contains($0) && stripped(next[index],oldIndex:$0) != nil }) { assign(index,previous) }
        }
        for index in next.indices where matches[index] == nil && !bodies[index].isEmpty {
            if let previous = bodySources[bodies[index]]?.first(where:{ !used.contains($0) }) { assign(index,previous) }
        }
        lines = next.enumerated().map { index,line in
            let oldIndex: Int?
            if let matched = matches[index] { oldIndex = matched }
            else if index - first < old.count - first - suffix && !used.contains(index) { oldIndex = index }
            else { oldIndex = nil }
            let previous = oldIndex.flatMap { old.indices.contains($0) ? old[$0] : nil }
            let body = bodies[index]
            let empty = body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
            return Line(atMs:empty ? nil : previous?.atMs ?? max(0,atMs),text:body)
        }
        displayed = next
        remember(text)
    }
    private mutating func remember(_ text: String) {
        var stamps = zip(displayed,lines).map { raw,line in
            Stamp(atMs:line.atMs,prefixCount:raw.hasSuffix(line.text) ? raw.count - line.text.count : 0)
        }
        if historyPosition >= 0, history[historyPosition].stamps == stamps { stamps = history[historyPosition].stamps }
        let digest = Data(SHA256.hash(data:Data(text.utf8)))
        if historyPosition >= 0, history[historyPosition].digest == digest, history[historyPosition].stamps == stamps { return }
        history.removeSubrange((historyPosition + 1)..<history.count)
        history.append(.init(digest:digest,stamps:stamps)); historyPosition = history.count - 1
    }
}
