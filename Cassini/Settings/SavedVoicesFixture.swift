// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import Foundation
import CassiniLibrary

/// Generated profiles in the explicit Settings fixture's private store.
/// Production data and model installation are never used or changed.
@MainActor enum SavedVoicesFixture {
    private static var preparation: Task<Void,Error>?
    static func prepare(_ store: SavedVoicesStore) async throws {
        guard SettingsFixture.id != nil, LibraryLaunchContext.argument("-CassiniSavedVoicesFixture") == "YES" else { return }
        if let preparation { try await preparation.value; return }
        let root = SpeechModelController.appData
        let task = Task {
            let marker = root.appendingPathComponent("voices-fixture-seeded")
            if await Task.detached(operation:{ FileManager.default.fileExists(atPath:marker.path) }).value { return }
            let generation = try await store.snapshot().generation
            for (index,name) in ["Marta","Giulia Rossi","Dario","Luca"].enumerated() {
                _ = try await store.enroll(name:name,embedding:[Float](repeating:Float(index+1),count:512),seconds:5,generation:generation,
                    clip:.init(meeting:"Recording-a0000000-0000-4000-8000-000000000001",speaker:"fixture-\(index)",startMs:0,endMs:5000))
            }
            try await Task.detached {
                let file = root.appendingPathComponent("voices/people.json")
                var document = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
                var rows = document["voices"] as! [[String:Any]]
                let index = rows.firstIndex { $0["name"] as? String == "Luca" }!
                rows[index]["model"] = String(repeating:"0",count:64)
                document["voices"] = rows
                try JSONSerialization.data(withJSONObject:document,options:[.sortedKeys]).write(to:file,options:.atomic)
                try Data().write(to:marker,options:.atomic)
            }.value
        }
        preparation = task; try await task.value
    }
}
#endif
