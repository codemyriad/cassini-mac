import Foundation

enum UXText {
    private struct Catalog: Decodable { let entries: [Entry] }
    private struct Entry: Decodable { let id: String; let en: String; let mac: String? }
    private static let values: [String: String] = {
        let url = Bundle.main.url(forResource: "strings", withExtension: "json", subdirectory: "UX")!
        let catalog = try! JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        return Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, $0.mac ?? $0.en) })
    }()
    static func text(_ id: String, _ values: [String: String] = [:]) -> String {
        guard var text = self.values[id] else { preconditionFailure("Missing shared UX string: \(id)") }
        for (key, value) in values { text = text.replacingOccurrences(of: "{\(key)}", with: value) }
        return text
    }
}
