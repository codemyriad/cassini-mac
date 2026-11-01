// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniLibrary
@testable import CassiniExport

/// D55 (M9): the export mix places a track at the one placement frame (48 kHz).
struct D55PlacementExportTests {
    @Test func theMixStartsATrackAtItsPlacementFrame() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D55Export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("burst.wav"), frames = 4800
        var data = Data()
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + frames*2)); data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(1); u32(48000); u32(96000); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(frames*2))
        for _ in 0..<frames { u16(UInt16(bitPattern: 6000)) }
        try data.write(to: url)
        let input = try PCMInput(.init(url: url, startOffsetMs: 1234.5104, frameCount: UInt64(frames), sourceKind: "remote", sampleRate: 48000), ownership: nil)
        var mix = [Float](repeating: 0, count: 48000 * 2)
        try input.add(to: &mix, position: 0)
        let first = try #require(mix.firstIndex { $0 != 0 })
        #expect(Int64(first) == TrackPlacement.frame(ms: 1234.5104, rate: 48000))
        #expect(first == 59256 && mix[59255] == 0, "a one-frame shift is not the placement")
    }
}
