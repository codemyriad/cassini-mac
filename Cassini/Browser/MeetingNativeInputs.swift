// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CassiniRecording
import CassiniBrowserControl

enum MeetingInputError: Error { case microphoneUnavailable, microphoneChanged, systemChanged }

/// One microphone input per meeting. An Others-only capture never creates this
/// object, requests its permission, or installs a microphone tap.
@MainActor final class MeetingMicrophoneInput: CaptureInput {
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var installed = false
    func authorize() async throws { try await NativeRecordingInputs().authorize() }
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws {
        let engine = AVAudioEngine(); self.engine = engine
        let input = engine.inputNode, format = input.outputFormat(forBus:0)
        guard format.sampleRate > 0, (1...64).contains(format.channelCount) else { throw MeetingInputError.microphoneUnavailable }
        let label = UXText.text("common.yourMicrophone")
        input.installTap(onBus:0,bufferSize:4096,format:format) { buffer,time in
            sink.receive(buffer,hostTime:time.isHostTimeValid ? time.hostTime : 0,id:"microphone",label:label,kind:"microphone")
        }
        installed = true
        try engine.start()
        observer = NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:engine,queue:.main) { _ in
            failure(String(describing:MeetingInputError.microphoneChanged))
        }
    }
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let engine {
            engine.stop()
            if installed { engine.inputNode.removeTap(onBus:0) }
        }
        installed = false; engine = nil
    }
}

/// This input has no microphone path. It is created only after browser loss
/// while Others remains selected; its failure cannot silently select Me.
@MainActor final class MeetingSystemInput: CaptureInput {
    private var tap: AudioProcessTap?
    func authorize() async throws {} // macOS owns the system-audio consent prompt.
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws {
        let tap = AudioProcessTap(); self.tap = tap
        let label = UXText.text("common.theOthers")
        _ = try tap.start(processes:nil,onFormatChange:{ failure(String(describing:MeetingInputError.systemChanged)) }) { buffer,host in
            sink.receive(buffer,hostTime:host,id:"output",label:label,kind:"system")
        }
    }
    func stop() { tap?.stop(); tap = nil }
}
