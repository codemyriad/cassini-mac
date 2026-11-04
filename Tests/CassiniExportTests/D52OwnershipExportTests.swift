// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
import CassiniLibrary
@testable import CassiniExport

/// D52/D49: the export mixdown keeps only each source's half-open ownership.
struct D52OwnershipExportTests {
    private func wave(_ url: URL, frames: Int, value: Int16) throws {
        var data = Data()
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + frames*2)); data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(1); u32(48000); u32(96000); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(frames*2))
        for _ in 0..<frames { u16(UInt16(bitPattern: value)) }
        try data.write(to: url)
    }
    @Test func theSeamIsNeverDoubledInTheMix() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D52Export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try wave(root.appendingPathComponent("system.wav"), frames: 48000*7, value: 4000)
        try wave(root.appendingPathComponent("browser.wav"), frames: 48000*5, value: 8000)
        let ownership = OthersOwnership(events: [.init(atMs: 0, type: "othersSource", source: "system", reason: "missing"),
                                                 .init(atMs: 6000, type: "othersSource", source: "browser", reason: "callConnected")])
        let system = try PCMInput(.init(url: root.appendingPathComponent("system.wav"), startOffsetMs: 0, frameCount: UInt64(48000*7), sourceKind: "system", sampleRate: 48000), ownership: ownership)
        let browser = try PCMInput(.init(url: root.appendingPathComponent("browser.wav"), startOffsetMs: 5000, frameCount: UInt64(48000*5), sourceKind: "remote", sampleRate: 48000), ownership: ownership)
        var mix = [Float](repeating: 0, count: 48000*10)
        try system.add(to: &mix, position: 0); try browser.add(to: &mix, position: 0)
        let a = Float(4000)/32768, b = Float(8000)/32768
        #expect(abs(mix[48000*5 + 100] - a) < 1e-4, "Physical overlap before the seam: stand-in only")
        #expect(abs(mix[6000*48 - 1] - a) < 1e-4); #expect(abs(mix[6000*48] - b) < 1e-4, "Half-open at 6000 ms")
        #expect(abs(mix[48000*6 + 48000/2] - b) < 1e-4, "System's last second is not mixed")
        #expect(mix.allSatisfy { $0 <= b + 1e-4 }, "No sample is ever the sum of both")
    }
}
