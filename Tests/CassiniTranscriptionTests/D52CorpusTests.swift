// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CryptoKit
import CassiniKit
import CassiniLibrary
@testable import CassiniTranscription

/// D52 shared production-shaped corpus (conformance/multistream, protocol
/// c6f5fc7), materialized by its deterministic stdlib generator and hash-checked
/// against a pinned digest (D52.3e), then read through the Mac scanner, speaker
/// lanes and others-ownership placement.
final class D52CorpusTests: XCTestCase {
    /// SHA-256 of the sorted "./relative/path <sha256>\n" listing of every generated file.
    static let pinnedDigest = "dc2a0187d386fe72d73fc9dca01bb6f6c929bc87bb8c46f44629328b3e69020d"
    private func materialize() throws -> URL {
        let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D52Corpus-"+UUID().uuidString)
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/env")
        process.arguments = ["python3","-I",repository.appendingPathComponent("browser-protocol/conformance/multistream/make.py").path,root.path]
        process.standardOutput = Pipe(); try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus,0)
        return root
    }
    private func digest(_ root: URL) throws -> String {
        let files = try XCTUnwrap(FileManager.default.enumerator(atPath:root.path)).compactMap { $0 as? String }
            .filter { (try? root.appendingPathComponent($0).resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true }
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        var listing = ""
        for file in files {
            let hash = SHA256.hash(data:try Data(contentsOf:root.appendingPathComponent(file))).map { String(format:"%02x",$0) }.joined()
            listing += "./\(file) \(hash)\n"
        }
        return SHA256.hash(data:Data(listing.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    func testCorpusIsPinnedAndPlacesEverySourceOnce() throws {
        let root = try materialize(); defer { try? FileManager.default.removeItem(at:root) }
        XCTAssertEqual(try digest(root),Self.pinnedDigest,"Generated corpus differs from the pinned expectation")
        let meetings = try LibraryScanner(root:root).scan().meetings
        XCTAssertEqual(meetings.count,2)
        let call = try XCTUnwrap(meetings.first { $0.audioTracks.count == 8 })
        // M1: unequal disjoint spans of one source stay one speaker; nothing is separated.
        let spans = call.audioTracks.compactMap { track -> SourceSpanLanes.Span? in
            let speaker = TranscriptSpeaker.fromTrack(id:track.sourceID ?? "",kind:track.sourceKind ?? "media",sourceTrackID:track.sourceTrackID)
            guard speaker.id.hasPrefix("track-"), let id = track.sourceID else { return nil }
            return .init(id:id,base:speaker.id,startMs:track.startOffsetMs,endMs:track.endOffsetMs)
        }
        let lanes = SourceSpanLanes.assign(spans)
        XCTAssertEqual(Set(lanes.values),["track-source-a","track-source-b"])
        XCTAssertEqual(lanes.values.filter { $0 == "track-source-a" }.count,3)
        // D49/D33: system and browser never own the same instant; each seam is half-open.
        let ownership = try XCTUnwrap(OthersOwnership(events:call.captureEvents))
        let owned = call.audioTracks.map { track in
            (track.sourceKind,ownership.owned(kind:track.sourceKind,startMs:track.startOffsetMs ?? 0,endMs:track.endOffsetMs ?? 0))
        }
        for at in stride(from:0.0,to:90000,by:250) {
            let roles = Set(owned.filter { $0.1.contains { at >= $0.0 && at < $0.1 } }.compactMap { OthersOwnership.role(kind:$0.0) })
            XCTAssertFalse(roles.contains("system") && roles.contains("browser"),"Both own \(at) ms")
        }
        let system = owned.filter { $0.0 == "system" }.flatMap(\.1).map { [$0.0,$0.1] }
        XCTAssertEqual(system,[[0,20000],[50000,60000]])
        let microphone = try XCTUnwrap(owned.first { $0.0 == "microphone" })
        XCTAssertEqual(microphone.1.map { [$0.0,$0.1] },[[0,90000]],"The microphone is never masked")
        // The concurrent call's folder is independent and unmasked.
        let other = try XCTUnwrap(meetings.first { $0.audioTracks.count == 1 })
        XCTAssertEqual(other.audioTracks.first?.sourceTrackID,"other-call-source")
    }
}
