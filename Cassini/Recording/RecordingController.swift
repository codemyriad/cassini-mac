// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import CassiniLibrary
import CassiniRecording
import Observation

@MainActor @Observable final class RecordingController {
    static let shared = RecordingController()
    enum Phase { case idle, starting, recording, saving }
    private(set) var phase: Phase = .idle
    var isRecording: Bool { phase == .recording }
    var isStarting: Bool { phase == .starting }
    var isSaving: Bool { phase == .saving }
    var canStart: Bool { phase == .idle && LibraryLocationModel.shared.available }
    private(set) var diskMinutes: Int?
    private(set) var diskStopped = false
    @ObservationIgnored private let diskWatch = RecordingDiskWatch()
    @ObservationIgnored private var diskInfoTask: Task<Void,Never>?
    var diskLine: String? { diskStopped ? UXText.text("errors.diskStopped.line") : diskMinutes.map { UXText.text("errors.diskLow.line", ["n":String($0)]) } }
    func prepareDiskInfo(parent: URL) {
        diskInfoTask?.cancel(); diskStopped = false; diskMinutes = nil; RecordingDiskWatch.clear()
        diskInfoTask = Task {
            let minutes = await Task.detached { RecordingDiskWatch.inspect(parent,rate:48000 * 3 * 2)?.minutesLeft }.value
            guard !Task.isCancelled, !isRecording, !isSaving else { return }
            diskMinutes = minutes.flatMap { $0 < 10 ? $0 : nil }; diskInfoTask = nil
        }
    }
    var title = UXText.text("library.untitled")
    private(set) var startedAt: Date?
    private(set) var directory: URL?
    private(set) var lastCompletedDirectory: URL?
    private(set) var problem: String?
    private(set) var levels: [String: Float] = [:]
    private(set) var warnings: [String] = []
    private(set) var waitingForAudio = false
    private(set) var microphoneSilent = false
    @ObservationIgnored private(set) var spectrogram: RecordingSpectrogram?
    @ObservationIgnored private var timelineStart: TimeInterval?
    @ObservationIgnored private var lastMicSound: TimeInterval = 0
    @ObservationIgnored private var completedElapsedMs: Int64 = 0
    var elapsedMs: Int64 {
        guard isRecording, let timelineStart else { return completedElapsedMs }
        return Int64(max(0, ProcessInfo.processInfo.systemUptime - timelineStart) * 1000)
    }
    @ObservationIgnored var onSaved: ((URL) -> Void)?
    @ObservationIgnored private(set) var finishTask: Task<Void, Never>?
    @ObservationIgnored private var inputs: (any RecordingInputs)?
    @ObservationIgnored private var sink: RecordingSink?
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private var generation = 0

