// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CassiniRecording
import CassiniBrowserControl

/// The D60 dialog must remain responsive even while Core Audio opens a device.
/// Admission and the first-buffer deadline remain in CaptureInputLifecycle.
@MainActor final class TestRecordingInput: CaptureInput {
    private let side: CaptureSide
    private let worker: Worker
    init(_ side: CaptureSide) { self.side = side; worker = Worker(side) }
    func authorize() async throws {
        guard side == .me else { return }
        let permitted: Bool
        switch AVCaptureDevice.authorizationStatus(for:.audio) {
        case .authorized: permitted = true
        case .notDetermined: permitted = await AVCaptureDevice.requestAccess(for:.audio)
        default: permitted = false
        }
        guard permitted else { throw CaptureOpenRefusal.denied }
    }
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws { worker.start(sink:sink,failure:failure) }
    func stop() { worker.stop() }
    func drain() async { await worker.drain() }

    /// All device state belongs to this serial queue. Only the cancellation bit
    /// crosses it, so a late successful open is immediately closed, not admitted.
    private final class Worker: @unchecked Sendable {
        let side: CaptureSide
        let queue = DispatchQueue(label:"io.codemyriad.cassini.test-input",qos:.userInitiated)
        let lock = NSLock()
        var cancelled = false
        var engine: AVAudioEngine?
        var tap: AudioProcessTap?
        var observer: NSObjectProtocol?
        var installed = false
        init(_ side: CaptureSide) { self.side = side }
        func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) {
            queue.async { [self] in
                guard !lock.withLock({ cancelled }) else { return }
                do {
                    if side == .others {
                        let tap = AudioProcessTap(); self.tap = tap
                        let label = UXText.text("recordFirst.sound.title")
                        _ = try tap.start(processes:nil,onFormatChange:{ failure(UXText.mac("recording.outputChanged")) }) { buffer,host in
                            sink.receive(buffer,hostTime:host,id:"output",label:label,kind:"system")
                        }
                    } else {
                        let engine = AVAudioEngine(); self.engine = engine
                        let input = engine.inputNode, format = input.outputFormat(forBus:0)
                        guard format.sampleRate > 0, (1...64).contains(format.channelCount) else { throw MeetingInputError.microphoneUnavailable }
                        let label = UXText.text("common.yourMicrophone")
                        input.installTap(onBus:0,bufferSize:4096,format:format) { buffer,time in
                            sink.receive(buffer,hostTime:time.isHostTimeValid ? time.hostTime : 0,id:"microphone",label:label,kind:"microphone")
                        }
                        installed = true
                        try engine.start()
                        observer = NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:engine,queue:nil) { _ in
                            failure(UXText.mac("recording.micChanged"))
                        }
                    }
                    if lock.withLock({ cancelled }) { close() }
                } catch {
                    close()
                    if !lock.withLock({ cancelled }) { failure(error.localizedDescription) }
                }
            }
        }
        func stop() {
            lock.withLock { cancelled = true }
            queue.async { self.close() }
        }
        func drain() async {
            await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        }
        private func close() {
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            if let engine {
                engine.stop()
                if installed { engine.inputNode.removeTap(onBus:0) }
            }
            installed = false; engine = nil
            tap?.stop(); tap = nil
        }
    }
}
