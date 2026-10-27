import Foundation
import CassiniKit

/// Validates the vocabulary used by the pinned v1 meeting.schema.json. This is
/// deliberately not advertised as a general JSON Schema implementation.
enum MetadataSchema {
    static let bytes: Data = {
        let url = Bundle.module.url(forResource: "meeting.schema", withExtension: "json", subdirectory: "Schema")!
        return try! Data(contentsOf: url)
    }()
    static let schema = try! JSONParser.parse(bytes)
    static func validate(_ value: JSON, against schema: JSON = schema) -> Bool {
        if let choices = schema["oneOf"]?.array, choices.filter({ validate(value, against: $0) }).count != 1 { return false }
        if let choices = schema["allOf"]?.array, !choices.allSatisfy({ validate(value, against: $0) }) { return false }
        if let condition = schema["if"] {
            let branch = validate(value, against: condition) ? schema["then"] : schema["else"]
            if let branch, !validate(value, against: branch) { return false }
        }
        if let excluded = schema["not"], validate(value, against: excluded) { return false }
        if let fixed = schema["const"], !equal(value, fixed) { return false }
        if let choices = schema["enum"]?.array, !choices.contains(where: { equal(value, $0) }) { return false }
        if let type = schema["type"] {
            let types = type.array?.compactMap(\.string) ?? [type.string].compactMap { $0 }
            guard types.contains(where: { matches(value, type: $0) }) else { return false }
        }
        if let object = value.object {
            if let required = schema["required"]?.array, !required.allSatisfy({ value[$0.string ?? ""] != nil }) { return false }
            for (key, child) in object {
                if let rule = schema["properties"]?[key], !validate(child, against: rule) { return false }
            }
        }
        if let array = value.array {
            if let max = schema["maxItems"]?.int, array.count > max { return false }
            if let rule = schema["items"], !array.allSatisfy({ validate($0, against: rule) }) { return false }
        }
        if let text = value.string {
            let length = text.unicodeScalars.count
            if let min = schema["minLength"]?.int, length < min { return false }
            if let max = schema["maxLength"]?.int, length > max { return false }
            if let pattern = schema["pattern"]?.string, text.range(of: pattern, options: .regularExpression) == nil { return false }
            if schema["format"]?.string == "uuid", UUID(uuidString: text) == nil { return false }
        }
        if let number = decimal(value) {
            if let minimum = schema["minimum"].flatMap(decimal), number < minimum { return false }
            if let maximum = schema["maximum"].flatMap(decimal), number > maximum { return false }
        }
        return true
    }
    static func decimal(_ value: JSON) -> Decimal? {
        guard case .number(let literal) = value else { return nil }
        guard let number = Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN else { return nil }
        return number
    }
    private static func equal(_ a: JSON, _ b: JSON) -> Bool {
        if let x = decimal(a), let y = decimal(b) { return x == y }
        return a == b
    }
    private static func matches(_ value: JSON, type: String) -> Bool {
        switch type {
        case "null": return value.isNull
        case "object": return value.object != nil
        case "array": return value.array != nil
        case "string": return value.string != nil
        case "integer":
            guard var number = decimal(value) else { return false }
            var rounded = Decimal(); NSDecimalRound(&rounded, &number, 0, .plain)
            return rounded == number
        default: return false
        }
    }
}
