import Foundation

/// The trust states of SPEC.md "Trust and integrity". The raw values are normative.
public enum TrustState: String, Sendable, Codable {
    case plainAudio = "plain-audio"
    case unknownCassiniFormat = "unknown-cassini-format"
    case invalidCassiniMetadata = "invalid-cassini-metadata"
    case unverified = "unverified"
    case staleAudio = "stale-audio"
    case ok = "ok"
}

/// A coded problem found while reading. Codes follow the conformance suite's vocabulary.
public struct Finding: Error, Sendable, Equatable, Codable {
    public var code: String
    public var tag: String?
    public var message: String

    public init(_ code: String, tag: String? = nil, _ message: String) {
        self.code = code
        self.tag = tag
        self.message = message
    }
}

public struct Speaker: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct PayloadRef: Sendable, Equatable {
    public var prefix: String
    public var chunkCount: Int
    public var sha256: String
    public var rawBytes: Int
    public var gzipBytes: Int
    public var mime: String
    public var encoding: String
}

public struct TranscriptEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var isDefault: Bool
    public var format: String
    public var language: String?
    public var wordCount: Int?
    /// nil when the entry's payloadRef is missing, malformed or carries a member we do not know.
    public var payloadRef: PayloadRef?
}

public struct Meeting: Sendable, Equatable {
    public var id: String
    public var title: String
    public var createdAtUtc: String
    public var durationMs: Int
    public var recordedAtLocal: String?
    public var processedAtUtc: String?
}

public struct AudioInfo: Sendable, Equatable {
    public var container: String
    public var codec: String
    public var sampleRate: Int
    public var channels: Int
    public var sampleCount: Int
    public var durationMs: Int
}

public struct Integrity: Sendable, Equatable {
    public var matchPolicy: String
    public var opusAudioSha256: String
    public var sampleRate: Int
    public var channels: Int
    public var sampleCount: Int
    public var durationMs: Int
    /// Members of the closed `integrity` object that this reader does not know.
    public var unknownMembers: [String]
}

public struct Attachment: Sendable, Equatable {
    public var name: String
    public var mime: String
    public var data: Data
}

public struct Manifest: Sendable, Equatable {
    public var version: Int
    public var meeting: Meeting
    public var audio: AudioInfo
    public var integrity: Integrity
    public var speakers: [Speaker]
    public var transcripts: [TranscriptEntry]
    public var provenance: JSON?
    public var summary: JSON?
    public var attachments: [Attachment]
    /// The whole decoded manifest, for display of members this reader does not model.
    public var raw: JSON

    public func speaker(_ id: String) -> Speaker? { speakers.first { $0.id == id } }

    /// The resolved words slot: the first entry flagged default, else the first entry.
    public var defaultTranscript: TranscriptEntry? { transcripts.first { $0.isDefault } ?? transcripts.first }

    /// The meeting summary, from the attachment named `summary.md`.
    public var summaryMarkdown: String? {
        attachments.first { $0.name == "summary.md" }.flatMap { String(data: $0.data, encoding: .utf8) }
    }
}

/// One `cassini.words.v1` item.
public struct Word: Sendable, Equatable {
    public var speaker: String
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var lowConfidenceSpeaker: Bool
    public var attributionGapDb: Double?
}

public struct WordsTranscript: Sendable, Equatable {
    public var language: String?
    /// Items in file order (speaker-turn order). Never sorted by time.
    public var items: [Word]
}

/// What happened to one transcript body.
public enum TranscriptLoad: Sendable, Equatable {
    case available(WordsTranscript)
    case unavailable(Finding)

    public var transcript: WordsTranscript? {
        if case .available(let t) = self { return t }
        return nil
    }
}

/// How the audio check went.
public enum AudioCheck: Sendable, Equatable {
    case notApplicable
    case notChecked(String)
    case verified(AudioDigest)
    case mismatched(AudioDigest, [String])
    case unverifiable(String)
}

/// Everything a read produced.
public struct CassiniFile: Sendable {
    public var state: TrustState
    public var tags: TagSet?
    public var formatId: String?
    public var manifest: Manifest?
    /// Every word-timed transcript, keyed by id, in manifest order.
    public var transcripts: [(entry: TranscriptEntry, load: TranscriptLoad)]
    public var audioCheck: AudioCheck
    /// The computed `exact-opus-audio-v1` digest, when the audio was read; for plain audio too.
    public var audioDigest: Result<AudioDigest, AudioDigestError>?
    public var errors: [Finding]
    public var warnings: [Finding]
    /// Why the state is not `ok`, in a sentence, when there is something to say.
    public var stateReason: String?

    public var defaultTranscript: (entry: TranscriptEntry, load: TranscriptLoad)? {
        guard let id = manifest?.defaultTranscript?.id else { return nil }
        return transcripts.first { $0.entry.id == id }
    }
}
