// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniLibrary

struct BrowserConnectionTests {
    @Test func liveLeasesAreIndependentAndUnknownOrMixedNamesStayGeneric() throws {
        let fixture = try Fixture(), root = fixture.root.appendingPathComponent("Connections")
        #expect(!BrowserCompanionConnection.snapshot(directory:root).connected)
        var first: BrowserCompanionConnection? = try .init(directory:root,browser:"Chrome")
        try first?.update(recordingDirectory:fixture.folder)
        var snapshot = BrowserCompanionConnection.snapshot(directory:root)
        #expect(snapshot.connected && snapshot.browser == "Chrome")
        #expect(snapshot.recordingDirectories == [LibraryLocation.canonical(fixture.folder).path])
        var second: BrowserCompanionConnection? = try .init(directory:root)
        snapshot = BrowserCompanionConnection.snapshot(directory:root)
        #expect(snapshot.connected && snapshot.browser == nil)
        first = nil
        #expect(BrowserCompanionConnection.snapshot(directory:root).connected)
        #expect(BrowserCompanionConnection.snapshot(directory:root).recordingDirectories.isEmpty)
        second = nil
        #expect(!BrowserCompanionConnection.snapshot(directory:root).connected)
        let stale = root.appendingPathComponent(UUID().uuidString + ".json")
        try Data("{\"version\":1,\"browser\":\"Chrome\"}".utf8).write(to:stale)
        #expect(!BrowserCompanionConnection.snapshot(directory:root).connected)
    }
}
