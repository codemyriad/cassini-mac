import Foundation

struct ManifestError: Error {
    var message: String
}

/// Builds the typed manifest from decoded JSON, enforcing the required members (SPEC.md "The manifest").
enum ManifestParser {
    /// The largest time this reader accepts, the spec's own ceiling for decimal values (2^53−1).
    static let maxTimeMs = (1 << 53) - 1
    static let payloadRefKeys: Set<String> = ["prefix", "chunkCount", "sha256", "rawBytes", "gzipBytes", "mime", "encoding"]
    static let integrityKeys: Set<String> = ["matchPolicy", "opusAudioSha256", "sampleRate", "channels", "sampleCount", "durationMs"]

    static func parse(_ json: JSON, formatMajor: Int) throws -> Manifest {
        guard json.object != nil else { throw ManifestError(message: "the manifest is not a JSON object") }
        guard json["kind"]?.string == "cassini-portable-meeting" else {
            throw ManifestError(message: "kind is not cassini-portable-meeting")
        }
        guard let version = json["version"]?.int else { throw ManifestError(message: "version is missing or not an integer") }
        guard version == formatMajor else {
            throw ManifestError(message: "version \(version) disagrees with CASSINI_FORMAT /\(formatMajor)")
        }
        guard json["profile"]?.string == "ogg-opus" else { throw ManifestError(message: "profile is not ogg-opus") }

        func object(_ name: String) throws -> JSON {
            guard let v = json[name], v.object != nil else { throw ManifestError(message: "\(name) is missing or not an object") }
            return v
        }
        func str(_ o: JSON, _ path: String, _ key: String, nonEmpty: Bool = false) throws -> String {
            guard let s = o[key]?.string, !nonEmpty || !s.isEmpty else {
                throw ManifestError(message: "\(path).\(key) is missing or not a\(nonEmpty ? " non-empty" : "") string")
            }
            return s
        }
        func int(_ o: JSON, _ path: String, _ key: String) throws -> Int {
            guard let i = o[key]?.int, i >= 0 else { throw ManifestError(message: "\(path).\(key) is missing or not a non-negative integer") }
            return i
        }

        let m = try object("meeting")
        let meeting = Meeting(
            id: try str(m, "meeting", "id", nonEmpty: true),
            title: try str(m, "meeting", "title", nonEmpty: true),
            createdAtUtc: try str(m, "meeting", "createdAtUtc"),
            durationMs: try int(m, "meeting", "durationMs"),
            recordedAtLocal: m["recordedAtLocal"]?.string,
            processedAtUtc: m["processedAtUtc"]?.string
        )

        let a = try object("audio")
        let audio = AudioInfo(
            container: try str(a, "audio", "container"),
            codec: try str(a, "audio", "codec"),
            sampleRate: try int(a, "audio", "sampleRate"),
            channels: try int(a, "audio", "channels"),
            sampleCount: try int(a, "audio", "sampleCount"),
            durationMs: try int(a, "audio", "durationMs")
        )

        let i = try object("integrity")
        let integrity = Integrity(
            matchPolicy: try str(i, "integrity", "matchPolicy"),
            opusAudioSha256: try str(i, "integrity", "opusAudioSha256"),
            sampleRate: try int(i, "integrity", "sampleRate"),
            channels: try int(i, "integrity", "channels"),
            sampleCount: try int(i, "integrity", "sampleCount"),
            durationMs: try int(i, "integrity", "durationMs"),
            unknownMembers: i.keys.filter { !integrityKeys.contains($0) }
        )

        guard let speakerArray = json["speakers"]?.array else { throw ManifestError(message: "speakers is missing or not an array") }
        let speakers = try speakerArray.enumerated().map { n, s in
            Speaker(id: try str(s, "speakers[\(n)]", "id", nonEmpty: true), label: try str(s, "speakers[\(n)]", "label"))
        }

        guard let tArray = json["transcripts"]?.array, !tArray.isEmpty else {
            throw ManifestError(message: "transcripts is missing, not an array, or empty")
        }
        let transcripts = try tArray.enumerated().map { n, t -> TranscriptEntry in
            let path = "transcripts[\(n)]"
            return TranscriptEntry(
                id: try str(t, path, "id", nonEmpty: true),
                isDefault: t["default"]?.bool ?? false,
                format: try str(t, path, "format"),
                language: t["language"]?.string,
                wordCount: t["wordCount"]?.int,
                payloadRef: t["payloadRef"].flatMap(payloadRef)
            )
        }

        let ids = transcripts.map(\.id)
        guard Set(ids).count == ids.count else { throw ManifestError(message: "transcripts[] ids are not unique") }

        var attachments: [Attachment] = []
        for item in json["attachments"]?.array ?? [] {
            guard let name = item["name"]?.string, let b64 = item["contentBase64"]?.string,
                  let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { continue }
            attachments.append(Attachment(name: name, mime: item["mime"]?.string ?? "application/octet-stream", data: data))
        }

        return Manifest(
            version: version, meeting: meeting, audio: audio, integrity: integrity, speakers: speakers,
            transcripts: transcripts, provenance: json["provenance"], summary: json["summary"],
            attachments: attachments, raw: json
        )
    }

    static func payloadRef(_ j: JSON) -> PayloadRef? {
        guard j.object != nil, Set(j.keys).isSubset(of: payloadRefKeys),
              let prefix = j["prefix"]?.string, !prefix.isEmpty,
              let count = j["chunkCount"]?.int, count >= 1,
              let sha = j["sha256"]?.string,
              let raw = j["rawBytes"]?.int, raw >= 0,
              let gz = j["gzipBytes"]?.int, gz >= 0,
              let mime = j["mime"]?.string,
              let encoding = j["encoding"]?.string else { return nil }
        return PayloadRef(prefix: prefix, chunkCount: count, sha256: sha, rawBytes: raw, gzipBytes: gz, mime: mime, encoding: encoding)
    }

    static func words(_ json: JSON) throws -> WordsTranscript {
        guard json.object != nil else { throw ManifestError(message: "the transcript body is not a JSON object") }
        let rawItems: [JSON]
        switch json["items"] {
        case .array(let a)?: rawItems = a
        case .null?: rawItems = []
        default: throw ManifestError(message: "items is missing or not an array")
        }
        var items: [Word] = []
        items.reserveCapacity(rawItems.count)
        for (n, it) in rawItems.enumerated() {
            guard let speaker = it["speaker"]?.string,
                  let start = it["startMs"]?.int, let end = it["endMs"]?.int,
                  let text = it["text"]?.string else {
                throw ManifestError(message: "items[\(n)] lacks speaker, startMs, endMs or text")
            }
            guard start >= 0, start <= end, end <= maxTimeMs else {
                throw ManifestError(message: "items[\(n)] has startMs \(start) and endMs \(end)")
            }
            items.append(Word(speaker: speaker, startMs: start, endMs: end, text: text,
                              lowConfidenceSpeaker: it["lowConfidenceSpeaker"]?.bool == true,
                              attributionGapDb: it["attributionGapDb"]?.double))
        }
        let language = json["language"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        return WordsTranscript(language: language, items: items)
    }
}
