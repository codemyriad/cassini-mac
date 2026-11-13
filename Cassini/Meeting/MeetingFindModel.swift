// SPDX-License-Identifier: GPL-3.0-or-later
import CassiniLibrary
import Foundation
import Observation

@MainActor @Observable final class MeetingFindModel {
    var query = ""
    private(set) var matches: [TranscriptFind.Match] = []
    private(set) var selected: TranscriptFind.Match?
    private(set) var focusRequest = 0
    @ObservationIgnored private var revision = 0

    func requestFocus() { focusRequest &+= 1 }
    func step(_ direction: TranscriptFind.Direction) {
        selected = TranscriptFind.adjacent(to: selected, direction: direction, in: matches)
    }
    var status: String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let values = ["query": query, "index": ((selected.flatMap { matches.firstIndex(of: $0) } ?? 0) + 1).formatted(.number.locale(UXText.locale)),
                      "count": matches.count.formatted(.number.locale(UXText.locale))]
        return UXText.text(matches.isEmpty ? "mac.legacy.match.none" : matches.count == 1 ? "mac.legacy.match.one" : "mac.legacy.match.position", values)
    }
    func search(_ paragraphs: [TranscriptFind.Paragraph], locale: Locale) async {
        revision &+= 1
        let requestedRevision = revision
        let requestedQuery = query
        let previous = selected
        matches = []; selected = nil
        let task = Task.detached { try TranscriptFind.matches(in: paragraphs, query: requestedQuery, locale: locale) }
        do {
            let found = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            guard !Task.isCancelled, requestedRevision == revision, requestedQuery == query else { return }
            matches = found
            selected = previous.flatMap { found.contains($0) ? $0 : nil } ?? found.first
        } catch is CancellationError { }
        catch { assertionFailure("Unexpected transcript find failure: \(error)") }
    }
}
