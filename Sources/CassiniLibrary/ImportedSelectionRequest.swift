// SPDX-License-Identifier: GPL-3.0-or-later
/// A one-shot sidebar reveal, retained until the imported row is published.
public struct ImportedSelectionRequest {
    public private(set) var key: String?

    public init() {}

    public mutating func request(_ key: String) { self.key = key }
    public mutating func reset() { key = nil }

    public mutating func consume(_ target: String) {
        // Revealing a failed-import card must not consume the meeting reveal.
        if key == target { reset() }
    }

    public mutating func selectionChanged(to keys: Set<String>, awaitingPublication: Bool) {
        // Switching Starred to All can temporarily remove the selection before
        // the watcher publishes the imported folder.
        if !awaitingPublication, let key, keys != [key] { reset() }
    }
}
