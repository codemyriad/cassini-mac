// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CassiniRecording
import CassiniBrowserControl

enum MeetingInputError: Error { case microphoneUnavailable, microphoneChanged, systemChanged }

/// One microphone input per meeting. An Others-only capture never creates this
/// object, requests its permission, or installs a microphone tap.
@MainActor final class MeetingMicrophoneInput: CaptureInput {
    private let microphone = MicrophoneCaptureDriver()
    /// D58: only the OS denial is permissionDenied (no message); nothing is inferred from silence.
    func authorize() async throws {
        let permitted: Bool
        switch AVCaptureDevice.authorizationStatus(for:.audio) {
        case .authorized: permitted = true
        case .notDetermined: permitted = await AVCaptureDevice.requestAccess(for:.audio)
        default: permitted = false
        }
        guard permitted else { throw CaptureOpenRefusal.denied }
    }
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws {
        try microphone.start(
            sink: sink,
            label: UXText.text("common.yourMicrophone"),
            missingError: { MeetingInputError.microphoneUnavailable },
            changedMessage: String(describing: MeetingInputError.microphoneChanged),
            failure: failure
        )
    }
    func stop() {
        microphone.stop()
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
