// SPDX-License-Identifier: GPL-3.0-or-later
import CassiniLibrary
import Foundation
import Observation

@MainActor @Observable final class MeetingFindModel {
    var query = ""
    var focused = false
    private(set) var matches: [TranscriptFind.Match] = []
    private(set) var selected: TranscriptFind.Match?
    private(set) var ranges: [Int:[NSRange]] = [:]
    private(set) var selectedIndex: Int?
    private(set) var focusRequest = 0
    private(set) var searching = false
    @ObservationIgnored private var revision = 0

    func requestFocus() { focusRequest &+= 1 }
    func step(_ direction: TranscriptFind.Direction) {
        selected = TranscriptFind.adjacent(to: selected, direction: direction, in: matches)
        selectedIndex = selected.flatMap { matches.firstIndex(of: $0) }
    }
    var status: String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let values = ["query": query.trimmingCharacters(in: .whitespacesAndNewlines), "index": ((selectedIndex ?? 0) + 1).formatted(.number.locale(UXText.locale)),
                      "count": matches.count.formatted(.number.locale(UXText.locale))]
        return UXText.text(matches.isEmpty ? "mac.legacy.match.none" : matches.count == 1 ? "mac.legacy.match.one" : "mac.legacy.match.position", values)
    }
    func search(turns: [MeetingPresentation.Turn], names: [String:String], language: CassiniLanguage, locale: Locale) async {
        revision &+= 1
        let requestedRevision = revision
        let requestedQuery = query
        let previous = selected
        matches = []; selected = nil; ranges = [:]; selectedIndex = nil; searching = true
        defer { if requestedRevision == revision { searching = false } }
        guard !requestedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let task = Task.detached {
            var paragraphs: [TranscriptFind.Paragraph] = []
            for turn in MeetingPresentation.visibleTurns(turns) {
                try Task.checkCancellation()
                paragraphs.append(.init(id: turn.id, text: MeetingPresentation.prose(turn, in: turns, names: names, locale: locale, language: language).text))
            }
            let found = try TranscriptFind.matches(in: paragraphs, query: requestedQuery, locale: locale)
            try Task.checkCancellation()
            return (matches: found, ranges: Dictionary(grouping: found, by: \.paragraph).mapValues { $0.map(\.range) })
        }
        do {
            let found = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            guard !Task.isCancelled, requestedRevision == revision, requestedQuery == query else { return }
            matches = found.matches; ranges = found.ranges
            selected = previous.flatMap { found.matches.contains($0) ? $0 : nil } ?? found.matches.first
            selectedIndex = selected.flatMap { found.matches.firstIndex(of: $0) }
        } catch is CancellationError { }
        catch { assertionFailure("Unexpected transcript find failure: \(error)") }
    }
}
