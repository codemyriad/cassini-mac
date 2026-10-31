// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AppKit
import Observation
import Sparkle

/// Sparkle owns its update preferences and permission prompt. Placeholder feeds
/// stay dormant, including in CI; a release must supply the approved HTTPS feed.
@MainActor @Observable final class ApplicationUpdates: NSObject, SPUUpdaterDelegate {
    static let shared = ApplicationUpdates()
    @ObservationIgnored private var waiting: Task<Void, Never>?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    private(set) var available = false
    private var updaterCanCheck = false
    var canCheckForUpdates: Bool { updaterCanCheck && !readyWhenIdle }
    private(set) var readyWhenIdle = false
    private var automaticCheckSnapshot = false
    var automaticChecks: Bool {
        get { automaticCheckSnapshot }
        set {
            guard let updater = controller?.updater else { return }
            updater.automaticallyChecksForUpdates = newValue
            refreshPreferences()
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    private func refreshPreferences() {
        available = controller != nil
        updaterCanCheck = controller?.updater.canCheckForUpdates ?? false
        automaticCheckSnapshot = controller?.updater.automaticallyChecksForUpdates ?? false
    }

    private var busy: Bool {
        RecordingOverview.active || RecordingOverview.starting || RecordingOverview.saving || TranscriptionQueue.shared.isBusy ||
        LibraryImportCoordinator.shared.isBusy || MeetingExportCoordinator.shared.isBusy ||
        LibraryMoveCoordinator.shared.busy || MeetingRenameCoordinator.shared.working ||
        MeetingTrashCoordinator.shared.busy || RecordingPageModel.hasPendingEdits || LibraryStore.shared.isRefreshing
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock handler: @escaping () -> Void) -> Bool {
        guard busy else { return false }
        // Sparkle's installer retains the continuation below. Its public user
        // driver dismissal closes the now button-less status window without
        // cancelling that pending installation or touching recording inputs.
        controller?.userDriver.dismissUpdateInstallation()
        readyWhenIdle = true
        waiting?.cancel()
        waiting = Task { @MainActor [weak self] in
            while let self, self.busy {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard !Task.isCancelled, self != nil else { return }
            self?.readyWhenIdle = false
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
        attach(SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil))
    }

    private func attach(_ controller: SPUStandardUpdaterController) {
        self.controller = controller
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates) { [weak self] _,_ in Task { @MainActor in self?.refreshPreferences() } },
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] _,_ in Task { @MainActor in self?.refreshPreferences() } }
        ]
        refreshPreferences()
    }

    #if DEBUG
    static func fixture(_ controller: SPUStandardUpdaterController) -> ApplicationUpdates {
        precondition(SettingsFixture.id != nil)
        let updates = ApplicationUpdates()
        updates.attach(controller)
        return updates
    }
    #endif
}
