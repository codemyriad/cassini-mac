// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
import CassiniLibrary
@testable import CassiniExport

/// D52 M17: the export mixdown on the shared production-shaped corpus
/// (conformance/multistream, digest pinned in D52CorpusTests), through the same
/// PCMInput and ownership the exporter uses.
struct D52CorpusExportTests {
    @Test func theCorpusMixKeepsTheMicAndNeverDoublesTheOthers() throws {
        let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D52CorpusExport-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/env")
        process.arguments = ["python3","-I",repository.appendingPathComponent("browser-protocol/conformance/multistream/make.py").path,root.path]
        process.standardOutput = Pipe(); try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let meeting = try #require(try LibraryScanner(root:root).scan().meetings.first { $0.audioTracks.count == 8 })
        let ownership = OthersOwnership(events:meeting.captureEvents)
        let length = 90 * 48000
        var system = [Bool](repeating:false,count:length), browser = system
        for track in meeting.audioTracks {
            var masked = [Float](repeating:0,count:length), raw = masked
            try PCMInput(track,ownership:ownership).add(to:&masked,position:0)
            try PCMInput(track).add(to:&raw,position:0)
            let role = OthersOwnership.role(kind:track.sourceKind)
            // Inside its ownership the mix keeps each source's stored audio unchanged; outside it
            // (corpus v2 sources run past their D49 seams) the source is silent. The microphone
            // is never masked.
            let start = track.startOffsetMs ?? 0, end = track.endOffsetMs ?? start
            let owned = ownership?.owned(kind:track.sourceKind ?? "media",startMs:start,endMs:end) ?? [(start,end)]
            let edges = owned.flatMap { [$0.0,$0.1] }
            let altered = masked.indices.filter { index in
                let ms = Double(index) / 48
                // The sample on an ownership edge may fall either side of it.
                if edges.contains(where: { abs($0 - ms) < 1.5 / 48 }) { return false }
                return owned.contains { ms >= $0.0 && ms < $0.1 } ? masked[index] != raw[index] : masked[index] != 0
            }
            #expect(altered.isEmpty,"\(track.sourceID ?? "?") differs from its owned audio at \(altered.first.map { Double($0)/48 } ?? 0) ms")
            for index in masked.indices where masked[index] != 0 {
                if role == "system" { system[index] = true } else if role == "browser" { browser[index] = true }
            }
        }
        let doubled = system.indices.filter { system[$0] && browser[$0] }
        #expect(doubled.isEmpty,"system and browser both mixed at \(doubled.first.map { Double($0)/48 } ?? 0) ms")
        #expect(system.contains(true) && browser.contains(true))
    }
}
