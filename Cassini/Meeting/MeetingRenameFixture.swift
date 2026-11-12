// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Writable copies for hosted UI tests, never the sealed app resources or a
/// user's Library. Production and ordinary screenshot launches cannot enable it.
enum MeetingRenameFixture {
    static var enabled: Bool {
        #if DEBUG
        id != nil
        #else
        false
        #endif
    }
    #if DEBUG
    static var id: UUID? {
        let env = ProcessInfo.processInfo.environment
        guard env["CASSINI_HOSTED_SCREENSHOTS"] == "1", CommandLine.arguments.contains("--fixture-library-rename"),
              let value = LibraryLaunchContext.argument("-CassiniRenameID") else { return nil }
        return UUID(uuidString:value)
    }
    static let root: URL? = {
        guard let id else { return nil }
        let name = LibraryLaunchContext.argument("-CassiniFixture").map { URL(fileURLWithPath:$0).lastPathComponent } ?? "main"
        guard ["main","received-only"].contains(name) else { return nil }
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Fixtures/Library/" + name + "/root")
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniRenameFixture-" + id.uuidString,isDirectory:true)
        let root = parent.appendingPathComponent("root",isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            if !FileManager.default.fileExists(atPath:root.path) { try FileManager.default.copyItem(at:source,to:root) }
            if CommandLine.arguments.contains("--fixture-library-no-words") {
                // This meeting in the sealed main vector is complete. Only this
                // private writable copy becomes an untranscribed recording.
                let meeting = root.appendingPathComponent("Recording-a0000000-0000-4000-8000-000000000008")
                let metadata = meeting.appendingPathComponent("meeting.json")
                guard var value = try JSONSerialization.jsonObject(with:Data(contentsOf:metadata)) as? [String:Any] else { return nil }
                value["transcript"] = ["status":"none"]
                value["etaMinutes"] = NSNull(); value["error"] = NSNull()
                try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:metadata,options:.atomic)
                let sidecar = meeting.appendingPathComponent("transcript.json")
                if FileManager.default.fileExists(atPath:sidecar.path) { try FileManager.default.removeItem(at:sidecar) }
            }
            if CommandLine.arguments.contains("--fixture-library-many-sources") {
                // A large call for Recording details: more source rows than the sheet can show at once.
                let metadata = root.appendingPathComponent("Recording-a0000000-0000-4000-8000-000000000001/meeting.json")
                guard var value = try JSONSerialization.jsonObject(with:Data(contentsOf:metadata)) as? [String:Any] else { return nil }
                let sources: [[String:Any]] = (1...40).map {
                    ["sourceTrackId":"guest-\($0)","kind":"remote","label":"Guest \($0)","captureOutcome":"captured","audioMs":60000 * $0,"trackIds":[String]()]
                }
                value["recordingDetails"] = ["captureRecord":["version":1,"sources":sources],"end":["reason":"callEnded","atMs":2_400_000]]
                try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:metadata,options:.atomic)
            }
            if CommandLine.arguments.contains("--fixture-library-seven-speakers") {
                // Wave 1 palette coverage: 7 speakers (6 named across speaker-1..6 + 1 unnamed in speaker-0 stone)
                // plus an inline aside chip so avatar-* washes and speaker-* inks render together.
                let meeting = root.appendingPathComponent("Recording-a0000000-0000-4000-8000-000000000001")
                let metadata = meeting.appendingPathComponent("meeting.json")
                guard var value = try JSONSerialization.jsonObject(with:Data(contentsOf:metadata)) as? [String:Any] else { return nil }
                value["speakers"] = [
                    ["id":"marta","name":"Marta","provenance":"user","colourIndex":0],
                    ["id":"dario","name":"Dario","provenance":"recognised","colourIndex":1],
                    ["id":"giulia","name":"Giulia","provenance":"user","colourIndex":2],
                    ["id":"elena","name":"Elena","provenance":"user","colourIndex":3],
                    ["id":"lucas","name":"Lucas","provenance":"user","colourIndex":4],
                    ["id":"nadia","name":"Nadia","provenance":"user","colourIndex":5],
                    ["id":"guest","name":NSNull(),"provenance":"unnamed","colourIndex":6],
                ]
                value["quoteOverride"] = NSNull()
                try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:metadata,options:.atomic)
                let sidecar = meeting.appendingPathComponent("transcript.json")
                let transcript: [String:Any] = [
                    "format":"cassini.words.v1",
                    "language":"en",
                    "items":[
                        ["speaker":"marta","startMs":4000,"endMs":7000,"text":"Let’s start with the budget,"],
                        ["speaker":"giulia","startMs":7100,"endMs":7800,"text":"Yes, agreed."],
                        ["speaker":"marta","startMs":7900,"endMs":11000,"text":"since travel is the one line we need to settle today."],
                        ["speaker":"dario","startMs":12000,"endMs":17000,"text":"I sent the numbers on Friday. Client visits moved the total."],
                        ["speaker":"giulia","startMs":18000,"endMs":23000,"text":"Both September workshops came in under the cap."],
                        ["speaker":"elena","startMs":24000,"endMs":29000,"text":"Engineering hardware stayed flat for the whole quarter."],
                        ["speaker":"lucas","startMs":30000,"endMs":35000,"text":"Support renewals renew in January on the same terms."],
                        ["speaker":"nadia","startMs":36000,"endMs":41000,"text":"Marketing kept the event budget inside the reserve."],
                        ["speaker":"guest","startMs":42000,"endMs":47000,"text":"Then we keep travel at twelve thousand and review in January."],
                    ],
                ]
                try JSONSerialization.data(withJSONObject:transcript,options:[.sortedKeys]).write(to:sidecar,options:.atomic)
            }
            return root
        } catch { return nil }
    }()
    #endif
}
