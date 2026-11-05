// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// #118 review: a meeting's turns, prepared off the main actor. `request` starts preparing the
/// given words (a newer request cancels the one before); `cancel` stops it without forgetting
/// what was wanted, and `resume` starts it again if those turns aren't ready (a Library outage
/// cancels, its recovery resumes). A cancelled preparation never delivers.
@MainActor public final class TurnPreparation {
    /// The words, and their speakers' gap ranges (D63 #2).
    public typealias Prepare = @Sendable ([LibraryTranscriptItem], SpeakerGapRanges.Ranges) throws -> [MeetingPresentation.Turn]
    private let prepare: Prepare
    private let delivered: @MainActor ([MeetingPresentation.Turn]) -> Void
    private struct Wanted: Equatable { var items: [LibraryTranscriptItem]; var gaps: SpeakerGapRanges.Ranges }
    private var wanted = Wanted(items:[],gaps:[:])
    private var ready: Wanted?
    private var task: Task<Void,Never>?
    public init(prepare: @escaping Prepare = { try MeetingPresentation.turns($0,gaps:$1,cancellable:true) },
                delivered: @escaping @MainActor ([MeetingPresentation.Turn]) -> Void) {
        self.prepare = prepare; self.delivered = delivered
    }
    /// True while a preparation runs.
    public var preparing: Bool { task != nil }
    public func request(_ items: [LibraryTranscriptItem], gaps: SpeakerGapRanges.Ranges = [:]) {
        wanted = .init(items:items,gaps:gaps); ready = nil
        start()
    }
    public func cancel() { task?.cancel(); task = nil }
    /// Starts again when the wanted turns aren't ready and nothing is preparing them.
    public func resume() { if ready != wanted, task == nil { start() } }
    private func start() {
        task?.cancel()
        let request = wanted, prepare = prepare
        let work = Task.detached(priority:.userInitiated) { try prepare(request.items,request.gaps) }
        task = Task { [weak self] in
            let turns = await withTaskCancellationHandler { try? await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let turns, let self, self.wanted == request else { return }
            self.task = nil; self.ready = request
            self.delivered(turns)
        }
    }
}
