// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniLibrary

struct LibraryPreferencesTests {
    @Test func deviceLocalStarsAndChoiceSurviveRelaunchWithoutTouchingMeetings() throws {
        let suite = "CassiniStarsTest-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        var state = LibraryPreferences(defaults:defaults)
        #expect(state.filter == .all && state.starredKeys.isEmpty)
        state.toggle("Recording-abc"); state.toggle("Received-def")
        state.filter = .starred; state.save(to:defaults)
        let relaunched = LibraryPreferences(defaults:defaults)
        #expect(relaunched == state)
        // A refresh/missing row (including Trash) cannot erase a star.
        #expect(relaunched.starredKeys == ["Recording-abc","Received-def"])
        state.toggle("Recording-abc"); state.save(to:defaults)
        #expect(LibraryPreferences(defaults:defaults).starredKeys == ["Received-def"])
        let otherSuite = "CassiniStarsTest-" + UUID().uuidString
        let otherDevice = try #require(UserDefaults(suiteName:otherSuite))
        defer { otherDevice.removePersistentDomain(forName:otherSuite) }
        #expect(LibraryPreferences(defaults:otherDevice).starredKeys.isEmpty)
    }
}
