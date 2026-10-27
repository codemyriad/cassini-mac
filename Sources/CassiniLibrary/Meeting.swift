import Foundation

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
        if lifecycle == .recording { return .init(kind: "recording", text: "Recording " + LibraryFormat.liveBadge(liveMs ?? 0), tint: "red", dot: true) }
        if lifecycle == .saving { return .init(kind: "saving", text: "Saving…", tint: "grey") }
        if [.queued, .running].contains(transcript) {
            return .init(kind: "transcribing", text: etaMinutes.map(LibraryFormat.eta) ?? "Transcribing…", tint: "accent")
        }
        if error?.action != nil { return .init(kind: "needsAttention", text: "Needs attention", tint: "amber") }
        if let interruptedAtMs { return .init(kind: "interrupted", text: "Interrupted at " + LibraryFormat.position(interruptedAtMs), tint: "amber") }
        if origin == .received { return .init(kind: "received", text: "Received", tint: "grey") }
        return nil
    }
    public var canWriteDown: Bool { lifecycle == .saved && [.none, .failed].contains(transcript) && audioAvailable != false }
}
public enum CaptureActivity: Sendable { case recording, saving }
public protocol CaptureActivityProviding: Sendable {
    func snapshot() -> [UUID: CaptureActivity]
}
public struct CaptureActivitySnapshot: CaptureActivityProviding {
    public var captures: [UUID: CaptureActivity]
    public init(_ captures: [UUID: CaptureActivity] = [:]) { self.captures = captures }
    public func snapshot() -> [UUID: CaptureActivity] { captures }
}
public enum NameProvenance: String, Codable, Sendable { case user, recognised, unnamed }
public struct MeetingSpeaker: Sendable, Equatable {
    public var id: String
    public var name: String?
    /// nil for old embedded names whose naming history is unknown.
    public var provenance: NameProvenance?
    public var colourIndex: Int
    public var displayName: String { name ?? "Speaker \(colourIndex + 1)" }
}
public struct MeetingQuote: Codable, Equatable, Sendable {
    public var atMs: Int64
    public var text: String
    public init(atMs: Int64, text: String) { self.atMs = atMs; self.text = text }
    public var displayText: String { "“" + text + "”" }
}
public struct MeetingNote: Codable, Equatable, Sendable { public var atMs: Int64; public var text: String }
/// Validated audio and its original source timing. A nil offset is deliberately
/// distinct from the zero used only for Library duration display (D3).
public struct LibraryAudioTrack: Sendable, Equatable {
    public let url: URL
    public let startOffsetMs: Double?
    public init(url: URL, startOffsetMs: Double?) { self.url = url; self.startOffsetMs = startOffsetMs }
}
public struct LibraryMeeting: Sendable {
    public let id: UUID
    public let folder: URL
    /// D6.1: keep UUID as id; use the prefixed folder key in collections/UI.
    public var libraryKey: String { folder.lastPathComponent }
    public var state: MeetingState
    public var title: String?
    public var start: Date?
    /// Display duration only; D3 substitutes zero for unknown source starts. Never playback alignment.
    public var durationMs: Int64?
    public var speakers: [MeetingSpeaker]
    public var quote: MeetingQuote?
    public var notes: [MeetingNote]
    public var audioFiles: [URL]
    public var issues: [LibraryReadIssue]
    public var metadataReadOnly: Bool = false
    public var transcriptItems: [LibraryTranscriptItem] = []
    public var audioTracks: [LibraryAudioTrack] = []
    public var canPlaySession: Bool {
        state.origin == .own && state.lifecycle == .saved && !audioTracks.isEmpty && audioTracks.allSatisfy { $0.startOffsetMs != nil }
    }
    public var canWriteDown: Bool { state.canWriteDown }
    public var speakerNames: [String] { speakers.map(\.displayName) }
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
    /// R6 order is established by the scanner before grouping by calendar day.
    public func groups(format: LibraryFormat) -> [LibraryDayGroup] {
        var groups: [LibraryDayGroup] = []
        for meeting in meetings {
            let title = meeting.start.map(format.dayGroup) ?? "Date unknown"
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
