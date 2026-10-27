import AppKit
import AVFoundation
import CassiniRecording
import Observation

@MainActor @Observable
final class RecordingController {
    static let shared = RecordingController()
    enum Output: String, CaseIterable { case none = "No output audio", application = "Selected processes", system = "All system audio" }
    var output: Output = .system
    var includeMicrophone = true
    var processes: [AudioProcess] = []
    var selectedProcesses: Set<UInt32> = []
    var title = "Meeting"
    private(set) var isRecording = false
    private(set) var isSaving = false
    private var savingTask: Task<Void, Never>?
    private(set) var isStarting = false
    private var startCancelled = false
    private(set) var startedAt: Date?
    private(set) var directory: URL?
    private(set) var problem: String?
    private(set) var levels: [String: Float] = [:]
    private(set) var warnings: [String] = []
    private(set) var waitingForAudio = false
    private var engine: AVAudioEngine?
    private var tap: AudioProcessTap?
    private var sink: RecordingSink?
    private var scopedParent: URL?
    private var configurationObserver: NSObjectProtocol?
    private var statusTimer: Timer?

    var canStart: Bool {
        !isRecording && !isStarting && !isSaving && (includeMicrophone || output != .none)
            && (output != .application || !selectedProcesses.isEmpty)
    }

    func refreshProcesses() {
        do {
            processes = try AudioProcessTap.processes()
            selectedProcesses.formIntersection(Set(processes.map(\.id)))
        } catch { problem = error.localizedDescription }
    }

    func start() async {
        guard canStart else { return }
        problem = nil
        warnings = []
        let panel = NSOpenPanel()
        panel.title = "Choose where to save the recording"
        panel.prompt = "Record Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        isStarting = true
        startCancelled = false
        defer { isStarting = false }
        if parent.startAccessingSecurityScopedResource() { scopedParent = parent }
        do {
            if includeMicrophone {
                let permitted = await AVCaptureDevice.requestAccess(for: .audio)
                guard !startCancelled else { return }
                guard permitted else { throw RecordingError.invalid("Allow microphone access in System Settings → Privacy & Security → Microphone, then try again.") }
            }
            let session = try RecordingSession(parent: parent, title: title, source: "macos")
            directory = session.directory
            let recordingDirectory = session.directory
            let sink = RecordingSink(session: session) { message in
                let directory = recordingDirectory
                Task { @MainActor in
                    guard RecordingController.shared.directory == directory else { return }
                    await RecordingController.shared.stop(problem: message)
                }
            }
            self.sink = sink
            startedAt = Date()
            if output != .none {
                let tap = AudioProcessTap()
                self.tap = tap
                let label = output == .system ? "System output" : processes.filter { selectedProcesses.contains($0.id) }.map(\.name).joined(separator: ", ")
                let kind = output == .system ? "system" : "application"
                let directory = session.directory
                _ = try tap.start(processes: output == .system ? nil : Array(selectedProcesses), onFormatChange: {
                    Task { @MainActor in
                        guard RecordingController.shared.directory == directory else { return }
                        await RecordingController.shared.stop(problem: "The output audio format changed. Start a new recording with the current device.")
                    }
                }) { buffer, time in
                    sink.receive(buffer, hostTime: time, id: "output", label: label, kind: kind)
                }
            }
            if includeMicrophone {
                let engine = AVAudioEngine()
                self.engine = engine
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, (1...64).contains(format.channelCount) else {
                    throw RecordingError.invalid("No supported microphone is available. Choose an input in Sound settings. Multichannel inputs record channels 1 and 2.")
                }
                input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
                    sink.receive(buffer, hostTime: time.isHostTimeValid ? time.hostTime : 0,
                                 id: "microphone", label: "Microphone", kind: "microphone")
                }
                try engine.start()
                configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
                    Task { @MainActor in
                        guard RecordingController.shared.directory == recordingDirectory else { return }
                        await RecordingController.shared.stop(problem: "The microphone configuration changed. Start a new recording with the current input.")
                    }
                }
            }
            isRecording = true
            statusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let status = self.sink?.status() else { return }
                    self.levels = status.levels
                    self.warnings = status.warnings
                    if status.gapMs > 0 { self.warnings.append("Host-time gaps preserved as silence: \(Int(status.gapMs.rounded())) ms.") }
                    if status.droppedMs > 0 { self.warnings.append("Audio lost during a disk stall: \(Int(status.droppedMs.rounded())) ms. Gaps will contain silence.") }
                    let expecting = self.output == .none ? ["microphone"] : (self.includeMicrophone ? ["output", "microphone"] : ["output"])
                    self.waitingForAudio = Date().timeIntervalSince(self.startedAt ?? Date()) > 5
                        && expecting.contains { status.frames[$0, default: 0] == 0 }
                }
            }
        } catch { await stop(problem: error.localizedDescription) }
    }

    func stop(problem: String? = nil) async {
        if let savingTask { await savingTask.value; return }
        guard sink != nil || isStarting else { return }
        startCancelled = true
        self.problem = problem
        statusTimer?.invalidate()
        statusTimer = nil
        levels = [:]
        waitingForAudio = false
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver); self.configurationObserver = nil }
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
        tap?.stop()
        tap = nil
        let finishing = sink
        sink = nil
        isRecording = false
        isSaving = true
        let task = Task { @MainActor in
            do { try await finishing?.finishAsync(problem: problem) }
            catch { self.problem = error.localizedDescription }
            self.scopedParent?.stopAccessingSecurityScopedResource()
            self.scopedParent = nil
            self.isSaving = false
        }
        savingTask = task
        await task.value
        savingTask = nil
    }

    func reveal() {
        if let directory { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
    }
}
