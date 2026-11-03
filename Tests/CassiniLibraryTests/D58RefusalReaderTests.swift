// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
@testable import CassiniLibrary

/// D58 (R79): the shared refusal reader cases (conformance/refusals/readers.json) through the
/// Recording details report, and Copy details' exact entries.
final class D58RefusalReaderTests: XCTestCase {
    private func vectors() throws -> JSON {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-protocol/conformance/refusals/readers.json")
        return try JSONParser.parse(Data(contentsOf:url))
    }
    private func describe(_ line: RecordingDetailsReport.Line) -> String {
        guard case .catalog(let source)? = line.values["source"] else { return line.id ?? "" }
        return (line.id ?? "") + "|" + source
    }

    func testSharedReaderCases() throws {
        let readers = try XCTUnwrap(try vectors()["readers"]?.array)
        XCTAssertEqual(readers.count,16)
        for reader in readers {
            let name = try XCTUnwrap(reader["name"]?.string)
            let notSelected = (reader["notSelected"]?.array ?? []).compactMap(\.string)
            let lines = RecordingDetailsReport.sourceLines(stored:reader["stored"],notSelected:notSelected,
                                                           hasRows:!(reader["sources"]?.array ?? []).isEmpty)
            let expected = try XCTUnwrap(reader["expectedLines"]?.array).map { line in
                (line["id"]?.string ?? "") + (line["source"]?.string.map { "|" + $0 } ?? "")
            }
            XCTAssertEqual(lines.map(describe),expected,name)
            if let copy = reader["expectedCopy"]?.array {
                // Swift String equality is canonical; compare code points so normalization fails.
                let kept = RecordingDetailsReport.refusalCopy(reader["stored"])
                XCTAssertEqual(kept.count,copy.count,name)
                for (got,want) in zip(kept,copy) {
                    XCTAssertEqual(try got.encoded(maximumBytes:1_000_000),try want.encoded(maximumBytes:1_000_000),name)
                    XCTAssertEqual(got["message"]?.string.map { Array($0.unicodeScalars) },want["message"]?.string.map { Array($0.unicodeScalars) },name)
                }
            }
        }
    }

    /// The report shows the session's refusals after the rows; the captureRecord copy is used
    /// once the session is gone, and a refusal line replaces the empty state.
    func testTheReportReadsTheSessionOrItsCaptureRecordCopy() throws {
        let refusals = #"[{"atMs":0,"side":"others","code":"deviceUnavailable","message":"AudioHardwareCreateProcessTap: -50"},{"atMs":45000,"side":"me","code":"permissionDenied"}]"#
        let session = try JSONParser.parse(Data((#"{"version":1,"state":"completed","tracks":[],"refusals":"# + refusals + "}").utf8))
        let report = RecordingDetailsReport(.init(lifecycle:.saved,title:"Call",session:session))
        XCTAssertTrue(report.sources.isEmpty); XCTAssertFalse(report.sourcesEmpty)
        XCTAssertEqual(report.refusals.map(describe),["details.sources.refused.deviceUnavailable|details.source.system",
                                                      "details.sources.refused.permissionDenied|details.source.microphone"])
        let record = try JSONParser.parse(Data((#"{"version":1,"sources":[],"tracks":[],"events":[],"refusals":"# + refusals + "}").utf8))
        let fromRecord = RecordingDetailsReport(.init(lifecycle:.saved,title:"Call",session:nil,captureRecord:record))
        XCTAssertEqual(fromRecord.refusals,report.refusals)
        let none = RecordingDetailsReport(.init(lifecycle:.saved,title:"Call",session:nil,captureRecord:nil))
        XCTAssertTrue(none.sourcesEmpty)
        for id in report.refusals.compactMap(\.id) { XCTAssertTrue(RecordingDetailsReport.catalogIDs.contains(id),id) }
    }
}
