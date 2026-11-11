// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

public enum MeetingLifecycle: String, Codable, Sendable { case recording, saving, saved }
public enum MeetingOrigin: String, Codable, Sendable { case own, received }
public enum TranscriptStatus: String, Codable, Sendable { case none, queued, running, done, failed, damaged }
public struct MeetingIssue: Codable, Equatable, Sendable {
    public var id: String
    public var action: String?
    public init(id: String, action: String? = nil) { self.id = id; self.action = action }
}
public struct MeetingBadge: Codable, Equatable, Sendable {
    public var kind: String
    public var text: String
    public var tint: String
    public var dot: Bool?
}
/// HARMONY §3. This is derived state, not a second recording manifest.
public struct MeetingState: Codable, Equatable, Sendable {
    public var lifecycle: MeetingLifecycle
    public var origin: MeetingOrigin
    public var interruptedAtMs: Int64?
    public var transcript: TranscriptStatus
    public var etaMinutes: Int64?
    public var error: MeetingIssue?
    public var liveMs: Int64?
    /// nil for isolated badge vectors; the scanner always supplies audio availability (R9).
    public var audioAvailable: Bool?
    public init(lifecycle: MeetingLifecycle = .saved, origin: MeetingOrigin = .own,
                interruptedAtMs: Int64? = nil, transcript: TranscriptStatus = .none,
                etaMinutes: Int64? = nil, error: MeetingIssue? = nil, liveMs: Int64? = nil, audioAvailable: Bool? = nil) {
        self.lifecycle = lifecycle; self.origin = origin; self.interruptedAtMs = interruptedAtMs
        self.transcript = transcript; self.etaMinutes = etaMinutes; self.error = error; self.liveMs = liveMs; self.audioAvailable = audioAvailable
    }
    public var badge: MeetingBadge? {
        if lifecycle == .recording { return .init(kind: "recording", text: LibraryLocalization.shared.text("states.badge.recording",["liveBadge":LibraryFormat.liveBadge(liveMs ?? 0)]), tint: "red", dot: true) }
        if lifecycle == .saving { return .init(kind: "saving", text: LibraryLocalization.shared.text("states.badge.saving"), tint: "grey") }
        if [.queued, .running].contains(transcript) {
            return .init(kind: "transcribing", text: etaMinutes.map {LibraryFormat.eta($0)} ?? LibraryLocalization.shared.text("states.badge.transcribing.noEta"), tint: "accent")
        }
        if error?.action != nil { return .init(kind: "needsAttention", text: LibraryLocalization.shared.text("states.badge.needsAttention"), tint: "amber") }
        if let interruptedAtMs { return .init(kind: "interrupted", text: LibraryLocalization.shared.text("states.badge.interrupted",["position":LibraryFormat.position(interruptedAtMs)]), tint: "amber") }
        if origin == .received { return .init(kind: "received", text: LibraryLocalization.shared.text("states.badge.received"), tint: "grey") }
        return nil
    }
    public var canWriteDown: Bool { lifecycle == .saved && [.none, .failed].contains(transcript) && audioAvailable != false }
}
public enum CaptureActivity: Equatable, Sendable { case preparing, recording, saving }
public protocol CaptureActivityProviding: Sendable {
    func snapshot() -> [UUID: CaptureActivity]
}
public struct CaptureActivitySnapshot: CaptureActivityProviding {
    public var captures: [UUID: CaptureActivity]
    public init(_ captures: [UUID: CaptureActivity] = [:]) { self.captures = captures }
    public func snapshot() -> [UUID: CaptureActivity] { captures }
}
public enum NameProvenance: String, Codable, Sendable { case user, recognised, unnamed, source }
public struct MeetingSpeaker: Sendable, Equatable {
    /// The speaker id written for a system-sound ("The others") track: a mixed source, not a person.
    public static let mixedOthersID = "others"
    public var id: String
    public var name: String?
    /// nil for old embedded names whose naming history is unknown.
    public var provenance: NameProvenance?
    public var colourIndex: Int
    public var label: String? = nil
    public var displayName: String { name ?? label ?? "Speaker \(colourIndex + 1)" }
}
public struct MeetingQuote: Codable, Equatable, Sendable {
    public var atMs: Int64
    public var text: String
    public init(atMs: Int64, text: String) { self.atMs = atMs; self.text = text }
    public var displayText: String { "“" + text + "”" }
}
public struct MeetingNote: Codable, Equatable, Sendable { public var atMs: Int64; public var text: String }
public struct LibraryReceivedInfo: Sendable, Equatable {
    public let originalName: String
    public let originalFolderName: String?
    public let sha256: String
    public let importedAtMs: Int64
}
/// Validated audio and its original source timing. A nil offset is deliberately
/// distinct from the zero used only for Library duration display (D3).
public struct LibraryAudioTrack: Sendable, Equatable {
    public let url: URL
    public let startOffsetMs: Double?
    public let frameCount: UInt64?
    public let sourceID: String?
    public let sourceKind: String?
    public let sourceTrackID: String?
    public let sampleRate: Int?
    /// D52.2 stored gap ranges; nil means unknown (an older or foreign writer).
    public let gaps: [TrackPresence.Gap]?
    public init(url: URL, startOffsetMs: Double?, frameCount: UInt64? = nil, sourceID: String? = nil, sourceKind: String? = nil, sourceTrackID: String? = nil, sampleRate: Int? = nil, gaps: [TrackPresence.Gap]? = nil) {
        self.url = url; self.startOffsetMs = startOffsetMs; self.frameCount = frameCount
        self.sourceID = sourceID; self.sourceKind = sourceKind; self.sourceTrackID = sourceTrackID; self.sampleRate = sampleRate; self.gaps = gaps
    }
    /// Exact physical end on the session timeline, when offset and length are known.
    public var endOffsetMs: Double? {
        guard let startOffsetMs, let frameCount, let sampleRate, sampleRate > 0 else { return nil }
        return startOffsetMs + Double(frameCount)*1000/Double(sampleRate)
    }
}
public struct LibraryMeeting: Sendable {
    public let id: UUID
    public let folder: URL
    /// D6.1: keep UUID as id; use the prefixed folder key in collections/UI.
    public var libraryKey: String { retainedKey ?? folder.lastPathComponent }
    /// Only a retained Move original that collides with a destination folder
    /// needs a local collection identity. UUIDs and on-disk names stay intact.
    var retainedKey: String? = nil
    public var state: MeetingState { didSet { if state.origin != oldValue.origin { transcriptTurns = [] } } }
    public var title: String?
    /// R6 display fallbacks may come from unverifiable tags. Received exports
    /// use this independently trusted local/verified title or filename instead.
    public var exportTitle: String? = nil
    public var start: Date?
    public var recordingUtcOffsetMinutes: Int? = nil
    /// An unzoned recording label remains separate from `start`, which is an instant.
    public var recordedTime: MeetingTime? = nil
    /// Creation/import time is usable for ordering, never for a meeting-time label.
    public var sortingFallback: Date? = nil
    public var meetingTime: MeetingTime? {
        if let recordedTime, recordedTime.instant == start { return recordedTime }
        return start.map { MeetingTime(instant:$0) }
    }
    public var sortingInstant: Date? {
        recordedTime?.source == .recordedAtLocal && start == nil ? nil : (start ?? sortingFallback)
    }
    public var timeSortKey: String? {
        if let recordedTime, recordedTime.instant == start { return recordedTime.orderingKey }
        return (start ?? sortingFallback).map { MeetingTime(instant:$0).orderingKey }
    }
    /// Display duration only; D3 substitutes zero for unknown source starts. Never playback alignment.
    public var durationMs: Int64?
    public var speakers: [MeetingSpeaker] { didSet { transcriptTurns = [] } }
    public var quote: MeetingQuote?
    public var notes: [MeetingNote]
    public var audioFiles: [URL]
    public var issues: [LibraryReadIssue]
    /// Keep construction module-visible across Swift toolchains: private backing storage
    /// makes the synthesized memberwise initializer private in Swift 6.1 (Xcode 16.4).
    init(id: UUID, folder: URL, state: MeetingState, title: String?, start: Date?, durationMs: Int64?,
         speakers: [MeetingSpeaker], quote: MeetingQuote?, notes: [MeetingNote], audioFiles: [URL], issues: [LibraryReadIssue]) {
        self.id = id; self.folder = folder; self.state = state; self.title = title
        self.start = start; self.durationMs = durationMs; self.speakers = speakers
        self.quote = quote; self.notes = notes; self.audioFiles = audioFiles; self.issues = issues
    }
    public var metadataReadOnly: Bool = false
    /// The meeting.json revision this read saw (nil without readable metadata).
    public var metadataRevision: Int64? = nil
    /// No title of its own: `title` is the catalog's untitled fallback in the UI language.
    public var titleIsUntitled = false
    public var received: LibraryReceivedInfo? = nil
    /// The words as displayed: each speaker id is the final target of meeting.json's
    /// speakerMerges (D24), so every view, Search and Markdown group merged speakers together.
    public var transcriptItems: [LibraryTranscriptItem] = [] { didSet { transcriptTurns = [] } }
    /// The words with the speaker ids they were written with. Writers (resume, export bodies)
    /// use these: a merge never rewrites a transcript body. Defaults to `transcriptItems`.
    public var writtenTranscriptItems: [LibraryTranscriptItem] {
        get { writtenItems ?? transcriptItems }
        set { writtenItems = newValue }
    }
    private var writtenItems: [LibraryTranscriptItem]? = nil
    /// D24: each merged-away speaker id mapped to its final target (empty without merges).
    public var mergedInto: [String: String] = [:] { didSet { transcriptTurns = [] } }
    /// Prepared snapshots can outlive a metadata merge (including a suspended
    /// preparation). Resolve against the current metadata when rendering them.
    public func speaker(for id: String) -> MeetingSpeaker? {
        let resolved = mergedInto[id] ?? id
        return speakers.first { $0.id == resolved }
    }
    /// Overlap captions use current canonical identities, preserving order and
    /// distinct stored speakers even when their display names happen to match.
    public func overlappingSpeakerIDs(_ ids: [String], excluding speaker: String) -> [String] {
        var seen: Set<String> = [mergedInto[speaker] ?? speaker]
        return ids.compactMap { id in
            let resolved = mergedInto[id] ?? id
            return seen.insert(resolved).inserted ? resolved : nil
        }
    }
    public var speakerDisplayNames: [String:String] {
        var names = Dictionary(uniqueKeysWithValues:speakers.map { ($0.id,$0.displayName) })
        for (from,into) in mergedInto {
            if let name = names[into] { names[from] = name }
        }
        return names
    }
    public var transcriptLanguage: String? = nil
    public var transcriptModel: String? = nil
    /// meeting.json's transcript names a body (D67.2: a failed write-down stores none).
    public var transcriptReferenced = false
    public var wordEndsBoundedByAudio = false { didSet { transcriptTurns = [] } }
    /// Original capture source; never infer browser capture from a live badge.
    public var captureSource: String? = nil
    public var captureEvents: [CaptureEvent] = []
    /// Producer completion is independent of whether an app activity adapter is
    /// currently connected. Never automatically transcribe a growing capture.
    public var captureFinalized = false
    public var canQueueAutomatically: Bool {
        !metadataReadOnly && state.lifecycle == .saved && !audioFiles.isEmpty &&
        (state.origin == .received || captureFinalized) &&
        (state.origin == .own && state.transcript == .none || [.queued,.running].contains(state.transcript))
    }
    public var isBrowserCapture: Bool { captureSource == "chromium" }
    /// Immutable derived rows prepared by the background scanner. UI reads never render.
    public private(set) var transcriptTurns: [LibraryTranscriptTurn] = []
    /// Call after assigning all transcript inputs, off the main actor. Copies share Swift's
    /// immutable array storage; changing any input invalidates only that snapshot's rows.
    public mutating func prepareTranscriptTurns() {
        transcriptTurns = LibraryTranscriptTurn.coalescing(transcriptItems,gaps:speakerGaps,names:speakerDisplayNames,endsBoundedByAudio:wordEndsBoundedByAudio)
    }
    /// D70: maximal speaker runs for listening after merges, independent of reading rows.
    public var speakerTurns: [SpeakerTurn] { SpeakerTurn.grouping(transcriptItems) }
    /// D63 #2: each speaker's gap ranges, from the tracks its words were written from.
    /// A merge target also splits on the ranges of the speakers merged into it.
    public var speakerGaps: SpeakerGapRanges.Ranges {
        SpeakerMerges.gaps(SpeakerGapRanges.of(audioTracks,received:state.origin == .received),mergedInto)
    }
    public var audioTracks: [LibraryAudioTrack] = [] { didSet { transcriptTurns = [] } }
    public var canPlaySession: Bool {
        let nonempty = audioTracks.filter { $0.frameCount != 0 }
        return state.origin == .own && state.lifecycle == .saved && !nonempty.isEmpty && nonempty.allSatisfy { $0.startOffsetMs != nil }
    }
    public var hasNoSpeech: Bool {
        state.lifecycle == .saved && state.transcript == .done && transcriptItems.isEmpty &&
        state.audioAvailable == true && !audioFiles.isEmpty
    }
    public var canWriteDown: Bool { state.canWriteDown || (hasNoSpeech && !metadataReadOnly) }
    /// D52 M12: people, not devices. "The others" is a mixed capture of system sound,
    /// so it is left out of row names and people counts (it still has its own speaker
    /// row and transcript turns).
    public var people: [MeetingSpeaker] { speakers.filter { $0.id != MeetingSpeaker.mixedOthersID } }
    public var speakerNames: [String] { people.map(\.displayName) }
}
public struct LibraryTranscriptTurn: Equatable, Sendable {
    public let speaker: String
    public let startMs: Int64
    public var endMs: Int64
    public var text: String
    public var over: [String] = []
    public var continuation = false
    /// Viewer-readable words of one speaker, split where one of its gap ranges lies between them (D63 #2).
    public static func coalescing(_ items: [LibraryTranscriptItem], gaps: SpeakerGapRanges.Ranges = [:], names: [String:String] = [:], endsBoundedByAudio: Bool = false) -> [Self] {
        let all = MeetingPresentation.turns(items,gaps:gaps,endsBoundedByAudio:endsBoundedByAudio)
        return MeetingPresentation.visibleTurns(all).map {
            .init(speaker:$0.speaker,startMs:$0.startMs,endMs:$0.endMs,text:MeetingPresentation.prose($0,in:all,names:names).text,over:$0.over,continuation:$0.continuation)
        }
    }
}
/// Diagnostic codes only. No raw errors or undrawn UI copy is produced by the core.
public enum LibraryReadIssue: String, Sendable { case unsafePath, invalidMetadata, invalidCapture, missingAudio, invalidAudio, invalidTranscript, unsupportedVersion, unknownStartOffset }
public struct LibraryDayGroup: Sendable {
    public var title: String
    public var meetings: [LibraryMeeting]
}
public struct LibraryScan: Sendable {
    public var meetings: [LibraryMeeting]
    public var issues: [LibraryReadIssue]
    public init(meetings: [LibraryMeeting], issues: [LibraryReadIssue]) { self.meetings = meetings; self.issues = issues }
    /// Primary-root copies take precedence over retained originals of the same
    /// meeting. Global order and identities remain the R6 folder-key contract.
    public static func merging(_ snapshots: [Self], retaining folders: Set<URL> = []) -> Self {
        var seen = Set<String>(), meetings: [LibraryMeeting] = []
        for snapshot in snapshots { for var meeting in snapshot.meetings {
            if !seen.insert(meeting.libraryKey).inserted {
                guard folders.contains(LibraryLocation.canonical(meeting.folder)) else { continue }
                meeting.retainedKey = "retained:" + LibraryLocation.canonical(meeting.folder).path
                guard seen.insert(meeting.libraryKey).inserted else { continue }
            }
            meetings.append(meeting)
        } }
        return .init(meetings:meetings.sorted(by:LibraryScanner.ordered),issues:snapshots.flatMap(\.issues))
    }
    /// R6 order is established by the scanner before grouping by calendar day.
    public func groups(format: LibraryFormat) -> [LibraryDayGroup] {
        var groups: [LibraryDayGroup] = []
        for meeting in meetings {
            let title = meeting.meetingTime.map(format.dayGroup) ?? "Date unknown"
            if groups.last?.title == title { groups[groups.count - 1].meetings.append(meeting) }
            else { groups.append(.init(title: title, meetings: [meeting])) }
        }
        return groups
    }
}
public protocol LibraryWatching: AnyObject, Sendable {
    func start(onChange: @escaping @Sendable (URL) -> Void) throws
    func stop()
}
