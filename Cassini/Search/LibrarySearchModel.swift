// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Observation
import CassiniLibrary
import CassiniSearch

@MainActor @Observable final class LibrarySearchModel {
    static let shared = LibrarySearchModel()
    var visible = false
    var query = ""
    var speaker: String?
    var date = SearchDate.any
    var own = false
    var selectedID: String?
    private(set) var hits: [SearchHit] = []
    private(set) var meetings: [LibraryMeeting] = []
    private(set) var focusRequest = 0
    private(set) var searching = false
    @ObservationIgnored private var task: Task<Void,Never>?
    @ObservationIgnored private var indexTask: Task<SearchIndex,Error>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var fixtureSelectionDone = false
    @ObservationIgnored private let makeIndex: @Sendable (URL) throws -> SearchIndex
    @ObservationIgnored private let reportFailure: @MainActor (Error) -> Void
    @ObservationIgnored private var errorShown = false
    init(makeIndex: @escaping @Sendable (URL) throws -> SearchIndex = { try SearchIndex(cache:$0) },
         reportFailure: @escaping @MainActor (Error) -> Void = { NSApp.presentError($0) }) {
        self.makeIndex = makeIndex; self.reportFailure = reportFailure
    }
    var selected: SearchHit? { hits.first { $0.id == selectedID } }
    var names: [String] { SearchIndex.names(meetings) }
    var count: String { LibraryFormat.searchCount(places:Int64(hits.count),meetings:Int64(Set(hits.map(\.meetingKey)).count)) }
    func meeting(_ hit: SearchHit) -> LibraryMeeting? { meetings.first { $0.libraryKey == hit.meetingKey } }
    func open() {
        MeetingNavigation.shared.back(); visible = true; focusRequest &+= 1
        MeetingNavigation.shared.openLibrary?(); update(LibraryStore.shared.meetings)
    }
    func close() {
        task?.cancel(); generation &+= 1; visible = false; query = ""; speaker = nil; date = .any; own = false
        selectedID = nil; hits = []; searching = false
    }
    func update(_ meetings: [LibraryMeeting]) { self.meetings = meetings; refresh() }
    func refresh() {
        task?.cancel(); generation &+= 1
        guard visible else { return }
        let revision = generation, snapshot = meetings, query = query, filter = SearchFilter(speaker:speaker,date:date,own:own)
        let context = LibraryStore.shared.context, now = context.now ?? Date(), zone = context.timeZone
        if indexTask == nil {
            let cache = context.screenshot ? FileManager.default.temporaryDirectory.appendingPathComponent("CassiniSearchFixture-\(ProcessInfo.processInfo.processIdentifier)") :
                FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("MeetingSearch-v1")
            let create = makeIndex
            indexTask = Task.detached { try create(cache) }
        }
        let ready = indexTask!
        searching = true
        task = Task {
            do {
                try await Task.sleep(for:.milliseconds(120))
                let index = try await ready.value
                try Task.checkCancellation(); try await index.replace(snapshot)
                try Task.checkCancellation()
                let results = try await index.search(query,filter:filter,now:now,timeZone:zone)
                guard !Task.isCancelled, revision == generation else { return }
                hits = results
                if selectedID == nil || !results.contains(where:{ $0.id == selectedID }) { selectedID = results.first?.id }
                #if DEBUG
                if context.screenshot, LibraryLaunchContext.argument("-CassiniScreenshot") == "search", !fixtureSelectionDone {
                    selectedID = results.first(where:{ $0.positionMs == 872000 })?.id ?? selectedID; fixtureSelectionDone = true
                }
                #endif
                searching = false; errorShown = false
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, revision == generation else { return }
                indexTask = nil // A failed initialization must not poison later queries.
                hits = []; selectedID = nil; searching = false
                if !errorShown { errorShown = true; reportFailure(error) }
            }
        }
    }
    func openSelected(play: Bool) {
        guard !searching, let hit = selected, let meeting = meeting(hit) else { return }
        let context = LibraryStore.shared.context
        close(); LibraryStore.shared.selectedKey = meeting.libraryKey
        MeetingNavigation.shared.open(meeting,frozen:context.screenshot)
        MeetingNavigation.shared.detail?.seek(Int(hit.positionMs))
        if play, MeetingNavigation.shared.detail?.isPlaying != true { MeetingNavigation.shared.detail?.toggle() }
    }
}
