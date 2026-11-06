// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import Foundation
import CassiniKit
import CassiniBrowserControl

/// Uses the production decoder, with English synthetic evidence and no IPC.
enum BrowserCompanionFixture {
    static var kind: String? {
        guard MeetingRenameFixture.enabled, let kind = LibraryLaunchContext.argument("-CassiniBrowserCase"),
              ["health-ready","health-idle","health-reload","health-files","health-outdated","health-legacy"].contains(kind) else { return nil }
        return kind
    }
    static func peers(_ kind: String) -> [BrowserControlPeerSnapshot] {
        do {
            var registry = BrowserControlRegistry()
            let peer = UUID(uuidString:"b0000000-0000-4000-8000-000000000072")!
            let metadata = try JSONSerialization.data(withJSONObject:["version":1,"id":peer.uuidString,"role":"control","browser":"Chrome"])
            try registry.connect(JSONDecoder().decode(BrowserPeer.self,from:metadata))
            var hello: [String:Any] = ["type":"hello","version":1,"capabilities":["independent-sessions-v1","multi-stream-v1","tab-readiness-v1"],
                "extensionVersion":kind == "health-outdated" ? "0.2.19" : "0.2.20","extensionInstance":"synthetic-English-instance"]
            if kind != "health-legacy" { hello["filesOk"] = kind != "health-files" }
            try registry.receive(JSONSerialization.data(withJSONObject:hello),from:peer)
            let health: [String:Any] = ["state":kind == "health-reload" ? "reloadRequired" : kind == "health-ready" ? "ready" : "idle","worker":"ready","nativeControl":"connected",
                "tabs":kind == "health-reload" ? [["tabId":2,"state":"reloadRequired","hookSeen":true,"relayAlive":false,"action":"reloadMeetingTab"]] : kind == "health-ready" ? [["tabId":2,"state":"ready","hookSeen":true,"relayAlive":true]] : []]
            let status: [String:Any] = ["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready","sessions":[],"browserHealth":health]
            try registry.receive(JSONSerialization.data(withJSONObject:status),from:peer)
            return registry.snapshots
        } catch { preconditionFailure("Invalid synthetic companion snapshot: \(error)") }
    }
}
#endif
