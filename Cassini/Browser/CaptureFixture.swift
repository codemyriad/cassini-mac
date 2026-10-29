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
    static var systemAllowed = true
    static var microphoneStarts = 0
    static var systemStarts = 0
}
/// Only the exact private app self-test can construct this driver. Release has
/// neither its entry point nor the factory branch. It never opens a device.
@MainActor final class CaptureFixtureInput: CaptureInput {
    let side: CaptureSide
    private var timer: Timer?
    private var sink: RecordingSink?
    init(_ side: CaptureSide) { self.side = side }
    func authorize() async throws {
        if side == .me && !CaptureFixture.microphoneAllowed { throw CocoaError(.fileReadNoPermission) }
    }
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws {
        if side == .others && !CaptureFixture.systemAllowed { throw CocoaError(.fileReadNoPermission) }
        self.sink = sink
        if side == .me { CaptureFixture.microphoneStarts += 1 } else { CaptureFixture.systemStarts += 1 }
        emit()
        timer = Timer.scheduledTimer(withTimeInterval:0.02,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.emit() } }
    }
    private func emit() {
        let format = AVAudioFormat(standardFormatWithSampleRate:8000,channels:1)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:160)!
        buffer.frameLength = 160
        for index in 0..<160 { buffer.floatChannelData![0][index] = side == .me ? 0.12 : 0.33 }
        sink?.receive(buffer,hostTime:AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime),id:side == .me ? "microphone" : "output",label:side == .me ? "Generated mic" : "Generated system",kind:side == .me ? "microphone" : "system")
    }
    func stop() { timer?.invalidate(); timer = nil; sink = nil }
}
#endif
