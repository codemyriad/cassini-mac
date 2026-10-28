// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import zlib

/// One canonical word-timed body, with standard Cassini v1 chunk descriptors.
/// Input manifest supplies meeting/audio/integrity/speakers and approved hints.
public enum PortableMeetingTags {
    public static func make(manifest: JSON, transcript: Data, language: String = "auto", wordCount: Int,
                            shouldCancel: () -> Bool = { false }) throws -> Data {
        let body = try ManifestParser.words(JSONParser.parse(transcript))
        guard body.items.count == wordCount else { throw PayloadError.json("word count mismatch") }
        var comments: [Comment] = []
        func chunkSet(_ raw: Data, prefix: String, mime: String) throws -> JSON {
            guard raw.count <= CassiniReader.maxPayloadBytes else { throw PayloadError.tooLarge(CassiniReader.maxPayloadBytes) }
            let compressed = try gzip(raw,shouldCancel:shouldCancel)
            let base64 = compressed.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
            let bytes = Array(base64.utf8)
            let chunks = stride(from:0,to:bytes.count,by:4096).map { String(decoding:bytes[$0..<min($0 + 4096,bytes.count)],as:UTF8.self) }
            let sha = SHA256.hash(data:raw).map { String(format:"%02x",$0) }.joined()
            for (suffix,value) in [("MIME",mime),("ENCODING",CassiniReader.encoding),("CHUNK_COUNT",String(chunks.count)),("SHA256",sha),("RAW_BYTES",String(raw.count)),("GZIP_BYTES",String(compressed.count))] {
                comments.append(.init(name:prefix + suffix,value:value))
            }
            for (index,chunk) in chunks.enumerated() { comments.append(.init(name:prefix + String(format:"%03d",index),value:chunk)) }
            return .object([("prefix",.string(prefix)),("chunkCount",.number(String(chunks.count))),("sha256",.string(sha)),
                ("rawBytes",.number(String(raw.count))),("gzipBytes",.number(String(compressed.count))),("mime",.string(mime)),("encoding",.string(CassiniReader.encoding))])
        }
        let reference = try chunkSet(transcript,prefix:"CASSINI_TX_SCRIPT_PAYLOAD_",mime:"application/vnd.cassini.transcript-words+json")
        let entry: JSON = .object([("id",.string("script")),("default",.bool(true)),("format",.string(CassiniReader.wordsFormat)),
            ("language",.string(language)),("wordCount",.number(String(wordCount))),("payloadRef",reference)])
        let root = try manifest.setting("transcripts",to:.array([entry]))
        let model = try ManifestParser.parse(root,formatMajor:1)
        _ = try chunkSet(root.encoded(),prefix:"CASSINI_PAYLOAD_",mime:"application/vnd.cassini.portable-meeting+json")
        let scalarTags: [(String,String)] = [
            ("CASSINI_FORMAT","org.cassini.portable-meeting/1"),("CASSINI_PROFILE","ogg-opus"),
            ("CASSINI_PAYLOAD_SCHEMA","https://format.gocassini.com/schema/cassini-portable-meeting-manifest-v1.schema.json"),
            ("CASSINI_TRANSCRIPT_IDS","script"),("CASSINI_TRANSCRIPT_DEFAULT","script"),
            ("CASSINI_AUDIO_SAMPLE_RATE","48000"),("CASSINI_AUDIO_CHANNELS",String(model.audio.channels)),
            ("CASSINI_AUDIO_SAMPLE_COUNT",String(model.audio.sampleCount)),("CASSINI_AUDIO_DURATION_MS",String(model.audio.durationMs)),
            ("CASSINI_AUDIO_MATCH_POLICY","exact-opus-audio-v1"),("CASSINI_AUDIO_OPUS_SHA256",model.integrity.opusAudioSha256),
            ("CASSINI_MEETING_ID",model.meeting.id),("CASSINI_CREATED_AT",model.meeting.createdAtUtc),
            ("CASSINI_SPEAKER_COUNT",String(model.speakers.count)),("TITLE",model.meeting.title)
        ]
        for (name,value) in scalarTags { comments.append(.init(name:name,value:value)) }
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
    private static func gzip(_ input: Data, shouldCancel: () -> Bool) throws -> Data {
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
