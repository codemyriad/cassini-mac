// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin
import Testing
import XCTest
@testable import CassiniModels

struct ModelSupersessionTests {
    private struct Receipt: Encodable { let pin: ModelPin; let files: [ModelAsset] }
    private func plan(_ id: String, revision: String, bytes: Data) -> ModelPlan {
        let hash = SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
        return ModelPlan(pin:.init(id:id,sourceSHA256:String(repeating:revision,count:64)),files:[
            ModelAsset(path:"weights.bin",url:URL(string:"https://dist.gocassini.com/weights.bin")!,compressedBytes:1,
                compressedSHA256:hash,rawBytes:UInt64(bytes.count),rawSHA256:hash)
        ])
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniSupersession-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        return root
    }
    private func directory(_ plan: ModelPlan, in root: URL) -> URL {
        root.appendingPathComponent("models/"+plan.pin.id+"/"+plan.pin.sourceSHA256)
    }
    private func install(_ plan: ModelPlan, bytes: Data, in root: URL) throws -> URL {
        let directory = directory(plan,in:root)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try bytes.write(to:directory.appendingPathComponent("weights.bin"))
        try JSONEncoder().encode(Receipt(pin:plan.pin,files:plan.files)).write(to:directory.appendingPathComponent("receipt.json"))
        try Data("Test model notice".utf8).write(to:directory.appendingPathComponent("NOTICE.txt"))
        return directory
    }
    @Test(arguments:["missing","partial","same-size-corrupt","bad-receipt","missing-notice"])
    func obsoleteCopyStaysUntilTheReplacementFullyVerifies(_ failure: String) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let bytes = Data("model bytes".utf8)
        let old = plan("old-model",revision:"a",bytes:bytes), new = plan("new-model",revision:"b",bytes:bytes)
        let kept = try install(old,bytes:bytes,in:root)
        if failure != "missing" {
            let target = try install(new,bytes:bytes,in:root)
            switch failure {
            case "partial": try FileManager.default.removeItem(at:target.appendingPathComponent("receipt.json"))
            case "same-size-corrupt": try Data(repeating:0,count:bytes.count).write(to:target.appendingPathComponent("weights.bin"))
            case "bad-receipt": try Data("{}".utf8).write(to:target.appendingPathComponent("receipt.json"))
            case "missing-notice": try FileManager.default.removeItem(at:target.appendingPathComponent("NOTICE.txt"))
            default: break
            }
        }
        let downloader = ModelDownloader(appData:root,userAgent:"Cassini test")
        await #expect(throws:(any Error).self) { try await downloader.removeSuperseded(old.pin,afterVerifying:new) }
        #expect(ModelStorage.isInstalled(old,in:root))
        #expect(try Data(contentsOf:kept.appendingPathComponent("weights.bin")) == bytes)
    }
    @Test func verifiedReplacementRetiresOnlyTheOldIdAndKeepsAcceptedJobFiles() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let bytes = Data("model bytes".utf8)
        let old = plan("old-model",revision:"a",bytes:bytes), new = plan("new-model",revision:"b",bytes:bytes)
        let other = plan("unrelated",revision:"c",bytes:bytes)
        let retired = try install(old,bytes:bytes,in:root), current = try install(new,bytes:bytes,in:root)
        _ = try install(other,bytes:bytes,in:root)
        let accepted = root.appendingPathComponent("accepted-job"), acceptedNew = root.appendingPathComponent("accepted-new-job")
        try FileManager.default.linkItem(at:retired.appendingPathComponent("weights.bin"),to:accepted)
        try FileManager.default.linkItem(at:current.appendingPathComponent("weights.bin"),to:acceptedNew)
        let partial = root.appendingPathComponent("model-downloads/"+old.pin.id+"/"+old.pin.sourceSHA256)
        try FileManager.default.createDirectory(at:partial,withIntermediateDirectories:true)
        try bytes.write(to:partial.appendingPathComponent("partial"))
        let downloader = ModelDownloader(appData:root,userAgent:"Cassini test")
        try await downloader.removeSuperseded(old.pin,afterVerifying:new)
        #expect(!FileManager.default.fileExists(atPath:retired.path))
        #expect(!FileManager.default.fileExists(atPath:partial.path))
        #expect(ModelStorage.isInstalled(new,in:root) && ModelStorage.isInstalled(other,in:root))
        #expect(try Data(contentsOf:accepted) == bytes && Data(contentsOf:acceptedNew) == bytes)
        try await downloader.removeSuperseded(old.pin,afterVerifying:new) // Idempotent.
        #expect(ModelStorage.isInstalled(new,in:root))
    }
    @Test(arguments:[false,true]) func replacementIsRecheckedAfterItsLockAndCancellationKeepsOld(_ cancel: Bool) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let bytes = Data("model bytes".utf8)
        let old = plan("old-model",revision:"a",bytes:bytes), new = plan("new-model",revision:"b",bytes:bytes)
        _ = try install(old,bytes:bytes,in:root)
        let current = try install(new,bytes:bytes,in:root)
        let lockFile = current.deletingLastPathComponent().appendingPathComponent("."+new.pin.sourceSHA256+".lock")
        let fd = open(lockFile.path,O_RDWR | O_CREAT | O_CLOEXEC,0o600)
        try #require(fd >= 0); defer { _ = flock(fd,LOCK_UN); close(fd) }
        try #require(flock(fd,LOCK_EX | LOCK_NB) == 0)
        let waiting = XCTestExpectation(description:"Retirement reached the held replacement lock")
        waiting.assertForOverFulfill = false
        let downloader = try ModelDownloader(appData:root,fixtureOrigin:URL(string:"http://127.0.0.1:1")!,userAgent:"Cassini test",removalLockWaiting:{ waiting.fulfill() })
        let task = Task { try await downloader.removeSuperseded(old.pin,afterVerifying:new) }
        defer { task.cancel() }
        let observed = await XCTWaiter.fulfillment(of:[waiting],timeout:10)
        try #require(observed == .completed) // Failure-only guard; the failed flock is the event.
        #expect(ModelStorage.isInstalled(old,in:root))
        if cancel { task.cancel() }
        else { try Data(repeating:0,count:bytes.count).write(to:current.appendingPathComponent("weights.bin")) }
        _ = flock(fd,LOCK_UN)
        if cancel { await #expect(throws:CancellationError.self) { try await task.value } }
        else { await #expect(throws:ModelDownloadError.hash) { try await task.value } }
        #expect(ModelStorage.isInstalled(old,in:root))
    }
    @Test(arguments:[false,true]) func symlinkedCacheAncestorsCannotRedirectCleanup(_ idOnly: Bool) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let bytes = Data("model bytes".utf8)
        let old = plan("old-model",revision:"a",bytes:bytes), new = plan("new-model",revision:"b",bytes:bytes)
        _ = try install(old,bytes:bytes,in:root); _ = try install(new,bytes:bytes,in:root)
        let cache = root.appendingPathComponent("model-downloads")
        let partial = cache.appendingPathComponent(old.pin.id+"/"+old.pin.sourceSHA256+"/partial")
        try FileManager.default.createDirectory(at:partial.deletingLastPathComponent(),withIntermediateDirectories:true)
        try bytes.write(to:partial)
        let ancestor = idOnly ? cache.appendingPathComponent(old.pin.id) : cache
        let outside = root.appendingPathComponent("outside-cache")
        try FileManager.default.moveItem(at:ancestor,to:outside)
        try FileManager.default.createSymbolicLink(at:ancestor,withDestinationURL:outside)
        let downloader = ModelDownloader(appData:root,userAgent:"Cassini test")
        await #expect(throws:ModelDownloadError.unsafePath) { try await downloader.removeSuperseded(old.pin,afterVerifying:new) }
        #expect(ModelStorage.isInstalled(old,in:root) && ModelStorage.isInstalled(new,in:root))
        #expect(try Data(contentsOf:partial) == bytes,"Cleanup did not traverse the cache symlink")
    }
    @Test func symlinkedModelNamespaceCannotRedirectCleanup() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let bytes = Data("model bytes".utf8)
        let old = plan("old-model",revision:"a",bytes:bytes), new = plan("new-model",revision:"b",bytes:bytes)
        let original = try install(old,bytes:bytes,in:root); _ = try install(new,bytes:bytes,in:root)
        let models = root.appendingPathComponent("models"), outside = root.appendingPathComponent("outside-models")
        try FileManager.default.moveItem(at:models,to:outside)
        try FileManager.default.createSymbolicLink(at:models,withDestinationURL:outside)
        let downloader = ModelDownloader(appData:root,userAgent:"Cassini test")
        await #expect(throws:ModelDownloadError.unsafePath) { try await downloader.removeSuperseded(old.pin,afterVerifying:new) }
        #expect(try Data(contentsOf:original.appendingPathComponent("weights.bin")) == bytes)
    }
    @Test func oppositeConcurrentRetirementsLeaveOneFullyVerifiedCopy() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let bytes = Data("model bytes".utf8)
        let first = plan("old-model",revision:"a",bytes:bytes), second = plan("new-model",revision:"b",bytes:bytes)
        _ = try install(first,bytes:bytes,in:root); _ = try install(second,bytes:bytes,in:root)
        let a = ModelDownloader(appData:root,userAgent:"Cassini test"), b = ModelDownloader(appData:root,userAgent:"Cassini test")
        async let left: Void? = try? await a.removeSuperseded(first.pin,afterVerifying:second)
        async let right: Void? = try? await b.removeSuperseded(second.pin,afterVerifying:first)
        _ = await (left,right)
        let installed = [first,second].filter { ModelStorage.isInstalled($0,in:root) }
        #expect(installed.count == 1,"An inverse cleanup cannot retire the last verified copy")
    }
    @Test func symlinkedReplacementCannotAuthorizeOldIdDeletion() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let bytes = Data("model bytes".utf8)
        let old = plan("old-model",revision:"a",bytes:bytes), new = plan("new-model",revision:"b",bytes:bytes)
        _ = try install(old,bytes:bytes,in:root)
        let target = try install(new,bytes:bytes,in:root)
        let outside = root.appendingPathComponent("outside-install")
        try FileManager.default.moveItem(at:target,to:outside)
        try FileManager.default.createSymbolicLink(at:target,withDestinationURL:outside)
        let downloader = ModelDownloader(appData:root,userAgent:"Cassini test")
        await #expect(throws:(any Error).self) { try await downloader.removeSuperseded(old.pin,afterVerifying:new) }
        #expect(ModelStorage.isInstalled(old,in:root))
        #expect(try Data(contentsOf:outside.appendingPathComponent("weights.bin")) == bytes)
    }
}
