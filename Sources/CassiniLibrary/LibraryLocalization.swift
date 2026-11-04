// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum CassiniLanguage: String, CaseIterable, Sendable {
    case en, it, fr, es
    case ptBR = "pt-BR", ptPT = "pt-PT"

    /// D50.1: bare Portuguese is Brazilian; every other Portuguese region is European.
    public init(languageTag: String) {
        let locale = Locale(identifier: languageTag.replacingOccurrences(of: "_", with: "-"))
        switch locale.language.languageCode?.identifier.lowercased() {
        case "it": self = .it
        case "fr": self = .fr
        case "es": self = .es
        case "pt": self = locale.language.region == nil || locale.language.region?.identifier.uppercased() == "BR" ? .ptBR : .ptPT
        default: self = .en
        }
    }
    public static var system: Self { .init(languageTag: Locale.preferredLanguages.first ?? "en") }
    public var pluralCategories: Set<String> { self == .en ? ["one", "other"] : ["one", "many", "other"] }

    /// CLDR cardinal rules for ordinary decimal quantities, including visible zeros.
    /// https://www.unicode.org/cldr/charts/latest/supplemental/language_plural_rules.html
    public func pluralCategory(_ literal: String) -> String {
        guard let number = Quantity(literal) else { return "other" }
        switch self {
        case .fr, .ptBR:
            if number.integer == 0 || number.integer == 1 { return "one" }
        case .es:
            if number.value == 1 { return "one" }
        case .en, .it, .ptPT:
            if number.integer == 1 && number.fractionDigits == 0 { return "one" }
        }
        if self != .en, number.fractionDigits == 0, number.integer != 0 {
            var divided = number.integer / 1_000_000, whole = Decimal()
            NSDecimalRound(&whole, &divided, 0, .down)
            if whole * 1_000_000 == number.integer { return "many" }
        }
        return "other"
    }
}

private struct Quantity {
    let value: Decimal, integer: Decimal, fractionDigits: Int
    init?(_ literal: String) {
        var input = literal[...]
        if input.first == "-" || input.first == "+" { input.removeFirst() }
        let parts = input.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts.allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let parsed = Decimal(string: String(input), locale: Locale(identifier: "en_US_POSIX")), !parsed.isNaN else { return nil }
        value = parsed; fractionDigits = parts.count == 2 ? parts[1].count : 0
        var temporary = parsed, whole = Decimal()
        NSDecimalRound(&whole, &temporary, 0, .down); integer = whole
    }
}

/// Shared bytes are embedded unchanged. Templates are tokenized once; inserted
/// titles containing another placeholder remain verbatim and are never evaluated.
public struct LibraryLocalization: Sendable {
    public struct Translation: Decodable, Sendable {
        public let text: String
        public let mac: String?
        public let plural: [String: String]?
    }
    public struct Entry: Decodable, Sendable {
        public let id: String, en: String
        public let mac: String?
        public let plural: [String: String]?
        public let l10n: [String: Translation]?
    }
    private struct Catalog: Decodable { let entries: [Entry] }
    private enum Token: Sendable { case literal(String), value(String) }
    private struct Text: Sendable {
        let tokens: [Token]
        init(_ text: String) {
            var tokens: [Token] = [], cursor = text.startIndex
            while let open = text[cursor...].firstIndex(of: "{"),
                  let close = text[text.index(after: open)...].firstIndex(of: "}") {
                let name = String(text[text.index(after: open)..<close])
                if open > cursor { tokens.append(.literal(String(text[cursor..<open]))) }
                if !name.isEmpty && name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) {
                    tokens.append(.value(name))
                } else { tokens.append(.literal(String(text[open...close]))) }
                cursor = text.index(after: close)
            }
            if cursor < text.endIndex { tokens.append(.literal(String(text[cursor...]))) }
            self.tokens = tokens
        }
        func render(_ values: [String: String], omitting: Set<String>) -> String {
            var skipped=Set<Int>()
            for index in tokens.indices {
                guard case .value(let key)=tokens[index],omitting.contains(key) else {continue}
                skipped.insert(index)
                // Reference formatters have optional fields separated by
                // punctuation. Remove one adjacent separator, never user text.
                let adjacent=[index-1,index+1].filter {tokens.indices.contains($0)}
                for neighbor in adjacent {
                    if case .literal(let value)=tokens[neighbor],value.allSatisfy({$0.isWhitespace || $0.isPunctuation || $0.isSymbol}) {
                        skipped.insert(neighbor);break
                    }
                }
            }
            return tokens.enumerated().filter {!skipped.contains($0.offset)}.map { _,token in
                switch token {
                case .literal(let value): return value
                case .value(let key): return values[key] ?? "{\(key)}"
                }
            }.joined()
        }
    }
    private struct Forms: Sendable { let base: Text, plural: [String: Text] }
    private let forms: [String: [CassiniLanguage: Forms]]
    public let entries: [Entry]
    public static let shared: Self = {
        let url = Bundle.module.url(forResource: "strings", withExtension: "json", subdirectory: "Localization")!
        let mac=Bundle.module.url(forResource:"mac",withExtension:"json",subdirectory:"Localization")!
        return try! Self(data: Data(contentsOf: url),macData:Data(contentsOf:mac))
    }()
    public init(data: Data, macData:Data? = nil) throws {
        entries = try JSONDecoder().decode(Catalog.self, from: data).entries + (try macData.map {try JSONDecoder().decode(Catalog.self,from:$0).entries} ?? [])
        forms = Dictionary(uniqueKeysWithValues: entries.map { entry in
            let source = Forms(base: Text(entry.mac ?? entry.en), plural: (entry.plural ?? [:]).mapValues(Text.init))
            var translations: [CassiniLanguage: Forms] = [.en: source]
            for language in CassiniLanguage.allCases where language != .en {
                if let translated = entry.l10n?[language.rawValue] {
                    translations[language] = Forms(base: Text(translated.mac ?? translated.text), plural: (translated.plural ?? [:]).mapValues(Text.init))
                }
            }
            return (entry.id, translations)
        })
    }
    public func contains(_ id: String) -> Bool { forms[id] != nil }
    public func text(_ id: String, _ values: [String: String] = [:], language: CassiniLanguage = .system, locale: Locale = .current, omitting: Set<String> = []) -> String {
        guard let entry = forms[id], let selected = entry[language] ?? entry[.en] else { preconditionFailure("Missing UX string: \(id)") }
        let template = values["n"].flatMap { selected.plural[language.pluralCategory($0)] ?? selected.plural["other"] } ?? selected.base
        var localized = values
        for key in ["n", "m", "k"] {
            guard let literal = values[key], let quantity = Quantity(literal) else { continue }
            let formatter = NumberFormatter(); formatter.locale = locale; formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = quantity.fractionDigits; formatter.maximumFractionDigits = quantity.fractionDigits
            let signed = literal.first == "-" ? -quantity.value : quantity.value
            localized[key] = formatter.string(from: NSDecimalNumber(decimal: signed)) ?? literal
        }
        return template.render(localized,omitting:omitting)
    }
}
