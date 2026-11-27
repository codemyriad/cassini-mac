// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CassiniRecording
import Observation

@MainActor protocol RecordingInputs: AnyObject {
    func authorize() async throws
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws
    func stop()
}

extension AudioProcessTap: @unchecked Sendable, SystemAudioTap {
    func start(
        onFormatChange: @escaping @Sendable () -> Void,
        receive: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void
    ) throws {
        _ = try start(processes: nil, onFormatChange: onFormatChange, receive: receive)
    }
}

@MainActor final class NativeRecordingInputs: RecordingInputs {
    private let microphone: MicrophoneCaptureDriver
    private let outputTap: OutputTapDriver

    init(
        makeEngine: @escaping () -> any MicrophoneAudioEngine = { AVAudioMicrophoneEngine() },
        makeTap: @escaping @Sendable () -> any SystemAudioTap = { AudioProcessTap() },
        notificationCenter: NotificationCenter = .default
    ) {
        microphone = MicrophoneCaptureDriver(makeEngine: makeEngine, notificationCenter: notificationCenter)
        outputTap = OutputTapDriver(makeTap: makeTap)
    }

    func authorize() async throws {
        let permitted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permitted = true
        case .notDetermined: permitted = await AVCaptureDevice.requestAccess(for: .audio)
        default: permitted = false
        }
        guard permitted else { throw RecordingError.invalid(UXText.text("errors.micPermission.line")) }
    }

    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws {
        let outputLabel = UXText.text("recordFirst.sound.title"), micLabel = UXText.text("common.yourMicrophone")
        try outputTap.start(
            sink: sink,
            label: outputLabel,
            changedMessage: UXText.mac("recording.outputChanged"),
            failure: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.stop()
                    failure(message)
                }
            }
        )
        do {
            try microphone.start(
                sink: sink,
                label: micLabel,
                missingError: { RecordingError.invalid(UXText.mac("recording.micMissing")) },
                changedMessage: UXText.mac("recording.micChanged"),
                failure: failure
            )
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        microphone.stop()
        outputTap.stop()
    }
}

#if DEBUG
/// Hosted-only driver exercises the actual controller/sink/files without devices
/// or permissions. Release builds contain no synthetic recording entry point.
@MainActor final class HostedRecordingInputs: RecordingInputs {
    // Fixture configuration is immutable for this driver. In particular, do
    // not copy ProcessInfo.environment once per PCM sample in a manual burst.
    private let transcribes = RecordingFixture.transcribes
    private let initialMicRate: Int? = {
        guard let raw = LibraryLaunchContext.argument("-CassiniFixtureMicRate"),
              let parsed = Int(raw), (8_000...192_000).contains(parsed) else { return nil }
        return parsed
    }()
    private var timer: Timer?
    private var frames: UInt64 = 0
    private var micFrames: UInt64 = 0
    private var micRateOverride: Int?
    private var speech: [Float] = []
    private var manualClock = false
    private var rate: Int { transcribes ? 16000 : 48000 }
    private var currentMicRate: Int { micRateOverride ?? initialMicRate ?? rate }
    private var origin = AVAudioTime.hostTime(forSeconds: ProcessInfo.processInfo.systemUptime)
    func useFixtureClock(origin: TimeInterval) {
        manualClock = true; self.origin = AVAudioTime.hostTime(forSeconds:origin)
    }
    func switchMicrophoneRate(to newRate: Int) {
        guard (8_000...192_000).contains(newRate) else { return }
        micRateOverride = newRate
    }
    func advanceFixtureMedia(toMilliseconds ms: Int, sink: RecordingSink) -> UInt64 {
        precondition(manualClock)
        let target = UInt64(ms * rate / 1000)
        while frames < target {
            emit(sink)
            // Keep bursts below the real writer's per-source pending-frame budget.
            if frames % UInt64(rate) == 0 { sink.flush() }
        }
        sink.flush()
        return target
    }
    func authorize() async throws {}
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws {
        if transcribes {
            let url = Bundle.main.resourceURL!.appendingPathComponent("Whistle/jfk.wav")
            let data = try Data(contentsOf: url)
            guard data.count > 44 else { throw CocoaError(.fileReadCorruptFile) }
            speech = stride(from: 44, to: data.count - 1, by: 2).map { offset in
                data.withUnsafeBytes { Float(Int16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768 }
            }
        }
        emit(sink)
        guard !manualClock else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit(sink) }
        }
    }
    private func emit(_ sink: RecordingSink) {
        let elapsedSeconds = Double(frames) / Double(rate)
        let host = origin + AVAudioTime.hostTime(forSeconds: elapsedSeconds)
        for (id, level, kind) in [("microphone", Float(0.12), "microphone"), ("output", Float(0.38), "system")] {
            let sourceRate = id == "microphone" ? currentMicRate : rate
            let count = max(1, sourceRate / 50)
            let format = AVAudioFormat(standardFormatWithSampleRate: Double(sourceRate), channels: 1)!
            let level = id == "microphone" && LibraryLaunchContext.argument("-CassiniSilentMicrophone") == "YES" ? 0 : level
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            let baseFrame = id == "microphone" ? Int(micFrames) : Int(frames)
            for n in 0..<count {
                let at = baseFrame + n
                // A constant-valued fixture is DC, not audible sound. Preserve
                // the same expected peak with a generated 400 Hz AC tone.
                if transcribes {
                    let speechIndex = sourceRate == 16000 ? at : Int(Double(at) * 16000.0 / Double(sourceRate))
                    buffer.floatChannelData![0][n] = id == "microphone" && speechIndex < speech.count ? speech[speechIndex] : 0
                } else {
                    buffer.floatChannelData![0][n] = level * Float(cos(2 * Double.pi * 400 * Double(at) / Double(sourceRate)))
                }
            }
            sink.receive(buffer, hostTime: host, id: id, label: id, kind: kind)
            if id == "microphone" { micFrames += UInt64(count) }
        }
        frames += UInt64(max(1, rate / 50))
    }
    func stop() { timer?.invalidate(); timer = nil }
}
/// Explicitly opted-in UI tests release finalization after inspecting Saving.
/// Suspending the task holds no thread and all writes use RecordingSession.
@MainActor @Observable final class RecordingFinalizationFixture {
    static let shared = RecordingFinalizationFixture()
    private(set) var waiting = false
    @ObservationIgnored private var continuation: CheckedContinuation<Void,Never>?
    func waitIfNeeded() async {
        guard RecordingFixture.enabled,
              LibraryLaunchContext.argument("-CassiniHoldFinalization") == "YES" else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiting = true
        }
    }
    func release() {
        let pending = continuation
        continuation = nil; waiting = false
        pending?.resume()
    }
}
#endif
