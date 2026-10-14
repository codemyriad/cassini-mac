import Foundation

/// Reads a Cassini portable meeting following SPEC.md "Reading a file".
public enum CassiniReader {
    public static let formatPrefix = "org.cassini.portable-meeting/"
    public static let encoding = "base64url+gzip+utf8json"
    public static let wordsFormat = "cassini.words.v1"
    /// Our own ceiling on any decompressed chunk set (SPEC: producers keep under 64 MiB).
    public static let maxPayloadBytes = 64 * 1024 * 1024
    public static let maxChunkCount = 100_000

    public static func read(contentsOf url: URL, verifyAudio: Bool = true) throws -> CassiniFile {
        try read(Data(contentsOf: url, options: .mappedIfSafe), verifyAudio: verifyAudio)
    }

    /// Throws only when the bytes are not Ogg Opus at all. Every Cassini outcome is a state.
    public static func read(_ data: Data, verifyAudio: Bool = true) throws -> CassiniFile {
        let headers = try OpusHeaderReader.read(data)
        let tags = try TagSet.parse(headers.tags)
        var file = CassiniFile(state: .plainAudio, tags: tags, formatId: nil, manifest: nil, transcripts: [],
                               audioCheck: .notApplicable, audioDigest: nil, errors: [], warnings: [], stateReason: nil)
        let digest: Result<AudioDigest, AudioDigestError>? = verifyAudio
            ? Result { try OpusAudioDigest.compute(data) }.mapError { $0 as? AudioDigestError ?? .container("\($0)") }
            : nil
        file.audioDigest = digest

        // 2. Decide what the file is.
        guard let format = tags["CASSINI_FORMAT"] else { return file }
        file.formatId = format
        guard format.hasPrefix(formatPrefix), let major = parseDecimal(String(format.dropFirst(formatPrefix.count))) else {
            return invalid(file, Finding("format-malformed", tag: "CASSINI_FORMAT", "CASSINI_FORMAT is \"\(format)\""))
        }
        guard major == 1 else {
            file.state = .unknownCassiniFormat
            file.stateReason = "This file carries Cassini metadata in version \(major), which this app cannot read."
            return file
        }
        for name in tags.repeatedNames where name.hasPrefix("CASSINI_") {
            if name == "CASSINI_FORMAT" || name.hasPrefix("CASSINI_PAYLOAD_") || name.hasPrefix("CASSINI_TX_") {
                file.errors.append(Finding("duplicate-tag", tag: name, "\(name) appears \(tags.count(name)) times"))
            } else {
                file.warnings.append(Finding("repeated-tag", tag: name, "\(name) appears \(tags.count(name)) times"))
            }
        }
        if !file.errors.isEmpty { return invalid(file, nil) }

        // 3–4. Reassemble, decode and verify the manifest. For it, the tags are the record.
        let manifestJSON: JSON
        switch manifestDescriptor(tags) {
        case .failure(let f): return invalid(file, f)
        case .success(let d):
            switch decodeChunkSet(d, tags: tags) {
            case .failure(let f): return invalid(file, f)
            case .success(let j): manifestJSON = j
            }
        }

        // 5. Read the manifest.
        let manifest: Manifest
        do {
            manifest = try ManifestParser.parse(manifestJSON, formatMajor: major)
        } catch let e as ManifestError {
            return invalid(file, Finding("manifest-invalid", e.message))
        } catch {
            return invalid(file, Finding("manifest-invalid", "\(error)"))
        }
        file.manifest = manifest
        compareCopies(manifest, tags, &file.warnings)

        // 6–7. Resolve and decode the word-timed transcripts.
        for entry in manifest.transcripts {
            let load = loadTranscript(entry, tags: tags, warnings: &file.warnings)
            if case .unavailable(let f) = load { file.errors.append(f) }
            file.transcripts.append((entry, load))
        }

        // 8. Decide whether to trust it.
        decideTrust(&file, manifest: manifest, tags: tags, digest: digest)
        return file
    }

