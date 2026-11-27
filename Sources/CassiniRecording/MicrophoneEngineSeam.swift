// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Minimal protocol over `AVAudioEngine` input capture so tests can drive
/// configuration-change handling deterministically without audio hardware.
public protocol MicrophoneAudioEngine: AnyObject {
    var inputFormat: AVAudioFormat { get }
    var notificationObject: AnyObject { get }
    func installInputTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    )
    func removeInputTap()
    func start() throws
    func stop()
}

/// Production `AVAudioEngine` adapter for `MicrophoneAudioEngine`.
public final class AVAudioMicrophoneEngine: MicrophoneAudioEngine {
    private let engine = AVAudioEngine()
    public init() {}
    public var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }
    public var notificationObject: AnyObject { engine }
    public func installInputTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: handler)
    }
    public func removeInputTap() {
        engine.inputNode.removeTap(onBus: 0)
    }
    public func start() throws {
        try engine.start()
    }
    public func stop() {
        engine.stop()
    }
}

/// Drives microphone capture from a `MicrophoneAudioEngine` into a `RecordingSink`.
@MainActor public final class MicrophoneInputDriver {
    private let makeEngine: () -> any MicrophoneAudioEngine
    private let notificationCenter: NotificationCenter
    private let micMissingMessage: String
    private let micChangedMessage: String
    private var engine: (any MicrophoneAudioEngine)?
    private var observer: NSObjectProtocol?

    /// Invoked on the main actor after a configuration-change notification has been
    /// handled (recovery finished or `failure` reported), allowing deterministic
    /// synchronization in tests without fixed sleeps.
    public var onConfigurationChangeHandled: (@MainActor () -> Void)?

    public init(
        makeEngine: @escaping () -> any MicrophoneAudioEngine = { AVAudioMicrophoneEngine() },
        notificationCenter: NotificationCenter = .default,
        micMissingMessage: String = "No microphone is available.",
        micChangedMessage: String = "The microphone changed."
    ) {
        self.makeEngine = makeEngine
        self.notificationCenter = notificationCenter
        self.micMissingMessage = micMissingMessage
        self.micChangedMessage = micChangedMessage
    }

    public func start(
        sink: RecordingSink,
        micLabel: String,
        failure: @escaping @Sendable (String) -> Void
    ) throws {
        let engine = makeEngine()
        self.engine = engine
        let format = engine.inputFormat
        guard format.sampleRate > 0, (1...64).contains(format.channelCount) else {
            throw RecordingError.invalid(micMissingMessage)
        }
        engine.installInputTap(bufferSize: 4096, format: format) { buffer, time in
            sink.receive(
                buffer,
                hostTime: time.isHostTimeValid ? time.hostTime : 0,
                id: "microphone",
                label: micLabel,
                kind: "microphone"
            )
        }
        try engine.start()
        let changedMessage = micChangedMessage
        observer = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine.notificationObject,
            queue: .main
        ) { [weak self] _ in
            failure(changedMessage)
            MainActor.assumeIsolated {
                self?.onConfigurationChangeHandled?()
            }
        }
    }

    public func stop() {
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        if let engine {
            engine.stop()
            engine.removeInputTap()
            self.engine = nil
        }
    }
}
