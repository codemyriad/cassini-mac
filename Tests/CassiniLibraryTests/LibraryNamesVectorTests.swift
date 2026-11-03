// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
@testable import CassiniLibrary

/// R65 (D55): the Swift port of library-v2/names.py on its shared name vectors.
struct LibraryNamesVectorTests {
    private func load(_ name: String) throws -> JSON {
        let url = try #require(Bundle.module.url(forResource:name,withExtension:"json",subdirectory:"Golden/library-v2"))
        return try JSONParser.parse(Data(contentsOf:url))
    }
    private func start(_ value: JSON) throws -> LibraryNames.Start {
        switch value["kind"]?.string {
        case "persisted"?: return .persisted(try #require(value["namePrefix"]?.string))
        case "capture"?: return .capture(startUtc:try #require(value["startUtc"]?.string),utcOffsetMinutes:value["utcOffsetMinutes"]?.int,libraryTimeZone:value["libraryTimeZone"]?.string)
        case "unknown-start"?: return .unknownStart(importUtc:try #require(value["importUtc"]?.string),libraryTimeZone:try #require(value["libraryTimeZone"]?.string))
        case "received"?: return .received(dateTag:value["dateTag"]?.string,importUtc:value["importUtc"]?.string ?? "",libraryTimeZone:value["libraryTimeZone"]?.string ?? "")
        default: throw LibraryNames.NameError.invalidStart
        }
    }
    private func check(_ vector: JSON, title: String, untitled: String) throws {
        let id = vector["id"]?.string ?? "?", input = try #require(vector["input"]), expected = try #require(vector["expected"])
        let prefix = try LibraryNames.prefix(start(try #require(input["start"])))
        #expect(prefix.namePrefix == expected["namePrefix"]?.string,"\(id)")
        #expect(prefix.source == expected["namePrefixSource"]?.string,"\(id)")
        #expect(prefix.utcOffsetMinutes == expected["utcOffsetMinutes"]?.int,"\(id)")
        let existing = input["existing"]?.array?.compactMap(\.string) ?? []
        let result = try LibraryNames.fileName(prefix:prefix.namePrefix,title:title,untitled:untitled,existing:existing,own:input["ownName"]?.string)
        #expect(result.sanitized == expected["sanitizedTitle"]?.string,"\(id)")
        #expect(result.name == expected["fileName"]?.string,"\(id)")
        #expect(result.name.utf8.count == expected["fileNameUtf8Bytes"]?.int,"\(id)")
    }
    @Test func everyNameVector() throws {
        let file = try load("name-vectors")
        let untitled = try #require(file["untitled"]?["value"]?.string)
        let cases = try #require(file["cases"]?.array)
        #expect(cases.count == 164)
        for vector in cases { try check(vector,title:try #require(vector["input"]?["title"]?.string),untitled:untitled) }
    }
    @Test func nfcNeverComposesArchaicJamo() {
        #expect(Array(LibraryNames.nfc("x\u{1100}\u{1176}\u{11A8}").unicodeScalars.map(\.value)) == [0x78,0x1100,0x1176,0x11A8])
        #expect(LibraryNames.nfc("\u{1100}\u{1161}\u{11A8}") == "\u{AC01}","modern jamo still compose")
        #expect(LibraryNames.nfc("e\u{301}") == "\u{E9}")
    }
    /// Swift strings cannot hold a lone surrogate, so titles arrive as UTF-16 units and each
    /// unpaired unit becomes "-" (the vectors' accepting-platform rule).
    @Test func everyMalformedTitleVector() throws {
        let file = try load("name-vectors-malformed")
        let untitled = try #require(file["untitled"]?["value"]?.string)
        for vector in try #require(file["cases"]?.array) {
            let units = try #require(vector["input"]?["titleUtf16"]?.array).compactMap { $0.int.map(UInt16.init) }
            try check(vector,title:LibraryNames.title(utf16:units),untitled:untitled)
        }
    }
}
