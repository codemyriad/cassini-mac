// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
@testable import CassiniLibrary

struct BulkImportTests {
    private func zip(_ mode:String, _ fixture:Fixture) throws -> URL {
        let url=fixture.root.appendingPathComponent(mode+".zip"),p=Process()
        p.executableURL=URL(fileURLWithPath:"/usr/bin/env")
        p.arguments=["python3",fixture.repository.appendingPathComponent("Tests/ArchiveFixtures.py").path,url.path,mode,
                     fixture.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/001-minimal-v1.opus").path]
        try p.run();p.waitUntilExit();try #require(p.terminationStatus==0);return url
    }
    @Test(arguments:[("unsafe",ZIPFailure.unsafePaths),("unicode-unsafe",.unsafePaths),("encrypted",.encrypted),("local-encrypted",.encrypted),("too-many",.tooLarge),("ratio",.tooLarge),("padded",.tooLarge),("forged-deflate",.tooLarge)])
    func refusedArchivesPublishNoMember(mode:String, failure:ZIPFailure) throws {
        let f=try Fixture(),source=try zip(mode,f),library=f.root.appendingPathComponent("Imported"),scratch=f.root.appendingPathComponent("Scratch")
        let result=LibraryBulkImport.run([source],into:library,temporaryRoot:scratch)
        #expect(result.archives == [failure]);#expect(result.imported==0)
        #expect(!FileManager.default.fileExists(atPath:library.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath:scratch.path).isEmpty)
    }
    @Test(arguments:["mixed","deflated","many","symlink"])
    func supportedMembersUseOrdinaryDedupAndPreserveNames(_ mode:String) throws {
        let f=try Fixture(),source=try zip(mode,f),library=f.root.appendingPathComponent("Imported")
        let result=LibraryBulkImport.run([source],into:library,temporaryRoot:f.root)
        #expect(result.imported==1 && result.failed==0 && result.archives.isEmpty)
        #expect(result.duplicates == (mode == "mixed" ? 1 : 0))
        #expect(result.unsupported == (mode == "mixed" ? 2 : mode == "many" ? 1999 : mode == "symlink" ? 1 : 0))
        #expect(result.lastMeeting?.title == "Conformance vector 001") // The document title, not the staging UUID.
        let repeated=LibraryBulkImport.run([source],into:library,temporaryRoot:f.root)
        #expect(repeated.imported==0 && repeated.duplicates >= 1)
    }
    @Test func corruptOrIndividuallyOversizedMembersDoNotDiscardGoodMembers() throws {
        let f=try Fixture()
        let damaged=LibraryBulkImport.run([try zip("crc",f)],into:f.root.appendingPathComponent("One"),temporaryRoot:f.root)
        #expect(damaged.imported==1 && damaged.failed==1 && damaged.archives.isEmpty)
        let source=try zip("oversized",f),archive=try ZIPArchive(url:source)
        let cap=try #require(archive.entries.last?.expandedBytes)
        let oversized=LibraryBulkImport.run([source],into:f.root.appendingPathComponent("Two"),temporaryRoot:f.root,memberLimit:cap)
        #expect(oversized.imported==1 && oversized.failed==1)
    }
    @Test func actualByteBudgetAndEmptyArchivesAreReported() throws {
        let f=try Fixture()
        let forged=LibraryBulkImport.run([try zip("forged",f)],into:f.root.appendingPathComponent("Imported"),temporaryRoot:f.root,limits:.init(expandedBytes:100000))
        #expect(forged.archives == [.tooLarge] && forged.imported==0)
        let empty=LibraryBulkImport.run([try zip("empty",f)],into:f.root.appendingPathComponent("Empty"),temporaryRoot:f.root)
        #expect(empty.archives == [.empty] && empty.unsupported==2)
    }
    @Test func cancellationAtMemberBoundaryRetainsCommittedNotesAndCleansScratch() throws {
        let f=try Fixture(),source=try zip("mixed",f),scratch=f.root.appendingPathComponent("Scratch")
        var cancel=false
        let report=LibraryBulkImport.run([source],into:f.root.appendingPathComponent("Imported"),temporaryRoot:scratch,shouldCancel:{cancel},progress:{ if $0.done==1 {cancel=true} })
        #expect(report.cancelled && report.imported==1 && report.duplicates==0)
        #expect(try FileManager.default.contentsOfDirectory(atPath:scratch.path).isEmpty)
        #expect(try LibraryScanner(root:f.root.appendingPathComponent("Imported")).scan().meetings.count==1)
    }
}
