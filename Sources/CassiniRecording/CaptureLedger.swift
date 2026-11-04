// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D52 M2 append-only browser source accounting, matching GNOME `CaptureRecord`
/// on the shared outcome vectors. Silence is received audio; padding is not.
/// A source failure is sticky. R69 `expected` turns true permanently once the
/// source is selected or bound to a recorded span.
public struct CaptureLedger: Sendable {
    public struct Discovered: Sendable, Equatable {
        public let sourceTrackId: String, kind: String, label: String?, failed: Bool
        public init(sourceTrackId: String, kind: String, label: String?, failed: Bool = false) {
            self.sourceTrackId = sourceTrackId; self.kind = kind; self.label = label; self.failed = failed
        }
    }
    struct Seen: Sendable { var kind: String, label: String, failed: Bool, expected: Bool }
    public static let discoverableKinds: Set<String> = ["local","remote","media","tab","application"]
    private(set) var seen: [String:Seen] = [:]
    private var order: [String] = []
    private var bindings: [String:String] = [:]
    public private(set) var ioFailed = false
    public init() {}

    public static func validIdentity(_ value: String?) -> Bool {
        guard let value else { return false }; return !value.isEmpty && value.utf8.count <= 200
    }
    public mutating func observe(_ identity: String, kind: String, label: String?, failed: Bool = false, expected: Bool) throws {
        guard Self.validIdentity(identity), Self.discoverableKinds.contains(kind) || ["microphone","system"].contains(kind),
              (label?.unicodeScalars.count ?? 0) <= 200 else { throw RecordingError.invalid("Invalid discovered audio source.") }
        if var known = seen[identity] {
            guard known.kind == kind else { throw RecordingError.invalid("Conflicting source kind.") }
            known.failed = known.failed || failed; known.expected = known.expected || expected
            seen[identity] = known
        } else {
            seen[identity] = .init(kind:kind,label:RecordingSession.cleanLabel(label ?? kind),failed:failed,expected:expected)
            order.append(identity)
        }
    }
    /// Validates the whole batch before changing the durable accounting.
    public mutating func discover(_ sources: [Discovered], expected: (String) -> Bool) throws {
        var proposed = self
        for source in sources {
            guard Self.discoverableKinds.contains(source.kind) else { throw RecordingError.invalid("Invalid discovered audio source kind.") }
            try proposed.observe(source.sourceTrackId,kind:source.kind,label:source.label,failed:source.failed,expected:expected(source.kind))
        }
        self = proposed
    }
    public func knows(_ identity: String) -> Bool { seen[identity] != nil }
    public func isFailed(_ identity: String) -> Bool { seen[identity]?.failed == true }
    /// A selection change makes every discovered source of that side expected.
    public mutating func select(expected: (String) -> Bool) {
        for identity in order where expected(seen[identity]!.kind) { seen[identity]!.expected = true }
    }
    /// A span is always bound to its source; it makes the source expected only when
    /// it records a selected side (a span opened while The others is off does not, R69).
    public mutating func bind(track: String, to identity: String, expected: Bool = true) {
        guard seen[identity] != nil else { return }
        bindings[track] = identity; seen[identity]!.expected = seen[identity]!.expected || expected
    }
    public func identity(ofTrack track: String) -> String? { bindings[track] }
    public mutating func markFailed(_ identity: String, io: Bool = false) {
        ioFailed = ioFailed || io
        seen[identity]?.failed = true
    }
    /// True when appending `frames` at `atMs` to span `id` would store audio that overlaps
    /// another stored span of the same source. The stored interval starts where the span's
    /// audio ends (any gap up to `atMs` is padded on disk), or at `atMs` for its first chunk.
    public func overlaps(_ manifest: RecordingManifest, track id: String, atMs: Double, frames: UInt64) -> Bool {
        guard let identity = bindings[id], let track = manifest.tracks.first(where:{ $0.id == id }) else { return false }
        let rate = Double(track.sampleRate)
        let start = track.startOffsetMs.map { $0 + Double(track.frames)*1000/rate } ?? atMs
        let end = max(start,atMs + Double(frames)*1000/rate)
        for other in manifest.tracks where other.id != id && bindings[other.id] == identity && other.frames > 0 {
            guard let previous = other.startOffsetMs else { continue }
            let previousEnd = previous + Double(other.frames)*1000/Double(other.sampleRate)
            if max(start,previous) < min(end,previousEnd) { return true }
        }
        return false
    }
    public struct Result: Sendable {
        public let outcome: SessionCaptureOutcome
        public let tracks: [String:CaptureOutcome]
        /// An expected source was not fully captured.
        public let incomplete: Bool
    }
    public func result(_ manifest: RecordingManifest) -> Result {
        var sources: [SessionCaptureOutcome.Source] = [], perTrack: [String:CaptureOutcome] = [:]
        for identity in order {
            let source = seen[identity]!
            let tracks = manifest.tracks.filter { bindings[$0.id] == identity }
            var duration = 0.0, failed = source.failed
            for track in tracks {
                let ms = Double(track.receivedFrames ?? 0)*1000/Double(track.sampleRate)
                duration += ms
                perTrack[track.id] = CaptureOutcome(failed:track.problemKind != nil,audioMs:ms)
                failed = failed || track.problemKind != nil
            }
            sources.append(.init(sourceTrackId:identity,kind:source.kind,label:source.label,captureOutcome:CaptureOutcome(failed:failed,audioMs:duration),
                                 audioMs:duration,trackIds:tracks.map(\.id),captureExpected:source.expected ? nil : false))
        }
        return .init(outcome:.init(sources:sources),tracks:perTrack,incomplete:sources.contains { $0.expected && $0.captureOutcome != .captured })
    }
}
