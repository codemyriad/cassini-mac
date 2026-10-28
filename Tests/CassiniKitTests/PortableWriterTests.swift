// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniKit

struct PortableWriterTests {
    private func source() throws -> Data {
        let root = try #require(Bundle.module.url(forResource:"Conformance",withExtension:nil))
        return try Data(contentsOf:root.appendingPathComponent("opus/001-minimal-v1.opus"))
    }
    @Test func retagKeepsAudioAndPublishesAnEmptyReadableBody() throws {
        let input = try source(), original = try CassiniReader.read(input)
        let manifest = try #require(original.manifest?.raw)
        let tags = try PortableMeetingTags.make(manifest:manifest,transcript:Data("{\"language\":\"auto\",\"items\":[]}".utf8),wordCount:0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".opus")
        defer { try? FileManager.default.removeItem(at:url) }
        let digest = try OpusStreamFile.rewrite(input,tags:tags,to:url)
        let output = try CassiniReader.read(contentsOf:url)
        #expect(output.state == .ok && output.errors.isEmpty)
        #expect(try output.audioDigest?.get() == digest)
        #expect(try original.audioDigest?.get() == digest)
        #expect(output.defaultTranscript?.load.transcript?.items.isEmpty == true)
        #expect(output.tags?["CASSINI_PAYLOAD_SHA256"] != original.tags?["CASSINI_PAYLOAD_SHA256"])
    }
    @Test func exactLacingAndAudioPageBoundariesFinishCleanly() throws {
        let overhead = try PortableMeetingTags.packet(comments:[.init(name:"X",value:"")]).count
        let tags = try PortableMeetingTags.packet(comments:[.init(name:"X",value:String(repeating:"a",count:65025 - overhead))])
        #expect(tags.count == 65025)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".opus")
        defer { try? FileManager.default.removeItem(at:url) }
        let writer = try OpusPacketWriter(url:url,head:OpusPacketWriter.monoHead(preSkip:312),tags:tags)
        for _ in 0..<50 { try writer.append(Data([0xf8,0xff,0xfe])) }
        try writer.finish(sampleCount:48000 - 312)
        let output = try CassiniReader.read(contentsOf:url)
        let digest = try #require(try output.audioDigest?.get())
        #expect(digest.packetCount == 50 && digest.sampleCount == 48000 - 312)
        #expect(output.tags?["X"]?.count == 65025 - overhead)
    }
    @Test func unknownExtensionNumbersSurviveWithoutFloatingPointRounding() throws {
        let value = try JSONParser.parse(Data("{\"x\":{\"other.example\":{\"integer\":9007199254740993,\"huge\":1e999}}}".utf8))
        #expect(try JSONParser.parse(value.encoded()) == value)
        #expect(throws:(any Error).self) { try JSON.number("1,\"injected\":true").encoded() }
        #expect(throws:(any Error).self) { try value.encoded(maximumBytes:10) }
    }
}
