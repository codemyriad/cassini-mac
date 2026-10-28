// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import CassiniTranscription
import CassiniWhistle
import CassiniParakeet

final class ParakeetLeaseTests: XCTestCase {
    func testRemovingAnInstalledRevisionKeepsAcceptedJobFiles() throws {
        let env = ProcessInfo.processInfo.environment
        guard let original = env["CASSINI_PARAKEET_MODEL"], let runtime = env["CASSINI_PARAKEET_RUNTIME"] else { throw XCTSkip("D16 source files supplied by Parakeet CI") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let installed = root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at:installed,withIntermediateDirectories:false)
        for name in ParakeetPin.files.keys {
            try FileManager.default.linkItem(at:URL(fileURLWithPath:original).appendingPathComponent(name),to:installed.appendingPathComponent(name))
        }
        var lease: ParakeetModelLease? = try ParakeetModelLease(model:installed,temporaryRoot:root)
        let files = try XCTUnwrap(lease?.directory)
        try FileManager.default.removeItem(at:installed)
        SpeechScratch.removeAbandoned(in:root)
        XCTAssertTrue(FileManager.default.fileExists(atPath:files.path),"A live kernel lease protects its files")
        _ = try ParakeetAssets.pinned(runtime:URL(fileURLWithPath:runtime),model:files)
        lease = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath:files.path))
    }
    func testMissingOrAliasedModelNeverLeavesAPartialLease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        XCTAssertThrowsError(try ParakeetModelLease(model:root,temporaryRoot:root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),[])
        let target = root.appendingPathComponent("target")
        try Data().write(to:target)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("encoder.int8.onnx"),withDestinationURL:target)
        XCTAssertThrowsError(try ParakeetModelLease(model:root,temporaryRoot:root))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains { $0.hasPrefix("CassiniSpeech-") })
    }
    func testUnrelatedExecutableCannotConstructABundledWorkerCapability() {
        XCTAssertThrowsError(try SignedSpeechBundle.currentWorker())
    }
}
