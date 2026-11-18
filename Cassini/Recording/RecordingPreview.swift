// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Synchronization
import CassiniRecording
import CassiniTranscription
import CassiniWhistle

/// The opt-in app owns the subscription and model lease. Drafts never leave memory.
@MainActor final class RecordingPreview {
    private static var active: (id: UUID, task: Task<Void, Never>)?
    private let drafts: Mutex<[String: [WhistleTranscript.Word]]>
    private let task: Task<Void, Never>

    static func start(_ observers: RecordedPCMObservers) -> RecordingPreview? {
        #if DEBUG
        guard CommandLine.arguments.contains("--live-transcription-preview") else { return nil }
        return RecordingPreview(observers.livePCM())
        #else
        return nil
        #endif
    }

    private init(_ input: AsyncStream<LivePCMEvent>) {
        let state = Mutex<[String: [WhistleTranscript.Word]]>([:])
        drafts = state
        let previous = Self.active?.task
        let id = UUID()
        task = Task {
            defer { if Self.active?.id == id { Self.active = nil } }
            await previous?.value
            do {
                let model = try await SpeechModelController.shared.modelForNewJob()
                defer { withExtendedLifetime(model) {} }
                try Task.checkCancellation()
                let workerName = model == nil ? "cassini-whistle-worker" : "cassini-parakeet-worker"
                let worker = WhistleSubprocess.WindowSession(
                    executable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(workerName)"),
                    arguments: model.map { ["--model", $0.lease.directory.path] } ?? [],
                    environment: WhistleEnvironment.worker()
                )
                do {
                    try await LiveCaptureTranscription.follow(input, worker: worker) { revision in
                        state.withLock { drafts in
                            var words = drafts[revision.source] ?? []
                            words.removeAll {
                                let midpoint = ($0.start + $0.end) * 500
                                return revision.fromMs <= midpoint && midpoint < revision.throughMs
                            }
                            words.append(contentsOf: revision.words)
                            drafts[revision.source] = words
                        }
                    }
                } catch {
                    await worker.close()
                    throw error
                }
                await worker.close()
            } catch {
                // A preview failure cannot block capture or the saved-audio job.
            }
        }
        Self.active = (id, task)
    }

    func cancel() { task.cancel() }
    var snapshot: [String: [WhistleTranscript.Word]] { drafts.withLock { $0 } }
}
