// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D70's hover index, built once with transcript preparation, after speaker merges.
/// Word intervals preserve silence even inside a long single-speaker run. In an
/// overlap the most recently started word wins; ending an aside restores its host.
public struct TimelineReadout: Equatable, Sendable {
    private struct Segment: Equatable, Sendable {
        let start: Int64
        let end: Int64
        let speaker: String
    }
    private let segments: [Segment]
    public init(items: [LibraryTranscriptItem] = []) {
        struct Event { let time: Int64; let index: Int; let entering: Bool }
        var events: [Event] = []
        for (index,item) in items.enumerated() where item.startMs >= 0 && item.endMs > item.startMs {
            events.append(.init(time:item.startMs,index:index,entering:true))
            events.append(.init(time:item.endMs,index:index,entering:false))
        }
        events.sort { $0.time < $1.time }
        var active: Set<Int> = [], result: [Segment] = [], at = 0
        while at < events.count {
            let start = events[at].time
            repeat {
                let event = events[at]
                if event.entering { active.insert(event.index) } else { active.remove(event.index) }
                at += 1
            } while at < events.count && events[at].time == start
            guard at < events.count, let chosen = active.max(by: {
                items[$0].startMs == items[$1].startMs ? $0 < $1 : items[$0].startMs < items[$1].startMs
            }) else { continue }
            let end = events[at].time, speaker = items[chosen].speaker
            if let last = result.last, last.end == start, last.speaker == speaker {
                result[result.count-1] = .init(start:last.start,end:end,speaker:speaker)
            } else { result.append(.init(start:start,end:end,speaker:speaker)) }
        }
        segments = result
    }
    public func speaker(at position: Double) -> String? {
        guard position.isFinite, position >= 0 else { return nil }
        var low = 0, high = segments.count
        while low < high {
            let mid = low+(high-low)/2
            if Double(segments[mid].start) <= position { low = mid+1 } else { high = mid }
        }
        guard low > 0, position < Double(segments[low-1].end) else { return nil }
        return segments[low-1].speaker
    }
}

/// Exact turn starts remain separate from the combined visual marks. Geometry
/// uses the native knob's travel, shared by hit testing, hover and Canvas drawing.
public struct ListeningTimeline: Equatable, Sendable {
    public let starts: [Double]
    public init(turns: [SpeakerTurn] = []) { starts = turns.map { Double($0.startMs) }.sorted() }
    public struct Track: Equatable, Sendable {
        public let minX: Double
        public let width: Double
        public init(minX: Double, width: Double) { self.minX = minX; self.width = max(0,width) }
        public func x(at position: Double, duration: Double) -> Double {
            minX + (duration > 0 ? min(1,max(0,position/duration)) : 0)*width
        }
        public func position(at x: Double, duration: Double) -> Double {
            width > 0 ? min(1,max(0,(x-minX)/width))*max(0,duration) : 0
        }
    }
    public func snapped(_ position: Double, duration: Double, track: Track) -> Double {
        guard duration > 0, track.width > 0, position.isFinite else { return position }
        var low = 0, high = starts.count
        while low < high {
            let mid = low+(high-low)/2
            if starts[mid] < position { low = mid+1 } else { high = mid }
        }
        let candidates = [low-1,low].filter { starts.indices.contains($0) && starts[$0] <= duration }
        guard let nearest = candidates.min(by: { abs(starts[$0]-position) < abs(starts[$1]-position) }),
              abs(track.x(at:starts[nearest],duration:duration)-track.x(at:position,duration:duration)) <= 6+1e-9 else { return position }
        return starts[nearest]
    }
    /// Marks closer than 3 pt combine visually, without affecting exact snapping/stepping.
    public func marks(duration: Double, track: Track) -> [Double] {
        guard duration > 0, track.width > 0 else { return [] }
        var result: [Double] = []
        for start in starts where start >= 0 && start <= duration {
            let x = track.x(at:start,duration:duration)
            if result.last.map({ x-$0 >= 3 }) ?? true { result.append(x) }
        }
        return result
    }
}
