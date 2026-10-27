import Foundation
import CassiniKit

struct AppMetadata: Decodable {
    let version: Int
    let revision: Int64
    let id: UUID
    let title: String?
    let titleSource: String
    let notes: [MeetingNote]
    let speakers: [Speaker]
    let transcript: Transcript
    let etaMinutes: Int64?
    let error: MeetingIssue?
    let quoteOverride: MeetingQuote?
    let received: Received?
    struct Speaker: Decodable { let id: String; let name: String?; let provenance: NameProvenance; let colourIndex: Int }
    struct Transcript: Decodable { let status: TranscriptStatus; let reference: Reference? }
    struct Reference: Decodable { let kind: String; let file: String; let format: String?; let transcriptId: String? }
    struct Received: Decodable { let originalName: String; let originalFolderName: String?; let sha256: String; let importedAtMs: Int64 }
    static let safe: Int64 = 9_007_199_254_740_991
    func validate(id folderID: UUID, received isReceived: Bool) throws {
        func require(_ condition: Bool) throws { if !condition { throw MetadataError.invalid } }
        try require(version == 1 && id == folderID && (0...Self.safe).contains(revision))
        try require(["meeting-window", "user"].contains(titleSource) && (titleSource != "user" || title?.isEmpty == false))
        try require(title == nil || (!title!.isEmpty && title!.unicodeScalars.count <= 500))
        try require(notes.allSatisfy { (0...Self.safe).contains($0.atMs) && $0.text.unicodeScalars.count <= 100000 })
        try require(speakers.count <= 1000 && Set(speakers.map(\.id)).count == speakers.count)
        for speaker in speakers {
            try require(!speaker.id.isEmpty && speaker.id.unicodeScalars.count <= 200 && speaker.colourIndex >= 0 && speaker.colourIndex <= Self.safe)
            try require(speaker.provenance == .unnamed ? speaker.name == nil : speaker.name?.isEmpty == false)
            try require((speaker.name?.unicodeScalars.count ?? 0) <= 200)
        }
        if [.queued, .running].contains(transcript.status) { try require(etaMinutes.map { (0...Self.safe).contains($0) } == true) }
        else { try require(etaMinutes == nil) }
        if let reference = transcript.reference {
            try require(safeBasename(reference.file))
            try require(reference.kind == "embedded" || (reference.kind == "sidecar" && reference.file == "transcript.json" && reference.format == "cassini.words.v1"))
        }
        if let error {
            try require(!error.id.isEmpty && error.id.first.map { $0 >= "a" && $0 <= "z" } == true && error.id.allSatisfy { $0 >= "a" && $0 <= "z" || $0 >= "0" && $0 <= "9" || $0 == "-" })
            try require(error.action == nil || error.action?.isEmpty == false)
        }
        if let received {
            try require(isReceived && safeBasename(received.originalName) && received.originalName.hasSuffix(".opus"))
            try require(received.originalFolderName == nil || safeBasename(received.originalFolderName!))
            try require(received.sha256.count == 64 && received.sha256.allSatisfy { "0123456789abcdef".contains($0) })
            try require((0...Self.safe).contains(received.importedAtMs))
        } else { try require(!isReceived) }
        if let quoteOverride { try require((0...Self.safe).contains(quoteOverride.atMs) && !quoteOverride.text.isEmpty && quoteOverride.text.unicodeScalars.count <= 100000) }
    }
}
enum MetadataError: Error { case invalid }
func safeBasename(_ value: String) -> Bool { !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && value.unicodeScalars.count <= 255 }
func safeFile(_ name: String, in directory: URL) throws -> URL {
    guard safeBasename(name) else { throw MetadataError.invalid }
    let file = directory.appendingPathComponent(name).resolvingSymlinksInPath()
    guard file.deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { throw MetadataError.invalid }
    return file
}
func readJSON<T: Decodable>(_ type: T.Type, at url: URL, limit: Int = 1_048_576) throws -> T {
    let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
    let data = try file.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw MetadataError.invalid }
    _ = try JSONParser.parse(data)
    return try JSONDecoder().decode(type, from: data)
}
func recordingDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: value)
}
