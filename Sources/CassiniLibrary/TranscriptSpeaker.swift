// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

/// A transcript speaker as the write-down assigns it to a track (D11, R64). Readers derive the
/// same ids from the same tracks, so a speaker's gap ranges (D63 #2) are the ones its words
/// were written from.
public struct TranscriptSpeaker: Sendable {
    public let id: String
    public let name: String?
    public init(id: String, name: String?) { self.id = id; self.name = name }
    public static func fromTrack(id: String, kind: String, sourceTrackID: String? = nil, received: Bool = false, me: String = "Me", others: String = "The others") -> Self {
        if received { return .init(id: "track-original", name: nil) }
        if ["microphone", "local"].contains(kind) { return .init(id: "me", name: me) }
        if kind == "system" { return .init(id: "others", name: others) }
        let identity = sourceTrackID ?? id
        let safe = !identity.isEmpty && identity.utf8.count <= 195 && identity.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,95].contains($0)
        }
        let suffix = safe ? identity : "opaque-" + SHA256.hash(data:Data(identity.utf8)).map { String(format:"%02x",$0) }.joined()
        return .init(id: "track-" + suffix, name: nil)
    }
    /// A track's id as the write-down names it: its source id, else its file name.
    public static func trackID(_ track: LibraryAudioTrack) -> String {
        track.sourceID ?? String(track.url.deletingPathExtension().lastPathComponent.dropFirst("track-".count))
    }
    /// D52 M1: every track with frames, with its speaker. One source is one speaker only while its
    /// spans are disjoint; an overlapping span takes an R64 lane (`base:overlap:n`). A received
    /// meeting is one original track.
    public static func assign(_ tracks: [LibraryAudioTrack], received: Bool, me: String = "Me", others: String = "The others") -> [(track: LibraryAudioTrack, speaker: TranscriptSpeaker)] {
        let counted = tracks.filter { $0.frameCount != 0 }
        let lanes = received ? [:] : SourceSpanLanes.assign(counted.compactMap { track in
            let id = trackID(track)
            let base = fromTrack(id:id,kind:track.sourceKind ?? "media",sourceTrackID:track.sourceTrackID,me:me,others:others).id
            guard base.hasPrefix("track-") else { return nil }
            let offset = track.startOffsetMs
            return .init(id:id,base:base,startMs:offset,endMs:offset == nil ? nil : track.endOffsetMs,frames:track.frameCount,sampleRate:track.sampleRate)
        })
        return counted.map { track in
            let id = trackID(track)
            var speaker = fromTrack(id:id,kind:track.sourceKind ?? "media",sourceTrackID:track.sourceTrackID,received:received,me:me,others:others)
            if let lane = lanes[id] { speaker = .init(id:lane,name:speaker.name) }
            return (track,speaker)
        }
    }
}

/// D63 #2: a turn never spans a gap range of its own track. A speaker's gap ranges are the
/// non-overflow, non-empty gap ranges of its tracks (prefix included), as half-open 16 kHz session
/// sample ranges [G0, G1) with the presence conversion. Turn grouping stays presentation (D47).
public enum SpeakerGapRanges {
    public typealias Ranges = [String:[Range<Int64>]]
    public static func of(_ tracks: [LibraryAudioTrack], received: Bool) -> Ranges {
        guard !received else { return [:] }
        var result: Ranges = [:]
        for (track,speaker) in TranscriptSpeaker.assign(tracks,received:false) {
            let rate = Double(track.sampleRate ?? 48000)
            let windows = (track.gaps ?? []).compactMap { gap -> TrackPresence.Window? in
                guard gap.kind != "overflow" else { return nil }
                let length = gap.frames.map { Double($0)*1000/rate } ?? gap.durationMs ?? 0
                return length > 0 ? (gap.atMs,gap.atMs + length) : nil
            }
            let ranges = TrackPresence.samples16k(windows).map { Int64($0.lowerBound)..<Int64($0.upperBound) }
            if !ranges.isEmpty { result[speaker.id,default:[]] += ranges }
        }
        return result
    }
    /// A word's midpoint M = 8 × (startMs + endMs), in 16 kHz session samples.
    public static func midpoint(_ item: LibraryTranscriptItem) -> Int64 { 8 * (item.startMs + item.endMs) }
    /// Two consecutive words of one speaker are in different turns when one of its gap ranges lies
    /// between their midpoints: G0 < max(M1, M2) and min(M1, M2) < G1.
    public static func splits(_ first: LibraryTranscriptItem, _ second: LibraryTranscriptItem, _ ranges: Ranges) -> Bool {
        guard first.speaker == second.speaker, let own = ranges[first.speaker] else { return false }
        let a = midpoint(first), b = midpoint(second)
        return own.contains { $0.lowerBound < $0.upperBound && $0.lowerBound < max(a,b) && min(a,b) < $0.upperBound }
    }
}
