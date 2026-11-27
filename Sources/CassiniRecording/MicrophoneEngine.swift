// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Testable seam over `AVAudioEngine` for native microphone capture.
public protocol MicrophoneAudioEngine: AnyObject {
    var notificationObject: AnyObject? { get }
    func inputFormat() -> AVAudioFormat
    func installTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat, block: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void)
    func removeTap()
    func start() throws
    func stop()
}

/// Production `AVAudioEngine` implementation of `MicrophoneAudioEngine`.
public final class AVAudioMicrophoneEngine: MicrophoneAudioEngine {
    private let engine = AVAudioEngine()

    public init() {}

    public var notificationObject: AnyObject? { engine }

    public func inputFormat() -> AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    public func installTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat, block: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void) {
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, time in
            block(buffer, time.isHostTimeValid ? time.hostTime : 0)
        }
    }

    public func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    public func start() throws {
        try engine.start()
    }

    public func stop() {
        engine.stop()
    }
}

/// Manages a microphone engine and recovers from `AVAudioEngineConfigurationChange`
/// (such as Bluetooth earbuds switching from music mode to headset mode or a mid-recording
/// input device switch) by removing the tap, reading the new format, reinstalling the tap,
/// and restarting the engine. Fails at most once, only if the restart fails.
@MainActor
public final class MicrophoneCaptureDriver {
    private let makeEngine: () -> any MicrophoneAudioEngine
    private let notificationCenter: NotificationCenter
    private var engine: (any MicrophoneAudioEngine)?
    private var observer: NSObjectProtocol?
    private var tapInstalled = false
    private var stopped = false
    private var hasFailed = false

    public init(
        makeEngine: @escaping () -> any MicrophoneAudioEngine = { AVAudioMicrophoneEngine() },
        notificationCenter: NotificationCenter = .default
    ) {
        self.makeEngine = makeEngine
        self.notificationCenter = notificationCenter
    }

    public func start(
        sink: RecordingSink,
        label: String,
        missingError: @escaping () -> Error,
        changedMessage: String,
        failure: @escaping @Sendable (String) -> Void
    ) throws {
        stop()
        stopped = false
        hasFailed = false

        let engine = makeEngine()
        self.engine = engine
        do {
            try installTapAndStart(engine: engine, sink: sink, label: label, invalidFormatError: missingError)
        } catch {
            stop()
            throw error
        }

        observer = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine.notificationObject,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange(
                    sink: sink,
                    label: label,
                    changedMessage: changedMessage,
                    failure: failure
                )
            }
        }
    }

    private func installTapAndStart(
        engine: any MicrophoneAudioEngine,
        sink: RecordingSink,
        label: String,
        invalidFormatError: () -> Error
    ) throws {
        let format = engine.inputFormat()
        guard format.sampleRate > 0, (1...64).contains(format.channelCount) else {
            throw invalidFormatError()
        }
        engine.installTap(bufferSize: 4096, format: format) { buffer, hostTime in
            sink.receive(buffer, hostTime: hostTime, id: "microphone", label: label, kind: "microphone")
        }
        tapInstalled = true
        try engine.start()
    }

    private func handleConfigurationChange(
        sink: RecordingSink,
        label: String,
        changedMessage: String,
        failure: @escaping @Sendable (String) -> Void
    ) {
        guard !stopped, !hasFailed, let engine else { return }
        if tapInstalled {
            engine.removeTap()
            tapInstalled = false
        }
        do {
            try installTapAndStart(
                engine: engine,
                sink: sink,
                label: label,
                invalidFormatError: { RecordingError.invalid(changedMessage) }
            )
        } catch {
            guard !stopped, !hasFailed else { return }
            hasFailed = true
            stop()
            failure(changedMessage)
        }
    }

    public func stop() {
        stopped = true
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        if let engine {
            engine.stop()
            if tapInstalled {
                engine.removeTap()
                tapInstalled = false
            }
            self.engine = nil
        }
    }
}
