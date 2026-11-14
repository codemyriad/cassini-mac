// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D99: device-local state only. Never stored beside meetings or passed to exporters.
/// Keys use the Library's stable folder identity, so rename and Library moves retain stars.
public struct LibraryPreferences: Equatable, Sendable {
    public enum Filter: String, Sendable { case all, starred }
    public var filter: Filter = .all
    public var starredKeys: Set<String> = []
    private static let key = "CassiniLibraryPreferences-v1"
    public init(defaults: UserDefaults) {
        let state = defaults.dictionary(forKey:Self.key) ?? [:]
        filter = (state["filter"] as? String).flatMap(Filter.init(rawValue:)) ?? .all
        starredKeys = Set(state["stars"] as? [String] ?? [])
    }
    public func save(to defaults: UserDefaults) {
        defaults.set(["filter":filter.rawValue,"stars":starredKeys.sorted()],forKey:Self.key)
    }
    public mutating func toggle(_ key: String) {
        if !starredKeys.insert(key).inserted { starredKeys.remove(key) }
    }
}
