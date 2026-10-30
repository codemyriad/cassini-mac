// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Sparkle

/// Sparkle owns its update preferences and permission prompt. Placeholder feeds
/// stay dormant, including in CI; a release must supply the approved HTTPS feed.
@MainActor final class ApplicationUpdates {
    static let shared = ApplicationUpdates()
    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil,
              ["YES", "true", "1"].contains(Bundle.main.object(forInfoDictionaryKey: "CassiniUpdatesEnabled") as? String ?? ""),
              let text = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: text), url.scheme == "https", url.host != nil,
              !text.contains("PLACEHOLDER") else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }
}
