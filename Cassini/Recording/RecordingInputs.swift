// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CassiniRecording

@MainActor protocol RecordingInputs: AnyObject {
    func authorize() async throws
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws
    func stop()
}

@MainActor final class NativeRecordingInputs: RecordingInputs {
    private var engine: AVAudioEngine?
    private var tap: AudioProcessTap?
    private var observer: NSObjectProtocol?
    func authorize() async throws {
        let permitted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permitted = true
        case .notDetermined: permitted = await AVCaptureDevice.requestAccess(for: .audio)
        default: permitted = false
        }
        guard permitted else { throw RecordingError.invalid(UXText.mac("recording.micDenied")) }
    }
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws {
        let tap = AudioProcessTap(); self.tap = tap
        let outputLabel = UXText.text("recordFirst.sound.title"), micLabel = UXText.text("common.yourMicrophone")
        _ = try tap.start(processes: nil, onFormatChange: { failure(UXText.mac("recording.outputChanged")) }) { buffer, host in
            sink.receive(buffer, hostTime: host, id: "output", label: outputLabel, kind: "system")
        }
        let engine = AVAudioEngine(); self.engine = engine
        let input = engine.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, (1...64).contains(format.channelCount) else {
            throw RecordingError.invalid(UXText.mac("recording.micMissing"))
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            sink.receive(buffer, hostTime: time.isHostTimeValid ? time.hostTime : 0, id: "microphone", label: micLabel, kind: "microphone")
        }
        try engine.start()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            failure(UXText.mac("recording.micChanged"))
        }
    }
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0); self.engine = nil }
        tap?.stop(); tap = nil
    }
}

#if DEBUG
/// Hosted-only driver exercises the actual controller/sink/files without devices
/// or permissions. Release builds contain no synthetic recording entry point.
@MainActor final class HostedRecordingInputs: RecordingInputs {
    private var timer: Timer?
    private var frames: UInt64 = 0
    private var speech: [Float] = []
    private var origin = AVAudioTime.hostTime(forSeconds: ProcessInfo.processInfo.systemUptime)
    func authorize() async throws {}
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws {
        if RecordingFixture.transcribes {
            let url = Bundle.main.resourceURL!.appendingPathComponent("Whistle/jfk.wav")
            let data = try Data(contentsOf: url)
            guard data.count > 44 else { throw CocoaError(.fileReadCorruptFile) }
            speech = stride(from: 44, to: data.count - 1, by: 2).map { offset in
                data.withUnsafeBytes { Float(Int16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768 }
            }
        }
        emit(sink)
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit(sink) }
        }
    }
    private func emit(_ sink: RecordingSink) {
        let rate = RecordingFixture.transcribes ? 16000 : 48000
        let count = rate / 50
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
        let host = origin + AVAudioTime.hostTime(forSeconds: Double(frames) / Double(rate))
        for (id, level, kind) in [("microphone", Float(0.12), "microphone"), ("output", Float(0.38), "system")] {
            let level = id == "microphone" && LibraryLaunchContext.argument("-CassiniSilentMicrophone") == "YES" ? 0 : level
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for n in 0..<count {
                let at = Int(frames) + n
                // A constant-valued fixture is DC, not audible sound. Preserve
                // the same expected peak with a generated 400 Hz AC tone.
                buffer.floatChannelData![0][n] = RecordingFixture.transcribes
                    ? (id == "microphone" && at < speech.count ? speech[at] : 0)
                    : level * Float(cos(2 * Double.pi * 400 * Double(at) / Double(rate)))
            }
            sink.receive(buffer, hostTime: host, id: id, label: id, kind: kind)
        }
        frames += UInt64(count)
    }
    func stop() { timer?.invalidate(); timer = nil }
}
/// A deterministic disk-finalization stall makes the production Saving state
/// observable to hosted UI tests. All file writes still use RecordingSession.
final class HostedFinalizationWriter: RecordingSinkWriter {
    private let session: RecordingSession
    init(_ session: RecordingSession) { self.session = session }
    var recordingProblem: String? { session.recordingProblem }
    func addTrack(id: String, label: String, kind: String, sampleRate: Int, channels: Int) throws {
        try session.addTrack(id: id, label: label, kind: kind, sampleRate: sampleRate, channels: channels)
    }
    func appendNative(id: String, pcm: Data, offsetMs: Double) throws { try session.appendNative(id: id, pcm: pcm, offsetMs: offsetMs) }
    func finish(problem: String?) throws { Thread.sleep(forTimeInterval: 1.25); try session.finish(problem: problem) }
}
#endif
