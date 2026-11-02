// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
@testable import CassiniBrowserControl

final class SharedAutoStartVectorTests: XCTestCase {
    func testSharedAutomaticAndManualStartVectors() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = ProcessInfo.processInfo.environment["CASSINI_AUTO_START_VECTORS"].map { URL(fileURLWithPath:$0) }
            ?? root.appendingPathComponent("browser-protocol/conformance/control/auto-start-vectors.json")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [[String:Any]])
        XCTAssertFalse(cases.isEmpty)
        for vector in cases {
            let name = try XCTUnwrap(vector["name"] as? String)
            let capabilities = try XCTUnwrap(vector["capabilities"] as? [String])
            let meeting = try XCTUnwrap(vector["meeting"] as? [String:Any])
            let expected = try XCTUnwrap(vector["expect"] as? [String:Bool])
            let automaticExpected = try XCTUnwrap(expected["automatic"])
            let tab = try XCTUnwrap(meeting["tabId"] as? Int)
            let peer = UUID()
            // D52.5: recordings the app already holds, seeded before the hello. Lost ones match
            // by (tabId, callGeneration) whatever control peer they started under.
            let recordings = vector["recordings"] as? [[String:Any]] ?? []
            let lost = recordings.filter { ($0["othersSource"] as? [String:String]) == ["source":"system","reason":"lost"] }
            func fresh() throws -> BrowserControlRegistry {
                var state = BrowserControlRegistry()
                state.setLostCalls(Set(lost.compactMap { row in (row["tabId"] as? Int).map { BrowserControlRegistry.LostCall(tabID:$0,callGeneration:row["callGeneration"] as? String) } }))
                try state.connect(.init(id:peer,role:.control,browser:"Chrome"))
                for message: [String:Any] in [
                    ["type":"hello","version":1,"capabilities":capabilities],
                    ["type":"meetings","meetings":[meeting]],
                    ["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready","sessions":[]]
                ] { try state.receive(JSONSerialization.data(withJSONObject:message),from:peer) }
                return state
            }
            var automatic = try fresh()
            XCTAssertEqual(automatic.automaticStarts(microphone:false).count, automaticExpected ? 1 : 0,
                           "\(name): automatic, capabilities=\(capabilities)")
            // A separate production registry avoids an automatic request's
            // pending-start guard interfering with the manual expectation.
            var manual = try fresh()
            let request = try? manual.start(.init(peer:peer,tabID:tab),microphone:false)
            XCTAssertEqual(request != nil,try XCTUnwrap(expected["manual"]),
                           "\(name): manual, capabilities=\(capabilities)")
            // Resume: each lost recording's own policy sees the call's row (same tab and call
            // generation, as the app matches it) with its transport closed, and asks once.
            var asks = 0
            for recording in lost {
                guard recording["tabId"] as? Int == tab, let generation = recording["callGeneration"] as? String,
                      generation == meeting["callGeneration"] as? String else { continue }
                var policy = BrowserCallPolicy(resumeCapture:capabilities.contains("resume-capture-v1"),callGeneration:generation,
                                               heard:recording["heardSeen"] as? Bool ?? false)
                let row = BrowserCallPolicy.Observation(page:(meeting["pageState"] as? String).flatMap(BrowserCallLifecycle.Page.init(rawValue:)) ?? .present,
                    sourceCount:meeting["sourceCount"] as? Int,sourceCountKnown:meeting["sourceCountKnown"] as? Bool ?? true,
                    heard:meeting["heard"] as? Bool ?? false,transportAlive:false,callGeneration:meeting["callGeneration"] as? String)
                asks += policy.steps(now:0,row,source:"system",reason:"lost").filter { $0 == .askResume }.count
            }
            XCTAssertEqual(asks,expected["resume"] == true ? 1 : 0,"\(name): resume")
        }
    }
}
