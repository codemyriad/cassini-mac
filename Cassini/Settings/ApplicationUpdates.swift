// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Sparkle

/// Sparkle owns its update preferences and permission prompt. Placeholder feeds
/// stay dormant, including in CI; a release must supply the approved HTTPS feed.
@MainActor final class ApplicationUpdates: NSObject, SPUUpdaterDelegate {
    static let shared = ApplicationUpdates()
    private var waiting: Task<Void, Never>?
    private var controller: SPUStandardUpdaterController?

    private var busy: Bool {
        RecordingOverview.active || RecordingOverview.saving || TranscriptionQueue.shared.isBusy ||
        LibraryImportCoordinator.shared.isBusy || MeetingExportCoordinator.shared.isBusy ||
        LibraryMoveCoordinator.shared.busy || MeetingRenameCoordinator.shared.working ||
        MeetingTrashCoordinator.shared.busy || RecordingPageModel.hasPendingEdits
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock handler: @escaping () -> Void) -> Bool {
        guard busy else { return false }
        waiting?.cancel()
        waiting = Task { @MainActor [weak self] in
            while let self, self.busy {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard !Task.isCancelled, self != nil else { return }
            handler()
        }
        return true
    }

    func start() {
        guard controller == nil,
              ["YES", "true", "1"].contains(Bundle.main.object(forInfoDictionaryKey: "CassiniUpdatesEnabled") as? String ?? ""),
              let text = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: text), url.scheme == "https", url.host != nil,
              !text.contains("PLACEHOLDER") else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }
}