    func start(parent: URL) async {
        guard canStart else { return }
        #if DEBUG
        guard !LibraryLaunchContext.current.screenshot || RecordingFixture.enabled else { return }
        #endif
        SessionPlaybackController.stopAll(); PlayerController.pauseActive()
        generation += 1
        let attempt = generation
        title = UXText.text("library.untitled")
        problem = nil; warnings = []; directory = nil; lastCompletedDirectory = nil
        phase = .starting
        let inputs: any RecordingInputs
        #if DEBUG
        if RecordingFixture.enabled { inputs = HostedRecordingInputs() }
        else { inputs = NativeRecordingInputs() }
        #else
        inputs = NativeRecordingInputs()
        #endif
        self.inputs = inputs
        do {
            #if DEBUG
            if RecordingFixture.enabled {
                guard let expected = RecordingFixture.root, expected.standardizedFileURL.path == parent.standardizedFileURL.path else { throw CocoaError(.fileWriteNoPermission) }
            }
            #endif
            try await inputs.authorize()
            guard generation == attempt else { inputs.stop(); return }
            // Permission authorization may have yielded while Move published a
            // new Library. Resolve the destination at actual folder creation.
            let session = try LibraryRouting.withLock(file:LibraryLaunchContext.locationFile,exclusive:false,wait:false) {
                LibraryLocationModel.shared.reload()
                guard LibraryLocationModel.shared.available else { throw POSIXError(.ENOENT) }
                return try RecordingSession(parent:LibraryLocationModel.shared.roots[0],title:title,source:"macos")
            }
            try MeetingMetadataWriter(directory: session.directory, id: session.manifest.id).createIfNeeded()
            directory = session.directory; startedAt = session.manifest.createdAt
            let writer: any RecordingSinkWriter
            #if DEBUG
            writer = RecordingFixture.enabled ? HostedFinalizationWriter(session) : session
            #else
            writer = session
            #endif
            let origin = ProcessInfo.processInfo.systemUptime
            spectrogram = RecordingSpectrogram.enabled ? RecordingSpectrogram(originUptime:origin,observers:session.pcmObservers) : nil
            timelineStart = origin; lastMicSound = origin; completedElapsedMs = 0; microphoneSilent = false
            let sink = RecordingSink(session: writer, originHostTime: AVAudioTime.hostTime(forSeconds: origin)) { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generation == attempt, self.phase != .saving else { return }
                    self.stop(problem: message)
                }
            }
            self.sink = sink
            try inputs.start(sink: sink) { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generation == attempt, self.phase != .saving else { return }
                    self.stop(problem: message)
                }
            }
            phase = .recording
            diskWatch.start(directory: session.directory) { [weak self] budget in
                self?.applyDiskBudget(budget)
            }
            statusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let status = self.sink?.status() else { return }
                    self.levels = status.levels; self.warnings = status.warnings
                    let now = ProcessInfo.processInfo.systemUptime
                    if status.levels["microphone",default:0] >= 0.01 { self.lastMicSound = now }
                    self.microphoneSilent = now - self.lastMicSound >= 20
                    self.waitingForAudio = Date().timeIntervalSince(self.startedAt ?? Date()) > 5 && ["microphone", "output"].contains { status.frames[$0, default: 0] == 0 }
                }
            }
        } catch { guard generation == attempt else { return }; stop(problem: error.localizedDescription) }
    }
    private func applyDiskBudget(_ budget: DiskBudget) {
        guard isRecording else { return }
        diskMinutes = budget.minutesLeft.flatMap { $0 < 30 ? $0 : nil }
        if budget.shouldStop { diskStopped = true; RecordingDiskWatch.clear(); stop(); return }
        RecordingDiskWatch.updateWarning(diskLine)
    }
    #if DEBUG
    func applyDiskBudgetForTesting(_ budget: DiskBudget) {
        guard RecordingFixture.enabled else { return }; applyDiskBudget(budget)
    }
    #endif
    func stop(problem: String? = nil) {
        guard phase == .starting || phase == .recording else { return }
        spectrogram?.stop(atMs:Double(elapsedMs))
        completedElapsedMs = elapsedMs
        generation += 1
        let attempt = generation
        self.problem = problem
        if !diskStopped { RecordingDiskWatch.clear() }
        diskWatch.stop()
        statusTimer?.invalidate(); statusTimer = nil
        inputs?.stop(); inputs = nil
        levels = [:]; waitingForAudio = false
        let sink = self.sink; self.sink = nil
        guard let sink, let directory else {
            phase = .idle; spectrogram = nil
            if let problem { present(problem) }
            return
        }
        phase = .saving
        finishTask = Task { [weak self] in
            var failure: String?
            do { try await Task.detached(priority: .userInitiated) { try sink.finish(problem: problem) }.value }
            catch { failure = error.localizedDescription }
            guard let self, self.generation == attempt else { return }
            self.problem = problem ?? failure
            self.lastCompletedDirectory = directory
            self.phase = .idle; self.finishTask = nil; self.spectrogram = nil
            self.onSaved?(directory)
            if let issue = self.problem { self.present(issue) }
        }
    }
    func stopAndWait() async { stop(); await finishTask?.value }
    private func present(_ message: String) {
        NSApp.presentError(NSError(domain: "CassiniRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
    }
}

enum RecordingFixture {
    static var enabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1" && CommandLine.arguments.contains("--fixture-library-recording")
        #else
        return false
        #endif
    }
    static var transcribes: Bool {
        #if DEBUG
        return enabled && LibraryLaunchContext.argument("-CassiniTranscriptionFixture") == "YES"
        #else
        return false
        #endif
    }
    static var root: URL? {
        #if DEBUG
        guard enabled, let key = LibraryLaunchContext.argument("-CassiniCaptureID"), UUID(uuidString: key) != nil else { return nil }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniLibrary-" + key)
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return parent.appendingPathComponent("root")
        #else
        return nil
        #endif
    }
}
