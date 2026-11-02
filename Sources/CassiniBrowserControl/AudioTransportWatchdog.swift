// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D52.4/D52.5 PCM_STALE_AFTER for one audio transport (SPEC.md "Audio transport
/// liveness"). Every audio-transport frame counts; control frames never reach it. It is
/// armed only while an open span (declared by `track`, not yet ended by `trackEnd` or
/// `stop`) has delivered PCM, and the transport is stale exactly when armed and
/// `now - lastFrame >= 45 s`. A frame arriving at or after that deadline is too late.
///
/// D57: a span whose document is gone never arms it. The recording's control status
/// reports its tab's pageState and documentGeneration (`document`, never activity):
/// navigating retires every open span and opens a departing window in which declared
/// spans are retired; the window closes on present or on a different generation. A new
/// generation retires the spans declared up to the last status that reported the old one.
public struct AudioTransportWatchdog: Sendable {
    public static let staleAfter: UInt64 = 45_000
    /// `generation`: D61, the documentGeneration the extension stamped on the span's track.
    public enum Frame: Sendable { case track(String,generation: String? = nil), audio(String), trackEnd(String), stop, other }
    private var open: Set<String> = [], delivered: Set<String> = [], last: UInt64?
    private var declared: [String] = [], generation: String?, confirmed = 0, departing = false
    /// D61: open spans that carry a documentGeneration (bytes, compared for equality only),
    /// and the generations seen leave. None ever leaves the set.
    private var documents: [String:Data] = [:], departed: Set<Data> = []
    public init() {}
    /// Spans without a generation follow D57's declaration order; one with a generation is
    /// dormant exactly while that generation has departed, checked at every evaluation.
    public var armed: Bool { !open.isDisjoint(with:delivered) || documents.contains { delivered.contains($0.key) && !departed.contains($0.value) } }
    public func isStale(at now: UInt64) -> Bool {
        guard let last, armed, now >= last else { return false }
        return now - last >= Self.staleAfter
    }
    /// Records a status's page state and documentGeneration (either may be absent); false
    /// when it arrived too late. It never counts as activity.
    public mutating func document(page: BrowserCallLifecycle.Page?, generation reported: String?, at now: UInt64) -> Bool {
        if isStale(at:now) { return false }
        let changed = reported.map { new in generation.map { Data($0.utf8) != Data(new.utf8) } ?? true } ?? false
        if changed, let old = generation, let reported {
            // D61: the old document departs, and so does every open span's other than the new one.
            open.subtract(declared.prefix(confirmed))
            departed.insert(Data(old.utf8)); departed.formUnion(documents.values.filter { $0 != Data(reported.utf8) })
        }
        if let reported { generation = reported; confirmed = declared.count }
        if page == .navigating {
            // D61: navigating departs the current document and every open span's.
            if let generation { departed.insert(Data(generation.utf8)) }
            departed.formUnion(documents.values)
            open.removeAll(); departing = true
        }
        else if page == .present || changed { departing = false }
        return true
    }
    /// Records a frame; false when it arrived too late (the transport was already stale).
    /// A frame and its accepted span transition together, as the shared vectors model them.
    public mutating func receive(_ frame: Frame, at now: UInt64) -> Bool {
        guard activity(at:now) else { return false }
        apply(frame); return true
    }
    /// Any frame on the transport is activity, accepted or refused; false when it arrived too
    /// late (the transport was already stale).
    public mutating func activity(at now: UInt64) -> Bool {
        if isStale(at:now) { return false }
        last = now; return true
    }
    /// The span transition of a frame the host accepted. A refused frame changes no span.
    public mutating func apply(_ frame: Frame) {
        switch frame {
        // A generation that is not 1 to 200 UTF-8 bytes counts as absent.
        case .track(let id, let generation?) where (1...200).contains(generation.utf8.count): documents[id] = Data(generation.utf8)
        case .track(let id,_): declared.append(id); if !departing { open.insert(id) }
        case .audio(let id): if open.contains(id) || documents[id] != nil { delivered.insert(id) }
        case .trackEnd(let id): open.remove(id); documents.removeValue(forKey:id)
        case .stop: open.removeAll(); documents.removeAll()
        case .other: break
        }
    }
    /// A span the host retired on a terminal refusal: the owner closed it and the extension
    /// fences its later packets, so it never arms the watchdog again.
    public mutating func retire(_ id: String) { open.remove(id); delivered.remove(id) }
}
