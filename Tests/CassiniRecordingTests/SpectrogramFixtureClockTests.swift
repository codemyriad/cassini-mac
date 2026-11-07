// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing
@testable import CassiniRecording

private final class SpectrogramClockWriter: RecordingSinkWriter, @unchecked Sendable {
    var recordingProblem: String? { nil }
    func addTrack(id: String, label: String, kind: String, sampleRate: Int, channels: Int) throws {}
    func appendNative(id: String, pcm: Data, offsetMs: Double) throws {}
    func finish(problem: String?) throws {}
}
@Suite struct SpectrogramFixtureClockTests {
    @Test(arguments:[true,false]) func delayedCallbacksPreserveOnlyTheDeliberateOmission(_ negativeControl: Bool) throws {
        let chunk = 4096, clock = SpectrogramFixtureClock(chunk:4096)
        let origin = AVAudioTime.hostTime(forSeconds:10)
        let sink = RecordingSink(session:SpectrogramClockWriter(),originHostTime:origin,onFailure:{ _ in })
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate:48000,channels:1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096))
        buffer.frameLength = 4096
        buffer.floatChannelData![0].initialize(repeating:0,count:chunk)
        var frames = 0, skipped = 0, deliberatelyOmitted = 0
        let wakeups = [12] + Array(13...100) + [122] + Array(123...200)
        for complete in wakeups {
            if negativeControl, complete-frames/chunk > 10 {
                // Exact old producer policy, not a modified recorder expectation.
                let resumed = (complete-10)*chunk
                skipped += resumed-frames; frames = resumed
            }
            let elapsed = Double(complete*chunk)/48000 + 1e-9
            while frames < complete*chunk {
                let end = clock.batchEnd(after:frames,at:elapsed)
                #expect(end > frames && end-frames <= chunk*10)
                while frames < end {
                    let host = origin + AVAudioTime.hostTime(forSeconds:Double(frames)/48000)
                    sink.receive(buffer,hostTime:host,id:"mic",label:"Mic",kind:"microphone")
                    if (150..<174).contains(frames/chunk) { deliberatelyOmitted += chunk }
                    else { sink.receive(buffer,hostTime:host,id:"system",label:"System",kind:"system") }
                    frames += chunk
                }
                sink.flush() // Event boundary: no artificial writer backlog in this source-clock test.
            }
        }
        let actual = sink.status()
        #expect(deliberatelyOmitted == 98304)
        #expect(actual.droppedMs == 0)
        #expect(skipped == (negativeControl ? 57344 : 0))
        #expect(actual.gapMs == (negativeControl ? 4096 : 2048))
        try sink.finish(problem:nil)
    }
}
