// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum UXText {
    private struct Catalog: Decodable { let entries: [Entry] }
    private struct Entry: Decodable { let id: String; let en: String; let mac: String?; let plural: [String:String]? }
    private static let catalog: Catalog = {
        let url = Bundle.main.url(forResource:"strings",withExtension:"json",subdirectory:"UX")!
        return try! JSONDecoder().decode(Catalog.self,from:Data(contentsOf:url))
    }()
    private static let values = Dictionary(uniqueKeysWithValues:catalog.entries.map { ($0.id,$0.mac ?? $0.en) })
    private static let plurals = Dictionary(uniqueKeysWithValues:catalog.entries.compactMap { entry in entry.plural.map { (entry.id,$0) } })
    static func text(_ id: String, _ values: [String: String] = [:]) -> String {
        guard var text = self.values[id] else { preconditionFailure("Missing shared UX string: \(id)") }
        if let count = values["n"].flatMap(Int.init), let plural = plurals[id]?[count == 1 ? "one" : "other"] { text = plural }
        for (key, value) in values { text = text.replacingOccurrences(of: "{\(key)}", with: value) }
        return text
    }
}
