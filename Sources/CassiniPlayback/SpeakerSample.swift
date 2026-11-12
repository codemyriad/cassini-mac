// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import CassiniLibrary

/// D24 sample: one precise span, restoring the previous position paused.
@MainActor @Observable public final class SpeakerSample {
    public private(set) var active=false
    @ObservationIgnored private let playback:SessionPlayback
    @ObservationIgnored private var restore:(LibraryMeeting,Double)?
    public init(playback:SessionPlayback) {self.playback=playback}
    @discardableResult public func play(_ meeting:LibraryMeeting,range:Range<Int64>) -> Bool {
        guard meeting.canPlaySession,!range.isEmpty else {return false}
        cancel()
        let position=playback.playheadMs
        playback.pause();playback.clearSpan()
        restore=(meeting,position);active=true
        let accepted=playback.play(meeting,fromMs:Double(range.lowerBound),untilMs:Double(min(range.upperBound,range.lowerBound+10_000))) { [weak self] in self?.cancel() }
        if !accepted {cancel()}
        return accepted
    }
    public func cancel() {
        guard let (meeting,position)=restore else {return}
        restore=nil;active=false
        playback.pause();playback.clearSpan()
        playback.seek(meeting,toMs:position)
    }
}
