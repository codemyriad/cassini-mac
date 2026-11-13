// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

/// WP7 UI state only. Preparing a notice does not consume its first appearance.
@MainActor @Observable final class ImportedMeetingNotice {
    struct Candidate: Equatable, Identifiable {
        let id: UUID
        let folderName: String?
    }
    struct Visibility {
        var appIsActive: Bool
        var isKeyWindow: Bool
        var hasSheet: Bool
        var contentIsVisible: Bool
        var permitsNotice: Bool { appIsActive && isKeyWindow && !hasSheet && contentIsVisible }
    }
    private(set) var notice: Candidate?
    #if DEBUG
    /// Read-only delivery observation for hosted UI assertions; never a decision input.
    private(set) var evaluatedMeetingID: UUID?
    #endif
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func update(candidate: Candidate?, visibility: Visibility) {
        #if DEBUG
        defer {
            let evaluated = visibility.permitsNotice ? candidate?.id : nil
            if evaluatedMeetingID != evaluated { evaluatedMeetingID = evaluated }
        }
        #endif
        guard visibility.permitsNotice, let candidate else { setNotice(nil); return }
        // A receipt already on screen stays until dismissed or navigation changes,
        // including after didAppear has persisted its seen flag.
        if notice?.id == candidate.id { setNotice(candidate); return }
        setNotice(defaults.bool(forKey: key(candidate.id)) ? nil : candidate)
    }

    /// Called by the rendered notice, with freshly read window/sheet visibility.
    /// Late callbacks from a previous meeting must not consume or dismiss another.
    func didAppear(_ id: UUID, visibility: Visibility) {
        guard notice?.id == id else { return }
        guard visibility.permitsNotice else { setNotice(nil); return }
        defaults.set(true, forKey: key(id))
    }

    func dismiss(_ id: UUID) {
        if notice?.id == id { setNotice(nil) }
    }

    private func setNotice(_ candidate: Candidate?) {
        if notice != candidate { notice = candidate }
    }

    private func key(_ id: UUID) -> String {
        "CassiniImportedNoticeShown." + id.uuidString.lowercased()
    }
}
