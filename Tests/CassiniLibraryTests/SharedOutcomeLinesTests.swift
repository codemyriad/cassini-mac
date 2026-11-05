// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniLibrary

/// Shared test 8 (D67): each T8 case's Details "Audio sources" lines, through the production
/// scanner and RecordingDetailsReport exactly as the Recording details sheet loads them, against
/// the hand-written library-vectors/outcome-lines.json. Ids, arguments and the warning role are
/// compared exactly; so are "no speech" and the words shown per speaker.
@Suite struct SharedOutcomeLinesTests {
    @Test func everyT8CaseShowsItsHandWrittenLines() throws {
        let source = try #require(Bundle.module.url(forResource: "LibraryVectors", withExtension: nil))
        let outcome = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("outcome-lines.json"))) as? [String: Any])
        let cases = try #require(outcome["cases"] as? [String: [String: Any]])
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("cases.json"))) as? [String: Any])
        let t8 = Set((manifest["cases"] as! [[String: Any]]).map { $0["id"] as! String }.filter { $0.hasPrefix("t8-") })
        // The file covers exactly the T8 cases: three outcome states, a control and five guards.
        try #require(Set(cases.keys) == t8 && t8.count == 9)
        let now = Date(timeIntervalSince1970: (manifest["nowMs"] as! NSNumber).doubleValue / 1000)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-outcome-lines-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-B", source.appendingPathComponent("make.py").path, output.path]
        try process.run(); process.waitUntilExit()
        try #require(process.terminationReason == .exit && process.terminationStatus == 0)
        var rendered: [String: [[String: Any]]] = [:]
        for id in t8.sorted() {
            let expected = cases[id]!
            let scan = try LibraryScanner(root: output.appendingPathComponent(id).appendingPathComponent("root")).scan(now: now)
            let meeting = try #require(scan.meetings.count == 1 ? scan.meetings.first : nil, "\(id): one meeting")
            try #require(meeting.state.lifecycle == .saved, "\(id): saved")
            let report = RecordingDetailsReport(.load(folder: meeting.folder, lifecycle: .saved, title: meeting.title ?? "",
                                                      transcriptDone: meeting.state.transcript == .done))
            // Source rows (own line, gap lines, then the R13 silent line), then D58 refusal lines.
            var lines: [[String: Any]] = []
            for row in report.sources {
                lines.append(Self.json(row.line, problem: row.problem))
                for gap in row.gapLines { lines.append(Self.json(gap, problem: false)) }
                if let silent = row.silent { lines.append(Self.json(silent, problem: false)) }
            }
            for refusal in report.refusals { lines.append(Self.json(refusal, problem: true)) }
            rendered[id] = lines
            let actual = try JSONSerialization.data(withJSONObject: lines, options: [.sortedKeys])
            let wanted = try JSONSerialization.data(withJSONObject: expected["audio"]!, options: [.sortedKeys])
            #expect(String(decoding: actual, as: UTF8.self) == String(decoding: wanted, as: UTF8.self), "\(id) Details lines")
            #expect(meeting.hasNoSpeech == (expected["noSpeech"] as! Bool), "\(id) noSpeech")
            // The meeting view shows every transcript item, as a turn or an aside.
            let words = Dictionary(grouping: meeting.transcriptItems, by: \.speaker).mapValues(\.count)
            #expect(words == (expected["visibleWords"] as! [String: Int]), "\(id) visible words")
            // Each line renders with the real catalog: no placeholder survives.
            for line in report.sources.flatMap(\.lines) {
                let text = line.render(language: .en, locale: Locale(identifier: "en_GB"))
                #expect(!text.isEmpty && !text.contains("{"), "\(id) renders \(text)")
            }
        }
        // D67.1: "others silent" is a visible state, so its Details lines differ from the control's.
        let silent = try JSONSerialization.data(withJSONObject: rendered["t8-others-silent"]!, options: [.sortedKeys])
        let control = try JSONSerialization.data(withJSONObject: rendered["t8-control-others-spoke"]!, options: [.sortedKeys])
        #expect(silent != control, "others silent reads differently from the control")
    }

    private static func json(_ line: RecordingDetailsReport.Line, problem: Bool) -> [String: Any] {
        var args: [String: Any] = [:]
        for (key, value) in line.values {
            switch value {
            case .catalog(let id): args[key] = ["catalog": id]
            case .text(let text): args[key] = ["text": text]
            case .duration(let ms): args[key] = ["ms": ms]
            case .position(let ms): args[key] = ["positionMs": ms]
            }
        }
        return ["id": line.id ?? NSNull(), "args": args, "problem": problem]
    }
}
