// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniKit

struct ZIPArchiveTests {
    private func folder() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("ZIPTest-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url
    }
    @Test func storedZIP64IsReadableByPythonAndStreamsInBoundedChunks() throws {
        let root=try folder(); defer { try? FileManager.default.removeItem(at:root) }
        let bytes=Data((0..<(3*ZIPArchive.chunkBytes+7)).map { UInt8(truncatingIfNeeded:$0 * 17) })
        let source=root.appendingPathComponent("source"); try bytes.write(to:source)
        let url=root.appendingPathComponent("notes.zip"),writer=try StoredZIPWriter(url:root.appendingPathComponent("notes.zip"))
        try writer.add(file:source,name:"English.opus"); try writer.finish()
        let archive=try ZIPArchive(url:url), entry=try #require(archive.entries.first)
        #expect(entry.method == 0 && entry.expandedBytes == UInt64(bytes.count))
        var read=Data()
        try archive.read(entry,remainingBytes:ZIPLimits().expandedBytes) { chunk in #expect(chunk.count <= 65536); read.append(chunk) }
        #expect(read == bytes)
        let python=Process(); python.executableURL=URL(fileURLWithPath:"/usr/bin/env")
        python.arguments=["python3","-c","import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); assert z.namelist()==['English.opus']; assert z.infolist()[0].compress_type==0; assert z.read('English.opus')==open(sys.argv[2],'rb').read()",url.path,source.path]
        try python.run();python.waitUntilExit();#expect(python.terminationStatus == 0)
    }
    @Test func limitsAndCancellationAreCheckedDuringStreaming() throws {
        #expect(ZIPLimits().expandedBytes == 20_000_000_000)
        #expect(throws:Never.self) { try ZIPArchive.checkRatio(100,1,100) }
        #expect(throws:ZIPFailure.tooLarge) { try ZIPArchive.checkRatio(101,1,100) }
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("source");try Data(repeating:7,count:200000).write(to:source)
        let url=root.appendingPathComponent("notes.zip"),writer=try StoredZIPWriter(url:root.appendingPathComponent("notes.zip"))
        try writer.add(file:source,name:"English.opus");try writer.finish()
        #expect(throws:ZIPFailure.tooLarge) { try ZIPArchive(url:url,limits:.init(entries:0)) }
        #expect(throws:ZIPFailure.tooLarge) { try ZIPArchive(url:url,limits:.init(expandedBytes:199999)) }
        let archive=try ZIPArchive(url:url),entry=try #require(archive.entries.first)
        #expect(throws:ZIPFailure.tooLarge) { try archive.read(entry,remainingBytes:1) {_ in} }
        var chunks=0
        #expect(throws:CancellationError.self) { try archive.read(entry,remainingBytes:200000,check:{ if chunks==1 {throw CancellationError()} }) {_ in chunks += 1} }
        #expect(chunks == 1)
    }
    @Test func decimalTwentyGBDirectoryBoundaryDoesNotRequireAllocatingAudio() throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("empty");try Data().write(to:source)
        let url=root.appendingPathComponent("boundary.zip"),writer=try StoredZIPWriter(url:root.appendingPathComponent("boundary.zip"))
        try writer.add(file:source,name:"English.opus");try writer.finish()
        var data=try Data(contentsOf:url)
        let central=try #require(data.range(of:Data([0x50,0x4b,1,2]))).lowerBound
        let sizeOffset=central+46+Int(data.z16(central+28))+4
        var size=Data();size.zip64(20_000_000_000)
        data.replaceSubrange(sizeOffset..<sizeOffset+8,with:size);try data.write(to:url)
        #expect(try ZIPArchive(url:url).entries[0].expandedBytes == 20_000_000_000)
        size=Data();size.zip64(20_000_000_001)
        data.replaceSubrange(sizeOffset..<sizeOffset+8,with:size);try data.write(to:url)
        #expect(throws:ZIPFailure.tooLarge) {try ZIPArchive(url:url)}
    }
    @Test(arguments:["../a.opus","/a.opus","C:/a.opus","folder/../a.opus","folder\\a.opus"])
    func unsafePathsAreRejected(_ name:String) throws { #expect(throws:ZIPFailure.unsafePaths) {try ZIPArchive.checkPath(name)} }
}
