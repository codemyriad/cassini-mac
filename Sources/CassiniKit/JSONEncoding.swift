// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension JSON {
    /// Preserve unknown extension numbers as literal JSON, including integers
    /// that cannot round-trip through Double/NSNumber (D13).
    public func encoded(maximumBytes: Int = 64 * 1024 * 1024) throws -> Data {
        var output = Data()
        func append(_ data: Data) throws {
            guard data.count <= maximumBytes - output.count else { throw PayloadError.tooLarge(maximumBytes) }
            output.append(data)
        }
        func literal(_ text: String) throws { try append(Data(text.utf8)) }
        func quoted(_ text: String) throws {
            guard text.utf8.count <= maximumBytes else { throw PayloadError.tooLarge(maximumBytes) }
            let array = try JSONSerialization.data(withJSONObject:[text],options:[.withoutEscapingSlashes])
            try append(Data(array.dropFirst().dropLast()))
        }
        func write(_ value: JSON, depth: Int) throws {
            switch value {
            case .null: try literal("null")
            case .bool(let flag): try literal(flag ? "true" : "false")
            case .number(let number): try literal(number)
            case .string(let text): try quoted(text)
            case .array(let values):
                guard depth < JSONParser.maxDepth else { throw PayloadError.json("excessive depth") }
                try literal("[")
                for (index,item) in values.enumerated() { if index > 0 { try literal(",") }; try write(item,depth:depth + 1) }
                try literal("]")
            case .object(let values):
                guard depth < JSONParser.maxDepth else { throw PayloadError.json("excessive depth") }
                try literal("{")
                for (index,pair) in values.enumerated() {
                    if index > 0 { try literal(",") }; try quoted(pair.0); try literal(":"); try write(pair.1,depth:depth + 1)
                }
                try literal("}")
            }
        }
        guard maximumBytes >= 0 else { throw PayloadError.tooLarge(maximumBytes) }
        try write(self,depth:0)
        guard try JSONParser.parse(output) == self else { throw PayloadError.json("invalid constructed JSON") }
        return output
    }
    public func setting(_ key: String, to value: JSON?) throws -> JSON {
        guard var members = object else { throw PayloadError.json("expected object") }
        if let index = members.firstIndex(where:{ $0.0 == key }) {
            if let value { members[index].1 = value } else { members.remove(at:index) }
        } else if let value { members.append((key,value)) }
        return .object(members)
    }
}
