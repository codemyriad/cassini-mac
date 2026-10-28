// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CryptoKit
import CassiniWhistle
@testable import CassiniParakeet

final class ParakeetTests: XCTestCase {
    func testPieceTimesUseFloat32ThenDoubleAndHalfAwayRounding() throws {
        let words = try ParakeetWords.decode([
            .init(text:"▁Hel",timestamp:0.0625,duration:0.0625),
            .init(text:"lo",timestamp:0.125,duration:0.0625),
            .init(text:"!",timestamp:2,duration:1),
            .init(text:" world",timestamp:3,duration:0.25),
        ])
        XCTAssertEqual(words.map(\.word),["Hello!","world"])
        XCTAssertEqual(words.map(\.start),[0.063,3])
        XCTAssertEqual(words.map(\.end),[0.188,3.25])
    }
    func testEveryUnicodeLetterAndNumberCategoryCountsAndMarksDoNot() throws {
        for text in ["A","a","ǅ","ʰ","中","7","Ⅷ","²"] {
            let result = try ParakeetWords.decode([.init(text:" " + text,timestamp:1,duration:0.5)])
            XCTAssertEqual(result.first?.end,1.5,text)
        }
        for text in ["!","—","\u{0301}","🙂"] {
            let result = try ParakeetWords.decode([.init(text:" " + text,timestamp:1,duration:20)])
            XCTAssertEqual(result.first?.end,1,text)
        }
    }
    func testInvalidClockValuesNeverBecomeIntegerWordTimes() throws {
        for value: Float in [.nan,.infinity,-.infinity,-1,32] {
            XCTAssertThrowsError(try ParakeetWords.decode([.init(text:" a",timestamp:value,duration:0.1)]))
            XCTAssertThrowsError(try ParakeetWords.decode([.init(text:" a",timestamp:0,duration:value)]))
        }
    }
    func testWritableAdjacentChecksumsCannotAuthoriseAnotherRuntime() throws {
        let bytes = Data("not the pinned runtime".utf8)
        XCTAssertThrowsError(try ParakeetAssets.verifySourceLibrary(bytes,pins:ParakeetPin.runtimes["libsherpa-onnx-c-api.dylib"]!))
        var fat = Data([0xca,0xfe,0xba,0xbe,0,0,0,2])
        fat.append(Data(repeating:255,count:40))
        XCTAssertThrowsError(try ParakeetAssets.verifySourceLibrary(fat,pins:ParakeetPin.runtimes["libonnxruntime.dylib"]!))
    }
    func testSharedGoldensAreVerbatim() throws {
        let root = Bundle.module.url(forResource:"Goldens",withExtension:nil)!
        for line in try String(contentsOf:root.appendingPathComponent("SHA256SUMS"),encoding:.utf8).split(separator:"\n") {
            let fields = line.split(whereSeparator:\.isWhitespace)
            XCTAssertEqual(fields.count,2)
            let data = try Data(contentsOf:root.appendingPathComponent(String(fields[1])))
            XCTAssertEqual(ParakeetAssets.sha(data),String(fields[0]))
        }
    }
}
