// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
@testable import CassiniLibrary

/// D52 M1 lanes (GNOME docs/d52-source-grouping.md literal table, cassini-gnome
/// main) and the shared half-open ownership vectors.
struct D52PlacementTests {
    private func lanes(_ spans: [(String,String,Double?,Double?)]) -> [String:String] {
        SourceSpanLanes.assign(spans.map { .init(id:$0.0,base:$0.1,startMs:$0.2,endMs:$0.3) })
    }
    @Test func groupingLiterals() {
        let base = "track-receiver"
        #expect(lanes([("a",base,0,1000),("b",base,1000,2000),("c",base,2000,3000)]) == ["a":base,"b":base,"c":base])
        #expect(lanes([("a",base,0,2000),("b",base,1000,3000),("c",base,2000,3000)]) == ["a":base,"b":base+":overlap:1","c":base])
        #expect(lanes([("a",base,0,1000+1.0/48),("b",base,1000,2000)]) == ["a":base,"b":base+":overlap:1"])
        #expect(lanes([("a",base,0,1000),("b",base,nil,nil),("c",base,nil,nil)]) == ["a":base,"b":base+":overlap:1","c":base+":overlap:2"])
        #expect(lanes([("a",base,0,1000),("b",base,0,1000),("x",base+":overlap:1",0,1000)]) == ["a":base,"b":base+":overlap:2","x":base+":overlap:1"])
    }
    @Test func inputOrderNeverChangesTheAssignment() {
        let spans: [(String,String,Double?,Double?)] = [("a","t",0,2000),("b","t",1000,3000),("c","t",2000,3000),("d","t",nil,nil)]
        let expected = lanes(spans)
        #expect(lanes(spans.reversed()) == expected)
        #expect(lanes([spans[2],spans[0],spans[3],spans[1]]) == expected)
    }
    @Test func sharedOwnershipVectors() throws {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-protocol/conformance/multistream/ownership.json")
        let cases = try #require(try JSONParser.parse(Data(contentsOf:url))["cases"]?.array)
        #expect(cases.count == 2)
        for vector in cases {
            let name = vector["name"]!.string!
            let events = CaptureEvent.read(vector["events"])
            #expect(events.count == vector["events"]!.array!.count,"\(name): every event is valid")
            let ownership = try #require(OthersOwnership(events:events))
            var kinds: [String:String] = [:], extents: [String:(Double,Double)] = [:]
            for track in vector["tracks"]!.array! {
                let id = track["id"]!.string!
                kinds[id] = track["kind"]!.string!; extents[id] = (track["startMs"]!.double!,track["endMs"]!.double!)
                let owned = ownership.owned(kind:kinds[id],startMs:extents[id]!.0,endMs:extents[id]!.1)
                let expected = vector["expected"]![id]!.array!.map { ($0.array![0].double!,$0.array![1].double!) }
                #expect(owned.map(\.0) == expected.map(\.0) && owned.map(\.1) == expected.map(\.1),"\(name): \(id)")
            }
            for probe in vector["ownershipAt"]!.array! {
                let at = probe["atMs"]!.double!
                let owners = kinds.keys.filter { id in
                    ownership.owned(kind:kinds[id],startMs:extents[id]!.0,endMs:extents[id]!.1).contains { at >= $0.0 && at < $0.1 }
                }.sorted()
                #expect(owners == probe["ids"]!.array!.compactMap(\.string).sorted(),"\(name) at \(at)")
            }
        }
    }
    @Test func theMicrophoneIsNeverMaskedAndNoEventsMeansNoMask() {
        let ownership = OthersOwnership(events:[.init(atMs:0,type:"othersSource",source:"none",reason:"user")])!
        #expect(ownership.owned(kind:"microphone",startMs:0,endMs:5000).count == 1)
        #expect(ownership.owned(kind:"remote",startMs:0,endMs:5000).isEmpty)
        #expect(OthersOwnership(events:[]) == nil)
    }
}
