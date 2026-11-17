// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CassiniRecording
import CassiniBrowserControl

protocol TestRecordingDevice: AnyObject { func close() }

/// The D60 dialog remains responsive while Core Audio opens a device.
/// Admission and the first-buffer deadline remain in CaptureInputLifecycle.
@MainActor final class TestRecordingInput: CaptureInput {
    struct Callbacks: Sendable {
        let receive: @Sendable (AVAudioPCMBuffer,UInt64) -> Void
        let failure: @Sendable (String) -> Void
    }
    typealias Open = @Sendable (CaptureSide,Callbacks) throws -> any TestRecordingDevice
    private let side: CaptureSide
    private let worker: Worker
    #if DEBUG
    private var fixtureAuthorization = false
    init(_ side: CaptureSide, open: @escaping Open) {
        self.side = side; worker = Worker(side,open:open); fixtureAuthorization = true
    }
    #endif
    init(_ side: CaptureSide) { self.side = side; worker = Worker(side,open:{ try NativeDevice.open($0,$1) }) }
    func authorize() async throws {
        #if DEBUG
        if fixtureAuthorization { return }
        #endif
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

    /// Device state belongs to this queue. Stop closes admission synchronously,
    /// including callbacks from an open that completes after cancellation.
    private final class Worker: @unchecked Sendable {
        let side: CaptureSide
        let open: Open
        let queue = DispatchQueue(label:"io.codemyriad.cassini.test-input",qos:.userInitiated)
        let lock = NSLock()
        var cancelled = false
        var device: (any TestRecordingDevice)?
        init(_ side: CaptureSide, open: @escaping Open) { self.side = side; self.open = open }
        func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) {
            queue.async { [self] in
                guard !lock.withLock({ cancelled }) else { return }
                let id = side == .me ? "microphone":"output"
                let kind = side == .me ? "microphone":"system"
                let label = UXText.text(side == .me ? "common.yourMicrophone":"recordFirst.sound.title")
                let callbacks = Callbacks(receive:{ [weak self] buffer,host in
                    self?.admit { sink.receive(buffer,hostTime:host,id:id,label:label,kind:kind) }
                },failure:{ [weak self] message in self?.admit { failure(message) } })
                do {
                    device = try open(side,callbacks)
                    if lock.withLock({ cancelled }) { close() }
                } catch {
                    close(); callbacks.failure(error.localizedDescription)
                }
            }
        }
        private func admit(_ callback: () -> Void) {
            lock.withLock { if !cancelled { callback() } }
        }
        func stop() {
            lock.withLock { cancelled = true }
            queue.async { self.close() }
        }
        func drain() async {
            await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        }
        private func close() {
            let previous = device; device = nil
            previous?.close()
        }
    }

    /// Construction and close both run on Worker's queue, including failed opens.
    private final class NativeDevice: TestRecordingDevice {
        var engine: AVAudioEngine?
        var tap: AudioProcessTap?
        var observer: NSObjectProtocol?
        var installed = false
        static func open(_ side: CaptureSide, _ callbacks: Callbacks) throws -> any TestRecordingDevice {
            let device = NativeDevice()
            do { try device.start(side,callbacks); return device }
            catch { device.close(); throw error }
        }
        private func start(_ side: CaptureSide, _ callbacks: Callbacks) throws {
            if side == .others {
                let tap = AudioProcessTap(); self.tap = tap
                _ = try tap.start(processes:nil,onFormatChange:{ callbacks.failure(UXText.mac("recording.outputChanged")) }) { buffer,host in
                    callbacks.receive(buffer,host)
                }
            } else {
                let engine = AVAudioEngine(); self.engine = engine
                let input = engine.inputNode, format = input.outputFormat(forBus:0)
                guard format.sampleRate > 0, (1...64).contains(format.channelCount) else { throw MeetingInputError.microphoneUnavailable }
                input.installTap(onBus:0,bufferSize:4096,format:format) { buffer,time in
                    callbacks.receive(buffer,time.isHostTimeValid ? time.hostTime : 0)
                }
                installed = true
                try engine.start()
                observer = NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:engine,queue:nil) { _ in
                    callbacks.failure(UXText.mac("recording.micChanged"))
                }
            }
        }
        func close() {
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
