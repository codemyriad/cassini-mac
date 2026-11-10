// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// #118 review: a meeting's turns, prepared off the main actor. `request` starts preparing the
/// given words (a newer request cancels the one before); `cancel` stops it without forgetting
/// what was wanted, and `resume` starts it again if those turns aren't ready (a Library outage
/// cancels, its recovery resumes). A cancelled preparation never delivers.
@MainActor public final class TurnPreparation {
    /// The words, and their speakers' gap ranges (D63 #2).
    public typealias Prepare = @Sendable ([LibraryTranscriptItem], SpeakerGapRanges.Ranges) throws -> [MeetingPresentation.Turn]
    private let prepare: @Sendable ([LibraryTranscriptItem],SpeakerGapRanges.Ranges,Bool) throws -> [MeetingPresentation.Turn]
    private let delivered: @MainActor ([MeetingPresentation.Turn]) -> Void
    private struct Wanted: Equatable { var items: [LibraryTranscriptItem]; var gaps: SpeakerGapRanges.Ranges; var endsBoundedByAudio = false }
    private var wanted = Wanted(items:[],gaps:[:])
    private var ready: Wanted?
    private var task: Task<Void,Never>?
    /// D70 listening runs, prepared by the same worker and published with its rows.
    public private(set) var speakerTurns: [SpeakerTurn] = []
    public private(set) var timelineReadout = TimelineReadout()
    public private(set) var transcriptListening = TranscriptListening()
    public init(prepare: Prepare? = nil,
                delivered: @escaping @MainActor ([MeetingPresentation.Turn]) -> Void) {
        self.prepare = { items,gaps,bounded in
            if let prepare { return try prepare(items,gaps) }
            return try MeetingPresentation.turns(items,gaps:gaps,endsBoundedByAudio:bounded,cancellable:true)
        }
        self.delivered = delivered
    }
    /// True while a preparation runs.
    public var preparing: Bool { task != nil }
    public func request(_ items: [LibraryTranscriptItem], gaps: SpeakerGapRanges.Ranges = [:], endsBoundedByAudio: Bool = false) {
        wanted = .init(items:items,gaps:gaps,endsBoundedByAudio:endsBoundedByAudio); ready = nil
        start()
    }
    public func cancel() { task?.cancel(); task = nil }
    /// Starts again when the wanted turns aren't ready and nothing is preparing them.
    public func resume() { if ready != wanted, task == nil { start() } }
    private func start() {
        task?.cancel()
        let request = wanted, prepare = prepare
        let work = Task.detached(priority:.userInitiated) {
            let rows = try prepare(request.items,request.gaps,request.endsBoundedByAudio)
            try Task.checkCancellation()
            let listening = SpeakerTurn.grouping(request.items)
            try Task.checkCancellation()
            let readout = TimelineReadout(items:request.items)
            try Task.checkCancellation()
            let mapping = TranscriptListening(rows:rows,turns:listening)
            try Task.checkCancellation()
            return (rows,listening,readout,mapping)
        }
        task = Task { [weak self] in
            let turns = await withTaskCancellationHandler { try? await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let turns, let self, self.wanted == request else { return }
            self.task = nil; self.ready = request
            self.speakerTurns = turns.1
            self.timelineReadout = turns.2
            self.transcriptListening = turns.3
            self.delivered(turns.0)
        }
    }
}