    static func invalid(_ file: CassiniFile, _ finding: Finding?) -> CassiniFile {
        var f = file
        if let finding { f.errors.append(finding) }
        f.state = .invalidCassiniMetadata
        f.manifest = nil
        f.transcripts = []
        f.stateReason = "The Cassini metadata in this file cannot be read: \(f.errors.first?.message ?? "unknown error")."
        return f
    }

    // MARK: Chunk sets

    struct ChunkDescriptor {
        var prefix: String
        var chunkCount: Int
        var sha256: String
        var rawBytes: Int
        var gzipBytes: Int?
        var encoding: String
    }

    static func manifestDescriptor(_ tags: TagSet) -> Result<ChunkDescriptor, Finding> {
        let p = "CASSINI_PAYLOAD_"
        guard let encoding = tags[p + "ENCODING"] else {
            return .failure(Finding("payload-descriptor-incomplete", tag: p + "ENCODING", "\(p)ENCODING is missing"))
        }
        guard encoding == CassiniReader.encoding else {
            return .failure(Finding("unsupported-encoding", tag: p + "ENCODING", "\(p)ENCODING is \"\(encoding)\""))
        }
        guard let count = parseDecimal(tags[p + "CHUNK_COUNT"]), count >= 1 else {
            return .failure(Finding("payload-descriptor-incomplete", tag: p + "CHUNK_COUNT", "\(p)CHUNK_COUNT is missing or malformed"))
        }
        guard let sha = tags[p + "SHA256"], !sha.isEmpty else {
            return .failure(Finding("payload-descriptor-incomplete", tag: p + "SHA256", "\(p)SHA256 is missing"))
        }
        guard let raw = parseDecimal(tags[p + "RAW_BYTES"]) else {
            return .failure(Finding("payload-descriptor-incomplete", tag: p + "RAW_BYTES", "\(p)RAW_BYTES is missing or malformed"))
        }
        let gz = tags[p + "GZIP_BYTES"]
        if gz != nil && parseDecimal(gz) == nil {
            return .failure(Finding("payload-descriptor-incomplete", tag: p + "GZIP_BYTES", "\(p)GZIP_BYTES is malformed"))
        }
        return .success(ChunkDescriptor(prefix: p, chunkCount: count, sha256: sha, rawBytes: raw,
                                        gzipBytes: parseDecimal(gz), encoding: encoding))
    }

    static func chunkName(_ prefix: String, _ i: Int) -> String {
        prefix + (i < 1000 ? String(format: "%03d", i) : String(i))
    }

    static func decodeChunkSet(_ d: ChunkDescriptor, tags: TagSet) -> Result<JSON, Finding> {
        guard d.encoding == encoding else {
            return .failure(Finding("unsupported-encoding", tag: d.prefix + "ENCODING", "encoding \"\(d.encoding)\" is not supported"))
        }
        guard d.chunkCount <= maxChunkCount else {
            return .failure(Finding("payload-too-large", tag: d.prefix + "CHUNK_COUNT", "\(d.chunkCount) chunks is more than this reader accepts"))
        }
        guard d.rawBytes <= maxPayloadBytes else {
            return .failure(Finding("payload-too-large", tag: d.prefix + "RAW_BYTES", "\(d.rawBytes) bytes is more than this reader accepts"))
        }
        var text = ""
        for i in 0..<d.chunkCount {
            let name = chunkName(d.prefix, i)
            if tags.count(name) > 1 {
                return .failure(Finding("duplicate-tag", tag: name, "\(name) appears \(tags.count(name)) times"))
            }
            guard let v = tags[name], !v.isEmpty else {
                return .failure(Finding("chunk-missing", tag: name, "\(name) is missing"))
            }
            text += v
        }
        do {
            let compressed = try Base64URL.decode(text)
            if let gz = d.gzipBytes, gz != compressed.count {
                return .failure(Finding("payload-gzip-bytes-mismatch", tag: d.prefix + "GZIP_BYTES",
                                        "\(d.prefix)GZIP_BYTES says \(gz), the chunks hold \(compressed.count)"))
            }
            let raw = try Gzip.inflate(compressed, limit: d.rawBytes)
            guard raw.count == d.rawBytes else {
                return .failure(Finding("payload-raw-bytes-mismatch", tag: d.prefix + "RAW_BYTES",
                                        "\(d.prefix)RAW_BYTES says \(d.rawBytes), the payload inflates to \(raw.count)"))
            }
            let sha = Hex.sha256(raw)
            guard sha == d.sha256.lowercased() else {
                return .failure(Finding("payload-sha256-mismatch", tag: d.prefix + "SHA256",
                                        "the SHA-256 of \(d.prefix)* does not match the declared digest"))
            }
            return .success(try JSONParser.parse(raw))
        } catch let e as PayloadError {
            if case .tooLarge = e {
                return .failure(Finding("payload-raw-bytes-mismatch", tag: d.prefix + "RAW_BYTES", e.description))
            }
            return .failure(Finding("decode-failed", tag: d.prefix + "000", e.description))
        } catch {
            return .failure(Finding("decode-failed", tag: d.prefix + "000", "\(error)"))
        }
    }

