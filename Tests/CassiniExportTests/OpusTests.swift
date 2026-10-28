// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniLibrary
@testable import CassiniExport

struct OpusTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"] != nil)) func realPinnedEncoderAndFrameGuards() throws {
        let directory = URL(fileURLWithPath:ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"]!)
        let hashes = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:directory.appendingPathComponent("unsigned-sha256.json")))
        let hash = try #require(hashes["libopus.0.dylib"])
        let assets = try OpusAssets.builtForTests(directory:directory,expectedBinarySHA256:hash)
        let encoder = try OpusEncoder(assets:assets,choice:AudioEncodeChoice.choose([]))
        #expect(encoder.preSkip > 0 && encoder.preSkip < 960)
        let frame = (0..<960).map { Float(0.2 * sin(Double($0) * 2 * .pi * 440 / 48000)) }
        let packet = try encoder.encode(frame)
        #expect(packet.count > 1 && packet.count <= 1276)
        #expect(packet[0] & 4 == 0) // The Opus TOC declares mono.
        #expect(throws:(any Error).self) { try encoder.encode(Array(frame.dropLast())) }
        #expect(throws:(any Error).self) { try encoder.encode([Float](repeating:.nan,count:960)) }
        #expect(throws:(any Error).self) { try OpusAssets.builtForTests(directory:directory,expectedBinarySHA256:String(repeating:"0",count:64)) }
    }
}
