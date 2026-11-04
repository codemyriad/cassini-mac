// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import zlib

/// The transcripts a file carries: their manifest entries, in order, and the tags that hold
/// their payloads. `digest` covers both, so equal sets have equal digests.
public struct PortableTranscripts: Sendable {
    public let entries: [JSON]
    let comments: [Comment]
    public let digest: String
    /// The original's payload tags carried here (upper-cased names), never carried twice.
    let carriedNames: Set<String>
}

/// One canonical word-timed body, with standard Cassini v1 chunk descriptors, and any
/// transcripts carried over from an original file byte for byte.
/// Input manifest supplies meeting/audio/integrity/speakers and approved hints.
public enum PortableMeetingTags {
    public static func make(manifest: JSON, transcript: Data, language: String = "und", wordCount: Int,
                            shouldCancel: () -> Bool = { false }) throws -> Data {
        try make(manifest:manifest,transcripts:transcripts(own:(transcript,language,wordCount),carried:nil,shouldCancel:shouldCancel),shouldCancel:shouldCancel)
    }
    /// `own`: this app's words body (the default transcript when given). `carried`: an
    /// original file whose transcripts all go out unchanged, their manifest entries verbatim and
    /// their payload tags byte for byte; when `own` is given too they stay, no longer default.
    /// With neither, the empty body (a file always lists a transcript).
    public static func transcripts(own: (body: Data, language: String, wordCount: Int)?, carried: CassiniFile?,
                                   shouldCancel: () -> Bool = { false }) throws -> PortableTranscripts {
        let originals = carried?.manifest?.raw["transcripts"]?.array ?? []
        // Display transcripts (readableTranscripts) stay in the manifest as they are; their
        // payloads are carried with the others.
        let readable = carried?.manifest?.raw["readableTranscripts"]?.array ?? []
        let prefixes = (originals + readable).compactMap { $0["payloadRef"]?["prefix"]?.string }.filter { !$0.isEmpty }
        // Exactly each declared chunk set's tags (never a longer prefix's), in file order.
        var comments = (carried?.tags?.comments ?? []).filter { comment in prefixes.contains { isChunk(comment.name,of:$0) } }
        let carriedNames = Set(comments.map { $0.name.uppercased() })
        // Every entry is carried, also one this app can't read (no payloadRef, another format).
        var entries = try originals.map { own == nil ? $0 : try $0.setting("default",to:.bool(false)) }
        let ids = Set((originals + readable).compactMap { $0["id"]?.string })
        if own != nil || entries.isEmpty {
            let (body,language,wordCount) = own ?? (Data(#"{"items":[],"language":"und"}"#.utf8),"und",0)
            let parsed = try ManifestParser.words(JSONParser.parse(body))
            guard parsed.items.count == wordCount else { throw PayloadError.json("word count mismatch") }
            // Never a carried id or payload prefix.
            var id = "script", index = 1
            func taken(_ id: String) -> Bool {
                let mine = prefix(id)
                return ids.contains(id) || prefixes.contains { $0.uppercased() == mine } || (carried?.tags?.comments ?? []).contains { isChunk($0.name,of:mine) }
            }
            while taken(id) { index += 1; id = "script-\(index)" }
            let (reference,payload) = try chunkSet(body,prefix:prefix(id),mime:"application/vnd.cassini.transcript-words+json",shouldCancel:shouldCancel)
            comments = payload + comments
            entries.insert(.object([("id",.string(id)),("default",.bool(true)),("format",.string(CassiniReader.wordsFormat)),
                ("language",.string(language)),("wordCount",.number(String(wordCount))),("payloadRef",reference)]),at:0)
        }
        var digest = SHA256()
        digest.update(data:try JSON.array(entries).encoded())
        for comment in comments { digest.update(data:Data((comment.name + "=" + comment.value + "\n").utf8)) }
        return .init(entries:entries,comments:comments,digest:digest.finalize().map { String(format:"%02x",$0) }.joined(),carriedNames:carriedNames)
    }
    static let descriptorSuffixes: Set<String> = ["MIME","ENCODING","CHUNK_COUNT","SHA256","RAW_BYTES","GZIP_BYTES"]
    /// One chunk set's tag: its prefix and a descriptor suffix or a chunk number (CassiniReader).
    static func isChunk(_ name: String, of prefix: String) -> Bool {
        let name = name.uppercased(), prefix = prefix.uppercased()
        guard name.hasPrefix(prefix) else { return false }
        let rest = name.dropFirst(prefix.count)
        return descriptorSuffixes.contains(String(rest)) || (rest.count >= 3 && rest.allSatisfy { $0.isASCII && $0.isNumber })
    }
    private static func prefix(_ id: String) -> String {
        "CASSINI_TX_" + id.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined() + "_PAYLOAD_"
    }
    private static func chunkSet(_ raw: Data, prefix: String, mime: String, shouldCancel: () -> Bool) throws -> (JSON,[Comment]) {
        guard raw.count <= CassiniReader.maxPayloadBytes else { throw PayloadError.tooLarge(CassiniReader.maxPayloadBytes) }
        let compressed = try gzip(raw,shouldCancel:shouldCancel)
        let base64 = compressed.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        let bytes = Array(base64.utf8)
        let chunks = stride(from:0,to:bytes.count,by:4096).map { String(decoding:bytes[$0..<min($0 + 4096,bytes.count)],as:UTF8.self) }
        let sha = SHA256.hash(data:raw).map { String(format:"%02x",$0) }.joined()
        var comments: [Comment] = []
        for (suffix,value) in [("MIME",mime),("ENCODING",CassiniReader.encoding),("CHUNK_COUNT",String(chunks.count)),("SHA256",sha),("RAW_BYTES",String(raw.count)),("GZIP_BYTES",String(compressed.count))] {
            comments.append(.init(name:prefix + suffix,value:value))
        }
        for (index,chunk) in chunks.enumerated() { comments.append(.init(name:prefix + String(format:"%03d",index),value:chunk)) }
        return (.object([("prefix",.string(prefix)),("chunkCount",.number(String(chunks.count))),("sha256",.string(sha)),
            ("rawBytes",.number(String(raw.count))),("gzipBytes",.number(String(compressed.count))),("mime",.string(mime)),("encoding",.string(CassiniReader.encoding))]),comments)
    }
    /// The tags this app writes itself; any other tag of an original file is carried (`carriedTags`).
    static let written: Set<String> = ["CASSINI_FORMAT","CASSINI_PROFILE","CASSINI_PAYLOAD_SCHEMA","CASSINI_TRANSCRIPT_IDS","CASSINI_TRANSCRIPT_DEFAULT",
        "CASSINI_AUDIO_SAMPLE_RATE","CASSINI_AUDIO_CHANNELS","CASSINI_AUDIO_SAMPLE_COUNT","CASSINI_AUDIO_DURATION_MS","CASSINI_AUDIO_MATCH_POLICY",
        "CASSINI_AUDIO_OPUS_SHA256","CASSINI_MEETING_ID","CASSINI_CREATED_AT","CASSINI_SPEAKER_COUNT","TITLE"]
    /// An original file's tags this app neither writes nor rebuilds (DATE, DESCRIPTION, ENCODER,
    /// ARTIST, unknown CASSINI_ facts), in file order. The manifest's chunk set is rewritten, the
    /// transcripts' are carried with them (`transcripts`), and a withdrawn transcript's leftover
    /// CASSINI_TX_ tags are dropped.
    public static func carriedTags(_ file: CassiniFile, besides transcripts: PortableTranscripts) -> [Comment] {
        (file.tags?.comments ?? []).filter { comment in
            let name = comment.name.uppercased()
            return !written.contains(name) && !isChunk(name,of:"CASSINI_PAYLOAD_") && !transcripts.carriedNames.contains(name) && !name.hasPrefix("CASSINI_TX_")
        }
    }
    public static func make(manifest: JSON, transcripts: PortableTranscripts, carriedTags: [Comment] = [],
                            shouldCancel: () -> Bool = { false }) throws -> Data {
        var comments = transcripts.comments
        let root = try manifest.setting("transcripts",to:.array(transcripts.entries))
        let model = try ManifestParser.parse(root,formatMajor:1)
        comments += try chunkSet(root.encoded(),prefix:"CASSINI_PAYLOAD_",mime:"application/vnd.cassini.portable-meeting+json",shouldCancel:shouldCancel).1
        // SPEC: the tag lists the ids sorted (the manifest keeps producer order).
        let ids = model.transcripts.map(\.id).sorted().joined(separator:",")
        let scalarTags: [(String,String)] = [
            ("CASSINI_FORMAT","org.cassini.portable-meeting/1"),("CASSINI_PROFILE","ogg-opus"),
            ("CASSINI_PAYLOAD_SCHEMA","https://format.gocassini.com/schema/cassini-portable-meeting-manifest-v1.schema.json"),
            ("CASSINI_TRANSCRIPT_IDS",ids),("CASSINI_TRANSCRIPT_DEFAULT",model.defaultTranscript?.id ?? model.transcripts.first?.id ?? ""),
            ("CASSINI_AUDIO_SAMPLE_RATE","48000"),("CASSINI_AUDIO_CHANNELS",String(model.audio.channels)),
            ("CASSINI_AUDIO_SAMPLE_COUNT",String(model.audio.sampleCount)),("CASSINI_AUDIO_DURATION_MS",String(model.audio.durationMs)),
            ("CASSINI_AUDIO_MATCH_POLICY","exact-opus-audio-v1"),("CASSINI_AUDIO_OPUS_SHA256",model.integrity.opusAudioSha256),
            ("CASSINI_MEETING_ID",model.meeting.id),("CASSINI_CREATED_AT",model.meeting.createdAtUtc),
            ("CASSINI_SPEAKER_COUNT",String(model.speakers.count)),("TITLE",model.meeting.title)
        ]
        for (name,value) in scalarTags { comments.append(.init(name:name,value:value)) }
        comments += carriedTags
        return try packet(comments:comments)
    }
    public static func packet(comments: [Comment] = []) throws -> Data {
        var data = Data("OpusTags".utf8)
        func number(_ value: Int) throws {
            guard value >= 0, value <= Int(UInt32.max) else { throw PayloadError.tooLarge(value) }
            var little = UInt32(value).littleEndian; withUnsafeBytes(of:&little) { data.append(contentsOf:$0) }
        }
        func text(_ value: String) throws { let bytes = Data(value.utf8); try number(bytes.count); data.append(bytes) }
        try text("Cassini"); try number(comments.count)
        for comment in comments {
            try text(comment.name + "=" + comment.value)
            guard data.count <= 120 * 1024 * 1024 else { throw PayloadError.tooLarge(data.count) }
        }
        return data
    }
    static func gzip(_ input: Data, shouldCancel: () -> Bool = { false }) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream,Z_DEFAULT_COMPRESSION,Z_DEFLATED,16 + MAX_WBITS,8,Z_DEFAULT_STRATEGY,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw PayloadError.gzip("encoder initialization") }
        defer { deflateEnd(&stream) }
        var output = Data(), buffer = [UInt8](repeating:0,count:65536)
        try input.withUnsafeBytes { source in
            stream.next_in = UnsafeMutablePointer(mutating:source.bindMemory(to:Bytef.self).baseAddress)
            stream.avail_in = uInt(source.count)
            while true {
                if shouldCancel() { throw CancellationError() }
                let result = buffer.withUnsafeMutableBytes { target -> Int32 in
                    stream.next_out = target.bindMemory(to:Bytef.self).baseAddress; stream.avail_out = uInt(target.count)
                    return deflate(&stream,Z_FINISH)
                }
                guard result == Z_OK || result == Z_STREAM_END else { throw PayloadError.gzip("encoder failure") }
                output.append(contentsOf:buffer.prefix(buffer.count - Int(stream.avail_out)))
                if result == Z_STREAM_END { break }
            }
        }
        return output
    }
}

/// D53.2: the language of the recognizer run that made the words, written the same
/// way in the transcript body, descriptor and provenance; "und" when unknown.
public enum TranscriptLanguage {
    public static func written(_ value: String?) -> String {
        guard let value, !value.isEmpty, value != "auto" else { return "und" }
        return value
    }
}
