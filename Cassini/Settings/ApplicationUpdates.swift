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
    @ObservationIgnored private var installation: (() -> Void)?
    private var terminating = false
    enum Activity: Hashable { case recording, starting, saving, transcription, importing, exporting, moving, renaming, trashing, editing, scanning }
    #if DEBUG
    @ObservationIgnored private var fixtureActivity: (() -> Set<Activity>)?
    @ObservationIgnored private var pollInterval: Duration = .seconds(1)
    #endif
    private(set) var available = false
    private var updaterCanCheck = false
    var canCheckForUpdates: Bool { updaterCanCheck && !readyWhenIdle && !terminating }
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

    var activity: Set<Activity> {
        #if DEBUG
        if let fixtureActivity { return fixtureActivity() }
        #endif
        var result: Set<Activity> = []
        if RecordingOverview.active { result.insert(.recording) }
        if RecordingOverview.starting { result.insert(.starting) }
        if RecordingOverview.saving { result.insert(.saving) }
        if TranscriptionQueue.shared.isBusy { result.insert(.transcription) }
        if LibraryImportCoordinator.shared.isBusy { result.insert(.importing) }
        if MeetingExportCoordinator.shared.isBusy { result.insert(.exporting) }
        if LibraryMoveCoordinator.shared.busy { result.insert(.moving) }
        if MeetingRenameCoordinator.shared.working { result.insert(.renaming) }
        if MeetingTrashCoordinator.shared.busy { result.insert(.trashing) }
        if RecordingPageModel.hasPendingEdits { result.insert(.editing) }
        if LibraryStore.shared.isRefreshing { result.insert(.scanning) }
        return result
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock handler: @escaping () -> Void) -> Bool {
        guard terminating || !activity.isEmpty else { return false }
        // Dismiss Sparkle's installation UI while retaining its continuation.
        controller?.userDriver.dismissUpdateInstallation()
        installation = handler
        readyWhenIdle = true
        waitForIdle()
        return true
    }

    private func waitForIdle() {
        waiting?.cancel(); waiting = nil
        guard !terminating, installation != nil else { return }
        waiting = Task { @MainActor [weak self] in
            while let self, !self.activity.isEmpty {
                #if DEBUG
                let interval = self.pollInterval
                #else
                let interval: Duration = .seconds(1)
                #endif
                do { try await Task.sleep(for:interval) } catch { return }
            }
            guard !Task.isCancelled, let self, !self.terminating else { return }
            let handler = self.installation
            self.installation = nil; self.waiting = nil; self.readyWhenIdle = false
            handler?()
        }
    }

    // Hold even while the Quit confirmation is open. Stop-and-keep can make
    // every activity idle before AppKit finishes the termination handshake.
    func beginTermination() { terminating = true; waiting?.cancel(); waiting = nil }
    func cancelTermination() { terminating = false; waitForIdle() }
    func finishTermination() {
        beginTermination(); installation = nil; readyWhenIdle = false
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
    static func fixture(_ controller: SPUStandardUpdaterController, activity: (() -> Set<Activity>)? = nil, canCheck: Bool? = nil) -> ApplicationUpdates {
        precondition(SettingsFixture.id != nil)
        let updates = ApplicationUpdates()
        updates.fixtureActivity = activity; updates.pollInterval = .milliseconds(10)
        updates.attach(controller)
        if let canCheck { updates.updaterCanCheck = canCheck }
        return updates
    }
    #endif
}
