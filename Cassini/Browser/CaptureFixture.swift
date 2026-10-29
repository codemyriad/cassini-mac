// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import Foundation
import AVFoundation
import CassiniRecording
import CassiniBrowserControl

@MainActor enum CaptureFixture {
    nonisolated static var enabled: Bool {
        RecordingFixture.enabled && RecordingFixture.root != nil && CommandLine.arguments.contains("--browser-capture-self-test")
    }
    static var microphoneAllowed = true
    static var microphoneStartsAllowed = true
    static var silentMicrophone = false
    static var microphoneDC: Float = 0
    static var systemAllowed = true
    static var systemBuffersAllowed = true
    static var microphoneStarts = 0
    static var systemStarts = 0
}
/// Only the exact private app self-test can construct this driver. Release has
/// neither its entry point nor the factory branch. It never opens a device.
@MainActor final class CaptureFixtureInput: CaptureInput {
    let side: CaptureSide
    private var timer: Timer?
    private var sink: RecordingSink?
    private var origin: UInt64 = 0
    private var frames: UInt64 = 0
    init(_ side: CaptureSide) { self.side = side }
    func authorize() async throws {
        if side == .me && !CaptureFixture.microphoneAllowed { throw CocoaError(.fileReadNoPermission) }
    }
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws {
        if side == .me && !CaptureFixture.microphoneStartsAllowed { throw CocoaError(.fileReadUnknown) }
        if side == .others && !CaptureFixture.systemAllowed { throw CocoaError(.fileReadNoPermission) }
        self.sink = sink
        origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime); frames = 0
        if side == .me { CaptureFixture.microphoneStarts += 1 } else { CaptureFixture.systemStarts += 1 }
        emit()
        timer = Timer.scheduledTimer(withTimeInterval:0.02,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.emit() } }
    }
    private func emit() {
        guard side != .others || CaptureFixture.systemBuffersAllowed else { return }
        if frames == 0 { origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime) }
        let format = AVAudioFormat(standardFormatWithSampleRate:8000,channels:1)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:160)!
        buffer.frameLength = 160
        for index in 0..<160 {
            let phase = Double(frames + UInt64(index))/8000 * 2 * Double.pi
            buffer.floatChannelData![0][index] = side == .me
                ? (CaptureFixture.silentMicrophone ? 0 : Float(sin(440*phase))*0.12) + CaptureFixture.microphoneDC
                : Float(sin(880*phase))*0.33
        }
        // Input stamps follow the generated source frames, not timer delivery.
        sink?.receive(buffer,hostTime:origin + AVAudioTime.hostTime(forSeconds:Double(frames)/8000),id:side == .me ? "microphone" : "output",label:side == .me ? "Generated mic" : "Generated system",kind:side == .me ? "microphone" : "system")
        frames += 160
    }
    func stop() { timer?.invalidate(); timer = nil; sink = nil }
}
#endif
