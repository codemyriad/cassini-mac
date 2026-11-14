// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniLibrary

/// The Mac currently separates browser sources, not mixed system/received audio.
/// Never enroll an undivided 'Me' or a mix and claim it is one person's voice.
public enum VoiceEnrollmentAudio {
    public struct Selection: Sendable {
        public let samples:[Float]
        public let clip:VoiceClip
    }
    private enum DecodeComplete: Error { case selected }
    public static func prepare(_ meeting:LibraryMeeting,speaker:String) throws -> Selection? {
        try prepare(meeting,speaker:speaker,decode:MeetingAudioDecoder.decode)
    }
    static func prepare(_ meeting:LibraryMeeting,speaker:String,decode:(URL,([Float],Int) throws -> Void) throws -> Void) throws -> Selection? {
        try Task.checkCancellation()
        guard meeting.state.origin == .own, speaker != "me", speaker != "others" else { return nil }
        let tracks=TranscriptSpeaker.assign(meeting.audioTracks,received:false).filter {
            (meeting.mergedInto[$0.speaker.id] ?? $0.speaker.id) == speaker &&
                $0.track.sourceKind == "remote"
        }.map(\.track).sorted { ($0.startOffsetMs ?? 0) < ($1.startOffsetMs ?? 0) }
        guard !tracks.isEmpty, tracks.allSatisfy({ $0.startOffsetMs != nil && $0.endOffsetMs != nil }),
              zip(tracks,tracks.dropFirst()).allSatisfy({ $0.endOffsetMs! <= $1.startOffsetMs! }) else { return nil }
        let duration=Int64(tracks.last!.endOffsetMs!)
        let windows=VoiceSelection.windows(speaker:speaker,words:meeting.transcriptItems.filter { $0.speaker == speaker },durationMs:duration)
        guard !windows.isEmpty else { return nil }
        var output:[Float]=[], longest:Range<Int64>?
        for track in tracks {
            let rate=Double(track.sampleRate ?? 48000), offset=track.startOffsetMs!
            var ranges:[Range<Int>]=[]
            for window in windows {
                let start=max(window.lowerBound,Int64(offset)), end=min(window.upperBound,Int64(track.endOffsetMs!))
                guard end-start >= 1500 else { continue }
                guard !(track.gaps ?? []).contains(where: { gap in
                    let a=offset+gap.atMs, b=a+(gap.frames.map { Double($0)*1000/rate } ?? gap.durationMs ?? 0)
                    return a < Double(end) && b > Double(start)
                }) else { continue }
                ranges.append(Int((Double(start)-offset)*16)..<Int((Double(end)-offset)*16))
                if longest == nil || end-start > longest!.upperBound-longest!.lowerBound { longest=start..<end }
            }
            guard !ranges.isEmpty else { continue }
            let expected=ranges.reduce(0) { $0+$1.count }, before=output.count
            var position=0, resampler:MeetingResampler?, current=0
            func append(_ pcm:[Float]) {
                while current < ranges.count, ranges[current].upperBound <= position { current += 1 }
                var index=current
                while index < ranges.count, ranges[index].lowerBound < position+pcm.count {
                    let lo=max(0,ranges[index].lowerBound-position), hi=min(pcm.count,ranges[index].upperBound-position)
                    if hi > lo { output.append(contentsOf:pcm[lo..<hi]) }
                    index += 1
                }
                position += pcm.count
            }
            do {
                try decode(track.url) { block, rate in
                    try Task.checkCancellation()
                    if resampler == nil { resampler=try MeetingResampler(rate:rate) }
                    append(resampler!.feed(block))
                    if position >= ranges.last!.upperBound { throw DecodeComplete.selected }
                }
            } catch DecodeComplete.selected {}
            if resampler != nil { append(resampler!.feed([],final:true)) }
            guard output.count-before == expected else { throw TranscriptionFailure.audioFormat }
        }
        guard output.count >= 64000, output.count <= 720000, let longest else { return nil }
        return .init(samples:output,clip:.init(meeting:meeting.folder.lastPathComponent,speaker:speaker,startMs:longest.lowerBound,endMs:longest.upperBound))
    }
}
