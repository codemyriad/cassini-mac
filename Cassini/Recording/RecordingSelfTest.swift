#if DEBUG
import AppKit
import AVFoundation
import CassiniRecording
import CoreAudio

/// Explicit developer diagnostic, absent from Release builds. Never opens a microphone.
/// Exercises the production sink and process tap with generated tones, then removes its files.
@MainActor
enum RecordingSelfTest {
    nonisolated static func log(_ message: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((message + "\n").utf8))
    }

    static func run(sinkOnly: Bool) async {
        log("RECORDING_SELF_TEST_PID: \(ProcessInfo.processInfo.processIdentifier)")
        // A permission dialog or blocked device start must not hold a nightly job forever.
        // This diagnostic process captures generated audio only and owns no user recording.
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            log("RECORDING_SELF_TEST_FAILED: Timed out waiting for audio consent or a usable output device.")
            exit(124)
        }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniCaptureCheck-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: parent) }
            try checkSink(parent: parent, interleaved: false)
            try checkSink(parent: parent, interleaved: true)
            log("PASS: native PCM sink preserves channels, format and frame count for planar and interleaved buffers")
            if !sinkOnly {
                try await checkTap(parent: parent)
                log("PASS: Core Audio process tap → production recording sink → stereo WAV with 440/880 Hz tones")
            }
            log("RECORDING_SELF_TEST_PASSED")
        } catch {
            log("RECORDING_SELF_TEST_FAILED: \(error.localizedDescription)")
        }
        NSApp.terminate(nil)
    }

    private static func tone(format: AVAudioFormat, seconds: Double, gain: Float = 0.05) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let frequency = channel == 0 ? 440.0 : 880.0
            for frame in 0..<Int(frames) {
                let pointer = buffer.floatChannelData![format.isInterleaved ? 0 : channel]
                let index = format.isInterleaved ? frame * Int(format.channelCount) + channel : frame
                pointer[index] = gain * Float(sin(2 * .pi * frequency * Double(frame) / format.sampleRate))
            }
        }
        return buffer
    }

    private static func checkSink(parent: URL, interleaved: Bool) throws {
        let session = try RecordingSession(parent: parent, title: "Synthetic native sink", source: "macos")
        let sink = RecordingSink(session: session) { message in log(message) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved)!
        let origin = AVAudioTime.hostTime(forSeconds: ProcessInfo.processInfo.systemUptime)
        for block in 0..<10 {
            sink.receive(tone(format: format, seconds: 0.1),
                         hostTime: origin + AVAudioTime.hostTime(forSeconds: Double(block) * 0.1),
                         id: "tone", label: "Synthetic 440/880", kind: "application")
        }
        try sink.finish(problem: nil)
        guard session.manifest.tracks.first?.frames == 48000 else {
            throw RecordingError.invalid("Native sink lost frames.")
        }
        try verifyTone(session)
    }

    private static func checkTap(parent: URL) async throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        defer { player.stop(); engine.stop() }

        // Translate this exact process; never capture the desktop mix or other applications.
        var pid = ProcessInfo.processInfo.processIdentifier
        var process: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try audioCheck(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                 UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process), "Locating synthetic audio process")
        guard process != 0 else { throw RecordingError.invalid("Synthetic audio process was not registered.") }
        let session = try RecordingSession(parent: parent, title: "Synthetic process tap", source: "macos")
        let sink = RecordingSink(session: session) { message in log(message) }
        let tap = AudioProcessTap()
        defer { tap.stop() }
        log("Starting synthetic process tap; macOS may request Cassini system-audio permission.")
        _ = try tap.start(processes: [process], onFormatChange: {}) { buffer, hostTime in
            sink.receive(buffer, hostTime: hostTime, id: "tone", label: "Synthetic 440/880", kind: "application")
        }
        player.scheduleBuffer(tone(format: format, seconds: 1), at: nil, options: .loops, completionHandler: nil)
        player.play()
        try await Task.sleep(for: .seconds(3))
        tap.stop()
        player.stop()
        try sink.finish(problem: nil)
        try verifyTone(session)
    }

    private static func verifyTone(_ session: RecordingSession) throws {
        guard let track = session.manifest.tracks.first else { throw RecordingError.invalid("No captured track.") }
        let file = try AVAudioFile(forReading: session.directory.appendingPathComponent(track.file))
        guard file.length > AVAudioFramePosition(file.processingFormat.sampleRate / 2), file.processingFormat.channelCount == 2,
              let audio = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw RecordingError.invalid("Captured WAV has an invalid length or channel count.")
        }
        try file.read(into: audio)
        let rate = audio.format.sampleRate
        // Ignore startup latency and take an interior window for spectral verification.
        let start = Int(audio.frameLength) / 3
        let count = min(Int(rate / 4), Int(audio.frameLength) - start)
        func power(channel: Int, frequency: Double) -> Double {
            var real = 0.0, imaginary = 0.0
            for i in 0..<count {
                let value = Double(audio.floatChannelData![channel][start + i])
                let phase = 2 * Double.pi * frequency * Double(i) / rate
                real += value * cos(phase); imaginary += value * sin(phase)
            }
            return (real * real + imaginary * imaginary) / Double(count * count)
        }
        for channel in 0..<2 {
            let expected = power(channel: channel, frequency: channel == 0 ? 440 : 880)
            let other = power(channel: channel, frequency: channel == 0 ? 880 : 440)
            log("Channel \(channel): expected power \(expected), other power \(other), frames \(audio.frameLength), rate \(rate)")
            guard expected > 0.000001, expected > other * 10 else {
                throw RecordingError.invalid("Captured channel \(channel) is silent or mixed incorrectly. Check system-audio permission and the current output device.")
            }
        }
    }
}
#endif
