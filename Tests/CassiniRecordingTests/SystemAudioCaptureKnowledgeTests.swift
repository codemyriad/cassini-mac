// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AVFoundation
import Testing
@testable import CassiniRecording

@Suite struct SystemAudioCaptureKnowledgeTests {
    @Test(arguments:[false,true]) func onlyFiniteNonzeroAudioProvidesEvidence(interleaved: Bool) throws {
        let name = "io.codemyriad.cassini.system-knowledge-test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        let state = SystemAudioCaptureKnowledge(defaults:defaults), attempt = state.beginAttempt()
        let format = try #require(AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48000,channels:2,interleaved:interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4)); buffer.frameLength = 4
        for channel in 0..<2 { for frame in 0..<4 {
            buffer.floatChannelData![interleaved ? 0 : channel][interleaved ? frame*2+channel : frame] = frame == 0 ? .nan : frame == 1 ? .infinity : 0
        } }
        #expect(!state.receive(buffer,attempt:attempt)); #expect(!state.previouslyCaptured)
        buffer.floatChannelData![interleaved ? 0 : 1][interleaved ? 7 : 3] = -Float.leastNonzeroMagnitude
        #expect(state.receive(buffer,attempt:attempt)); #expect(state.previouslyCaptured)
        state.flush()
    }
    @Test func knowledgeRequiresRealEvidenceAndSurvivesRelaunch() throws {
        let name = "io.codemyriad.cassini.system-knowledge-test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        let state = SystemAudioCaptureKnowledge(defaults:defaults)
        #expect(!state.previouslyCaptured)
        let attempt = state.beginAttempt() // starting or silence alone proves nothing
        #expect(!state.previouslyCaptured)
        state.receivedNonzero(attempt:attempt)
        #expect(state.previouslyCaptured)
        _ = state.beginAttempt()
        #expect(state.previouslyCaptured) // a new start alone does not revoke prior knowledge
        state.flush()
        #expect(SystemAudioCaptureKnowledge(defaults:defaults).previouslyCaptured)
        state.failedStart()
        #expect(!state.previouslyCaptured)
        state.flush()
        #expect(!SystemAudioCaptureKnowledge(defaults:defaults).previouslyCaptured)
    }
    @Test func failedStartInvalidatesDelayedEvidenceFromOlderConcurrentCaptures() throws {
        let name = "io.codemyriad.cassini.system-knowledge-test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        let state = SystemAudioCaptureKnowledge(defaults:defaults)
        let old = state.beginAttempt()
        state.failedStart()
        state.receivedNonzero(attempt:old)
        #expect(!state.previouslyCaptured)
        state.receivedNonzero(attempt:state.beginAttempt())
        #expect(state.previouslyCaptured)
        state.failedStart(); state.flush()
        #expect(!SystemAudioCaptureKnowledge(defaults:defaults).previouslyCaptured)
    }
}
