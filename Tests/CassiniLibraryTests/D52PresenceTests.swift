// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
@testable import CassiniLibrary

/// D52.2 shared presence vectors (conformance/gaps/presence.json) through the Mac helper.
struct D52PresenceTests {
    @Test func sharedPresenceVectors() throws {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-protocol/conformance/gaps/presence.json")
        let cases = try #require(try JSONParser.parse(Data(contentsOf:url))["cases"]?.array)
        #expect(cases.count == 11)
        for vector in cases {
            let name = vector["name"]!.string!, track = vector["track"]!
            let gaps: [TrackPresence.Gap]? = track["gaps"]?.array.map { rows in rows.map {
                .init(atMs:$0["atMs"]!.double!,durationMs:$0["durationMs"]?.double,frames:$0["frames"]?.int.map(UInt64.init),kind:$0["kind"]!.string!) } }
            let ownership = vector["ownership"]?.array?.map { (start:$0.array![0].double!,end:$0.array![1].double!) }
            let result = TrackPresence.windows(startOffsetMs:track["startOffsetMs"]!.double!,sampleRate:track["sampleRate"]!.int!,
                                               frames:UInt64(track["frames"]!.int!),gaps:gaps,ownership:ownership)
            func ranges(_ key: String) -> [[Int]] { vector["expected"]![key]!.array!.map { $0.array!.map { $0.int! } } }
            #expect(TrackPresence.samples16k(result.present).map { [$0.lowerBound,$0.upperBound] } == ranges("present"),"\(name) present")
            #expect(TrackPresence.samples16k(result.unknown).map { [$0.lowerBound,$0.upperBound] } == ranges("unknown"),"\(name) unknown")
        }
    }
}
