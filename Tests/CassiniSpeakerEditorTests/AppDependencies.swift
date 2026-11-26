// SPDX-License-Identifier: GPL-3.0-or-later
// Minimal app services for exercising the production coordinator without a window,
// global Library, model inference, or the user's Saved voices directory.
import AppKit
import CassiniLibrary

@MainActor final class LibraryMoveCoordinator {
    static let shared=LibraryMoveCoordinator()
    var busy=false
    func maybeRetryDeferred() {}
}
@MainActor final class MeetingTrashCoordinator {
    static let shared=MeetingTrashCoordinator()
    var busy=false
}
@MainActor final class MeetingDateTimeCoordinator {
    static let shared=MeetingDateTimeCoordinator()
    var working=false
}
@MainActor final class LibraryLocationModel {
    static let shared=LibraryLocationModel()
    var location=LibraryLocation(primary:FileManager.default.temporaryDirectory)
    var available=true
    var roots:[URL] { [location.primary] }
}
@MainActor final class LibraryStore {
    static let shared=LibraryStore()
    struct Context { var screenshot=false }
    var context=Context()
    var offline=false
    var selected:LibraryMeeting?
    func scannerForRename(_ meeting:LibraryMeeting)->LibraryScanner? {nil}
    func refresh(affected:URL) {}
}
@MainActor final class LibrarySearchModel {
    static let shared=LibrarySearchModel()
    var visible=false, searching=false
    var selected:String?
    func meeting(_ id:String)->LibraryMeeting? {nil}
}
@MainActor final class MeetingNavigation {
    static let shared=MeetingNavigation()
    var detail:Detail?
    final class Detail {
        var meeting:LibraryMeeting
        var fileURL:URL?
        var namingSpeakerID:String?
        let speakerSample=Sample()
        init(_ meeting:LibraryMeeting) {self.meeting=meeting}
    }
    final class Sample { func cancel() {} }
}
@MainActor enum UXText {
    static var locale: Locale { Locale(identifier: "en_GB") }
    static var language: CassiniLanguage { .en }
    static func text(_ key:String)->String {key}
}
@MainActor enum MeetingRenameFixture { static let enabled=false }
@MainActor final class SavedVoicesController {
    static let shared=SavedVoicesController()
    var store=SavedVoicesStore(directory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    var snapshot:SavedVoicesSnapshot?
    var readOnly=false
    var voices:[SavedVoice] {snapshot?.voices ?? []}
    struct TranscriptEnrollment:Sendable {
        let embedding:[Float]
        var seconds:Double = 5
        var generation:Int64 = 0
        var clip:VoiceClip? = nil
    }
    var refreshAction: (@MainActor () async -> Void)?
    var prepareAction: (@MainActor (LibraryMeeting, String) async throws -> TranscriptEnrollment?)?
    var enrollAction: (@MainActor (TranscriptEnrollment, String, String?) async throws -> SavedVoicesStore.ContributionBackup?)?
    var prepared: TranscriptEnrollment?
    func refresh() async { await refreshAction?() }
    func prepare(_ meeting:LibraryMeeting,speaker:String) async throws -> TranscriptEnrollment? {
        if let prepareAction { return try await prepareAction(meeting, speaker) }
        return prepared
    }
    @discardableResult func enroll(_ prepared:TranscriptEnrollment,name:String,into id:String?) async throws -> SavedVoicesStore.ContributionBackup? {
        if let enrollAction { return try await enrollAction(prepared, name, id) }
        throw SavedVoicesError.unsafeStorage
    }
}

// The production preference policy uses an isolated defaults suite in this harness.
extension VoicePreferences {
    static var shared=VoicePreferences(defaults:UserDefaults(suiteName:"io.codemyriad.cassini.speaker-tests." + UUID().uuidString)!)
}
