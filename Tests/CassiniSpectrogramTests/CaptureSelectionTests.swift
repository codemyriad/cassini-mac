// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import CassiniSpectrogram

@Suite struct CaptureSelectionTests {
    @Test func longMeetingHistoryKeepsEveryVisibleRasterDecisionWithBoundedStorage() {
        let events = (0..<100_000).map { index in
            SpectrogramCaptureSelection.Transition(atMs:Double(index)*0.1,me:index%3 != 0,others:index%7 != 0)
        }
        var selection = SpectrogramCaptureSelection()
        selection.update(events,nowMs:10_000)
        #expect(selection.retainedTransitions <= 314 && selection.storageBytes <= 8192)
        for slot in 188...500 {
            let expected = events.last { $0.atMs <= Double(slot)*20 }
            #expect(selection.selected(.me,slot:Int64(slot)) == (expected?.me ?? true))
            #expect(selection.selected(.others,slot:Int64(slot)) == (expected?.others ?? true))
        }
        selection.update(events,nowMs:1_000_000)
        #expect(selection.retainedTransitions == 1)
        #expect(selection.selected(.me,slot:50_000) == events.last!.me)
    }
    @Test func fractionalAndRepeatedBoundariesKeepTheLastAuthoritativeChoice() {
        var selection = SpectrogramCaptureSelection(me:true,others:false)
        selection.update([
            .init(atMs:20,me:false,others:true),
            .init(atMs:20.001,me:true,others:false),
            .init(atMs:39.999,me:false,others:false),
            .init(atMs:40,me:true,others:true)
        ],nowMs:100)
        #expect(selection.selected(.me,slot:0) && !selection.selected(.others,slot:0))
        #expect(!selection.selected(.me,slot:1) && selection.selected(.others,slot:1))
        #expect(selection.selected(.me,slot:2) && selection.selected(.others,slot:2))
    }
    @Test func futureAndMalformedEventsCannotGrowOrPrematurelyChangeThePicture() {
        var selection = SpectrogramCaptureSelection(me:false,others:true)
        selection.update((0..<10_000).lazy.map {
            .init(atMs:1_000_000+Double($0)*20,me:true,others:false)
        },nowMs:100)
        #expect(selection.retainedTransitions == 401 && selection.storageBytes <= 8192)
        #expect(!selection.selected(.me,slot:5) && selection.selected(.others,slot:5))
        selection.update([.init(atMs:.nan,me:true,others:false),.init(atMs:-1,me:true,others:false)],nowMs:100)
        #expect(selection.retainedTransitions == 1 && !selection.selected(.me,slot:5))
    }
}
