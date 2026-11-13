// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniLibrary

struct TranscribingPresentationTests {
    private func presentation(_ state: MeetingState, readOnly: Bool = false,
                              language: CassiniLanguage = .en) -> TranscribingPresentation {
        .init(state:state, readOnly:readOnly, wordCount:1234, durationMs:120_000,
              language:language, locale:Locale(identifier:"en_GB"))
    }
    @Test func activeStatesAndReadOnlyControlsRespectLifecycle() {
        for transcript in [TranscriptStatus.queued, .running] {
            let state = MeetingState(transcript:transcript)
            #expect(presentation(state).isActive)
            #expect(presentation(state).canStop)
            #expect(!presentation(state,readOnly:true).canStop)
            for lifecycle in [MeetingLifecycle.recording, .saving] {
                #expect(!presentation(.init(lifecycle:lifecycle,transcript:transcript)).isActive)
            }
        }
        for transcript in [TranscriptStatus.none, .done, .failed, .damaged] {
            #expect(!presentation(.init(transcript:transcript)).isActive)
            #expect(!presentation(.init(transcript:transcript)).canStop)
        }
    }
    @Test func etaUsesStatusLineCopyAndKeepsProvisionalFallbacks() {
        #expect(presentation(.init(transcript:.running,etaMinutes:4)).status == "Transcribing · about 4 min left")
        #expect(presentation(.init(transcript:.running,etaMinutes:1)).timeLeft == "About 1 min")
        #expect(presentation(.init(transcript:.running,etaMinutes:0)).status == "Transcribing, less than a minute left")
        for eta: Int64? in [nil, -1] {
            let value = presentation(.init(transcript:.running,etaMinutes:eta))
            #expect(value.status == "Transcribing…")
            #expect(value.timeLeft == "—")
        }
    }
    @Test func missingTelemetryDoesNotInventPercentagesOrBatteryEstimates() {
        let value = presentation(.init(transcript:.running))
        #expect(value.wordsSoFar == "1,234")
        #expect(value.audioDone == "— of 00:02:00")
        #expect(value.batteryAtFinish == "—")
        let unknown = TranscribingPresentation(state:.init(transcript:.queued),readOnly:false,
                                               wordCount:0,durationMs:nil)
        #expect(unknown.audioDone == "—")
    }
    @Test func statusAndDetailsUseEveryCatalogLanguage() {
        for language in CassiniLanguage.allCases {
            let value = presentation(.init(transcript:.running,etaMinutes:4),language:language)
            #expect(!value.status.contains("{"))
            #expect(!value.timeLeft.contains("{"))
            if language != .en { #expect(value.status != "Transcribing · about 4 min left") }
            for step in TranscribingPresentation.steps {
                let key = step
                #expect(LibraryLocalization.shared.text(key,language:language) != key)
            }
        }
    }
    @Test func batteryProjectionRequiresRealSystemInputsAndClampsAtEmpty() {
        #expect(TranscribingPresentation.batteryAtFinish(etaMinutes:15,chargePercent:80,secondsRemaining:3600) == 60)
        #expect(TranscribingPresentation.batteryAtFinish(etaMinutes:90,chargePercent:80,secondsRemaining:3600) == 0)
        #expect(TranscribingPresentation.batteryAtFinish(etaMinutes:Int64.max,chargePercent:80,secondsRemaining:1) == 0)
        #expect(TranscribingPresentation.batteryAtFinish(etaMinutes:nil,chargePercent:80,secondsRemaining:3600) == nil)
        #expect(TranscribingPresentation.batteryAtFinish(etaMinutes:1,chargePercent:nil,secondsRemaining:3600) == nil)
        for remaining in [-1.0, 0, .infinity, .nan] {
            #expect(TranscribingPresentation.batteryAtFinish(etaMinutes:1,chargePercent:80,secondsRemaining:remaining) == nil)
        }
        let value = TranscribingPresentation(state:.init(transcript:.running),readOnly:false,wordCount:0,
                                            durationMs:nil,batteryPercentAtFinish:60,language:.en)
        #expect(value.batteryAtFinish == "About 60%")
    }
}
