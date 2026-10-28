// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary
import CassiniTranscription
import CassiniWhistle
import Observation

/// One bounded worker, FIFO by arrival. A capture and playback may continue while
/// this child writes only app-owned sidecars. Failed jobs require an explicit retry.
@MainActor @Observable final class TranscriptionQueue {
    static let shared = TranscriptionQueue()
    private(set) var active: URL?
    @ObservationIgnored private var pending: [LibraryMeeting] = []
    @ObservationIgnored private var known = Set<String>()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var closing = false
    var isBusy: Bool { task != nil || !pending.isEmpty }
    func beginShutdown() {
        guard !closing else { return }; closing = true
        pending.removeAll(); task?.cancel()
    }
    func waitForShutdown() async { await task?.value }
    #if DEBUG
    @ObservationIgnored private var failedFixtureOnce = false
    #endif
    func consider(_ meetings: [LibraryMeeting], automatic: Bool) {
        guard automatic, !closing else { return }
        let candidates = meetings.filter(\.canQueueAutomatically)
            .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        for meeting in candidates { enqueue(meeting) }
    }
    func enqueue(_ meeting: LibraryMeeting, retry: Bool = false) {
        guard !closing, !meeting.metadataReadOnly, meeting.state.lifecycle == .saved, !meeting.audioFiles.isEmpty,
              active?.path != meeting.folder.path, !pending.contains(where: { $0.folder.path == meeting.folder.path }) else { return }
        if retry { known.remove(meeting.folder.path) }
        guard known.insert(meeting.folder.path).inserted else { return }
        do {
            if ![.queued,.running].contains(meeting.state.transcript) {
                try MeetingTranscriber.setStatus(directory: meeting.folder, id: meeting.id, status: "queued")
            }
            pending.append(meeting); startNext()
        } catch { NSApp.presentError(error) }
    }
    func writeDown(_ detail: MeetingDetailModel) {
        guard !closing, detail.meeting.canWriteDown else { return }
        guard let original = detail.fileURL else { enqueue(detail.meeting, retry: detail.meeting.state.transcript == .failed); return }
        let root = LibraryLaunchContext.current.root
        Task {
            do {
                // Retain the detail/player's security scope while copying off-main.
                let meeting = try await Task.detached { [detail] in
                    defer { withExtendedLifetime(detail) {} }
                    return try ReceivedAudioImport.copy(original, into: root)
                }.value
                enqueue(meeting); MeetingNavigation.shared.open(meeting)
            } catch { NSApp.presentError(error) }
        }
    }
    private func startNext() {
        guard !closing, task == nil, !pending.isEmpty else { return }
        let meeting = pending.removeFirst(); active = meeting.folder
        task = Task {
            do {
                struct Request: Encodable { let id: String; let meeting: String; let me: String; let others: String }
                let input = try JSONEncoder().encode(Request(id: UUID().uuidString, meeting: meeting.folder.path, me: UXText.text("common.me"), others: UXText.text("common.theOthers"))) + Data([10])
                var worker = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cassini-whistle-worker")
                var arguments: [String] = []
                #if DEBUG
                if RecordingFixture.transcribes, LibraryLaunchContext.argument("-CassiniFailTranscriptionOnce") == "YES", !failedFixtureOnce {
                    failedFixtureOnce = true; worker = URL(fileURLWithPath: "/usr/bin/false")
                }
                if RecordingFixture.transcribes, LibraryLaunchContext.argument("-CassiniSlowTranscription") == "YES" {
                    worker = URL(fileURLWithPath:"/bin/sleep"); arguments = ["60"]
                }
                #endif
                let result = try await WhistleSubprocess.run(executable: worker, arguments: arguments, environment: WhistleEnvironment.worker(), input: input, timeout: 24 * 60 * 60)
                struct Response: Decodable { let error: String? }
                guard result.status == 0, result.inputError == nil else { throw TranscriptionFailure.runtime("worker exited") }
                let response = try JSONDecoder().decode(Response.self, from: result.stdout)
                if let error = response.error, !error.contains("meeting is already being written down") { throw TranscriptionFailure.runtime(error) }
            } catch is CancellationError {
                // Quit pauses work. Preserve the sidecar and its reference for
                // next-launch recovery instead of turning cancellation into failure.
                try? await Task.detached(priority:.userInitiated) {
                    try MeetingTranscriber.pauseForResume(directory:meeting.folder,id:meeting.id)
                }.value
            } catch {
                // Worker crashes and bundle/decoder failures take the same retry path.
                try? MeetingTranscriber.setStatus(directory: meeting.folder, id: meeting.id, status: "failed")
            }
            await Task.detached { SegmentedAudio.removeAbandonedScratch() }.value
            active = nil; task = nil; startNext()
        }
    }
}