    // MARK: Transcripts

    static func loadTranscript(_ entry: TranscriptEntry, tags: TagSet, warnings: inout [Finding]) -> TranscriptLoad {
        guard entry.format == wordsFormat else {
            return .unavailable(Finding("unsupported-transcript-format", "transcript \(entry.id) is \(entry.format), which this app cannot show"))
        }
        guard let ref = entry.payloadRef else {
            return .unavailable(Finding("payload-ref-invalid", "transcript \(entry.id) has a missing or unrecognised payloadRef"))
        }
        // The payloadRef is the record; the CASSINI_TX_* descriptors are a copy.
        let copies: [(String, String)] = [
            ("MIME", ref.mime), ("ENCODING", ref.encoding), ("CHUNK_COUNT", String(ref.chunkCount)),
            ("SHA256", ref.sha256), ("RAW_BYTES", String(ref.rawBytes)), ("GZIP_BYTES", String(ref.gzipBytes)),
        ]
        for (suffix, value) in copies {
            let name = ref.prefix + suffix
            if let tag = tags[name], tag != value {
                warnings.append(Finding("tag-manifest-disagreement", tag: name, "\(name) is \(tag), the manifest says \(value)"))
            }
        }
        let d = ChunkDescriptor(prefix: ref.prefix, chunkCount: ref.chunkCount, sha256: ref.sha256,
                                rawBytes: ref.rawBytes, gzipBytes: ref.gzipBytes, encoding: ref.encoding)
        switch decodeChunkSet(d, tags: tags) {
        case .failure(var f):
            f.message = "transcript \(entry.id): \(f.message)"
            return .unavailable(f)
        case .success(let json):
            do {
                return .available(try ManifestParser.words(json))
            } catch let e as ManifestError {
                return .unavailable(Finding("transcript-invalid", "transcript \(entry.id): \(e.message)"))
            } catch {
                return .unavailable(Finding("transcript-invalid", "transcript \(entry.id): \(error)"))
            }
        }
    }

    // MARK: Tags that copy the manifest

    static func compareCopies(_ m: Manifest, _ tags: TagSet, _ warnings: inout [Finding]) {
        func check(_ name: String, _ value: String) {
            if let tag = tags[name], tag != value {
                warnings.append(Finding("tag-manifest-disagreement", tag: name, "\(name) is \(tag), the manifest says \(value)"))
            }
        }
        check("CASSINI_MEETING_ID", m.meeting.id)
        check("CASSINI_CREATED_AT", m.meeting.createdAtUtc)
        check("CASSINI_SPEAKER_COUNT", String(m.speakers.count))
        check("CASSINI_AUDIO_SAMPLE_RATE", String(m.integrity.sampleRate))
        check("CASSINI_AUDIO_CHANNELS", String(m.integrity.channels))
        check("CASSINI_AUDIO_SAMPLE_COUNT", String(m.integrity.sampleCount))
        check("CASSINI_AUDIO_DURATION_MS", String(m.integrity.durationMs))
        check("CASSINI_AUDIO_MATCH_POLICY", m.integrity.matchPolicy)

        let ids = Set(m.transcripts.map(\.id))
        if let listed = tags["CASSINI_TRANSCRIPT_IDS"] {
            let tagged = Set(listed.split(separator: ",").map(String.init))
            if tagged != ids {
                warnings.append(Finding("tag-manifest-disagreement", tag: "CASSINI_TRANSCRIPT_IDS",
                                        "CASSINI_TRANSCRIPT_IDS is \(listed), the manifest lists \(m.transcripts.map(\.id).joined(separator: ","))"))
            }
        }
        if let def = tags["CASSINI_TRANSCRIPT_DEFAULT"], ids.contains(def), def != m.defaultTranscript?.id {
            warnings.append(Finding("tag-manifest-disagreement", tag: "CASSINI_TRANSCRIPT_DEFAULT",
                                    "CASSINI_TRANSCRIPT_DEFAULT is \(def), the manifest selects \(m.defaultTranscript?.id ?? "none")"))
        }
    }

    // MARK: Trust

    static func decideTrust(_ file: inout CassiniFile, manifest m: Manifest, tags: TagSet,
                            digest: Result<AudioDigest, AudioDigestError>?) {
        func unverified(_ reason: String) {
            file.state = .unverified
            file.audioCheck = .unverifiable(reason)
            file.stateReason = reason
        }
        let claimed = m.integrity.opusAudioSha256.lowercased()
        if let tagged = tags["CASSINI_AUDIO_OPUS_SHA256"], tagged.lowercased() != claimed {
            file.warnings.append(Finding("tag-manifest-disagreement", tag: "CASSINI_AUDIO_OPUS_SHA256",
                                         "CASSINI_AUDIO_OPUS_SHA256 and the manifest's integrity.opusAudioSha256 disagree"))
            return unverified("The file makes two different claims about its audio, so there is nothing single to check.")
        }
        guard let digest else {
            file.state = .unverified
            file.audioCheck = .notChecked("The audio was not checked.")
            file.stateReason = "The audio was not checked."
            return
        }
        if !m.integrity.unknownMembers.isEmpty {
            return unverified("The integrity record has members this app does not know: \(m.integrity.unknownMembers.joined(separator: ", ")).")
        }
        guard m.integrity.matchPolicy == "exact-opus-audio-v1" else {
            return unverified("The audio match policy \"\(m.integrity.matchPolicy)\" is not one this app implements.")
        }
        guard claimed.count == 64 else { return unverified("The file carries no usable audio digest.") }
        switch digest {
        case .failure(let e):
            return unverified("The audio could not be checked: \(e.description).")
        case .success(let a):
            var failed: [String] = []
            if a.sha256 != claimed {
                failed.append("digest")
                file.warnings.append(Finding("audio-digest-mismatch", "the Opus audio SHA-256 does not match integrity.opusAudioSha256"))
            }
            var shape: [String] = []
            if a.channels != m.integrity.channels { shape.append("channels") }
            if a.sampleCount != m.integrity.sampleCount { shape.append("sample count") }
            if a.durationMs != m.integrity.durationMs { shape.append("duration") }
            if !shape.isEmpty {
                failed += shape
                file.warnings.append(Finding("audio-shape-mismatch", "computed \(shape.joined(separator: ", ")) disagree with integrity"))
            }
            if failed.isEmpty {
                file.state = .ok
                file.audioCheck = .verified(a)
            } else {
                file.state = .staleAudio
                file.audioCheck = .mismatched(a, failed)
                file.stateReason = "The audio in this file does not match the transcript recorded with it. "
                    + "The transcript is shown as it was written; it may describe a different recording."
            }
        }
    }
}
