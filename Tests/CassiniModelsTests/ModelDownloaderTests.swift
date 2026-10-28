// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniModels

private let pin = ModelPin(id:"fixture-model",sourceSHA256:String(repeating:"a",count:64))
private let enough: @Sendable (URL) throws -> ModelDiskSpace = { _ in .init(free:20 << 30,total:100 << 30) }
private final class Server: @unchecked Sendable {
    let process = Process()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniModelTests-" + UUID().uuidString)
    let origin: URL
    let log: URL
    init(_ scenario: String) throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        log = root.appendingPathComponent("requests.jsonl")
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/env")
        process.arguments = ["python3",Bundle.module.url(forResource:"server",withExtension:"py",subdirectory:"Fixtures")!.path,"--scenario",scenario,"--log",log.path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount:1), !byte.isEmpty, byte != Data([10]) { line.append(byte) }
        guard let value = String(data:line,encoding:.utf8), let url = URL(string:value), url.host == "127.0.0.1" else { process.terminate(); throw ModelDownloadError.response }
        origin = url
    }
    deinit { process.terminate(); process.waitUntilExit(); try? FileManager.default.removeItem(at:root) }
    var appData: URL { root.appendingPathComponent("data") }
    func downloader(budget: @escaping @Sendable (URL) throws -> ModelDiskSpace = enough) throws -> ModelDownloader { try .init(appData:appData,fixtureOrigin:origin,budget:budget) }
    var requests: [[String:Any]] { ((try? String(contentsOf:log,encoding:.utf8)) ?? "").split(separator:"\n").compactMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any] } }
    var destination: URL { appData.appendingPathComponent("models/" + pin.id + "/" + pin.sourceSHA256) }
}
private func fails(_ run: () async throws -> Void) async -> Error? { do { try await run(); Issue.record("Expected failure"); return nil } catch { return error } }

@Suite struct ModelDownloaderTests {
    @Test(arguments:["normal","no-length"]) func installVerifyNoNetworkReuseAndRemove(_ scenario: String) async throws {
        let server = try Server(scenario), downloader = try server.downloader()
        #expect(server.requests.isEmpty)
        let plan = try await downloader.plan(pin)
        #expect(plan.files.count == 2)
        #expect(try await downloader.spaceRequired(for:plan) > plan.rawBytes)
        let result = try await downloader.install(pin)
        #expect(result == server.destination)
        #expect(try ModelFiles.size(result.appendingPathComponent("weights.bin")) == plan.files[0].rawBytes)
        #expect(try ModelFiles.digest(result.appendingPathComponent("weights.bin")) == plan.files[0].rawSHA256)
        #expect(try String(contentsOf:result.appendingPathComponent("NOTICE.txt"),encoding:.utf8).contains("Local fixture"))
        #expect(ModelStorage.notices(in:server.appData) == [result.appendingPathComponent("NOTICE.txt")])
        let before = server.requests.filter { ($0["path"] as? String)?.hasPrefix("/models/") == true }.count
        _ = try await downloader.install(pin)
        #expect(server.requests.filter { ($0["path"] as? String)?.hasPrefix("/models/") == true }.count == before)
        #expect(server.requests.allSatisfy { $0["encoding"] as? String == "identity" })
        #expect(!server.requests.contains { ($0["path"] as? String)?.contains("example.invalid") == true })
        try await downloader.remove(pin); #expect(!FileManager.default.fileExists(atPath:result.path)); #expect(ModelStorage.notices(in:server.appData).isEmpty)
        _ = try await downloader.install(pin); #expect(FileManager.default.fileExists(atPath:result.path))
    }
    @Test(arguments:["truncated","416","ignore-range"]) func resumeWithRangeAndIfRange(_ scenario: String) async throws {
        let server = try Server(scenario), downloader = try server.downloader()
        _ = await fails { _ = try await downloader.install(pin) }
        #expect(!FileManager.default.fileExists(atPath:server.destination.path))
        _ = try await downloader.install(pin)
        let ranged = server.requests.filter { $0["range"] is String }
        #expect(ranged.count == 1)
        let manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:Bundle.module.url(forResource:"manifest",withExtension:"json",subdirectory:"Fixtures")!)) as! [String:Any]
        let digest = (manifest["artifacts"] as! [[String:Any]])[0]["sha256"] as! String
        #expect(ranged.first?["ifRange"] as? String == "\"" + digest + "\"")
    }
    @Test(arguments:["changed-etag","bad-range"]) func changedIdentityNeverAppends(_ scenario: String) async throws {
        let server = try Server(scenario), downloader = try server.downloader()
        _ = await fails { _ = try await downloader.install(pin) }
        let error = await fails { _ = try await downloader.install(pin) }
        #expect((error as? ModelDownloadError) == (scenario == "changed-etag" ? .etag : .range))
        #expect(!FileManager.default.fileExists(atPath:server.destination.path))
        _ = try await downloader.install(pin)
        #expect(server.requests.filter { $0["range"] is String }.count == 1)
    }
    @Test(arguments:["compressed-hash","raw-hash","unsafe-path","wrong-origin","redirect"]) func rejectsWithoutPublishing(_ scenario: String) async throws {
        let server = try Server(scenario), downloader = try server.downloader()
        let error = await fails { _ = try await downloader.install(pin) }
        if scenario.contains("hash") { #expect(error as? ModelDownloadError == .hash) }
        #expect(!FileManager.default.fileExists(atPath:server.destination.path))
        let folders = (try? FileManager.default.contentsOfDirectory(atPath:server.destination.deletingLastPathComponent().path)) ?? []
        #expect(!folders.contains { $0.hasPrefix(".install-") })
        if scenario == "unsafe-path" || scenario == "wrong-origin" { #expect(server.requests.count == 1) }
    }
    @Test func fullDiskStopsBeforeArtifact() async throws {
        let server = try Server("normal"), downloader = try server.downloader(budget:{ _ in .init(free:1 << 30,total:100 << 30) })
        let error = await fails { _ = try await downloader.install(pin) }
        guard case .diskSpace = error as? ModelDownloadError else { Issue.record("Missing disk budget failure"); return }
        #expect(server.requests.count == 1)
        #expect(!FileManager.default.fileExists(atPath:server.destination.path))
    }
    @Test func cancelAndRemoveWaitForTransferWithoutResurrection() async throws {
        let server = try Server("slow"), downloader = try server.downloader()
        let task = Task { try await downloader.install(pin) }
        for _ in 0..<200 { if server.requests.count >= 2 { break }; try await Task.sleep(for:.milliseconds(10)) }
        await downloader.cancel(pin)
        _ = await fails { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath:server.destination.path))
        let task2 = Task { try await downloader.install(pin) }
        try await Task.sleep(for:.milliseconds(30))
        try await downloader.remove(pin)
        _ = await fails { _ = try await task2.value }
        #expect(!FileManager.default.fileExists(atPath:server.destination.path))
        #expect(!FileManager.default.fileExists(atPath:server.appData.appendingPathComponent("model-downloads/" + pin.id + "/" + pin.sourceSHA256).path))
    }
    @Test func revisionPinMustBePresentAndOriginalInstallSurvivesBadUpdate() async throws {
        let server = try Server("normal"), downloader = try server.downloader()
        _ = try await downloader.install(pin)
        let bytes = try Data(contentsOf:server.destination.appendingPathComponent("weights.bin"))
        let missing = ModelPin(id:pin.id,sourceSHA256:String(repeating:"b",count:64))
        let error = await fails { _ = try await downloader.install(missing) }
        #expect(error as? ModelDownloadError == .pinUnavailable)
        #expect(try Data(contentsOf:server.destination.appendingPathComponent("weights.bin")) == bytes)
    }
    @Test func invalidZstdAndRawLimitNeverPublish() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false); defer { try? FileManager.default.removeItem(at:root) }
        let compressed = root.appendingPathComponent("bad.zst"), output = root.appendingPathComponent("raw")
        try Data("not a zstd frame".utf8).write(to:compressed)
        let invalid = ModelAsset(path:"raw",url:URL(string:"https://dist.gocassini.com/unused")!,compressedBytes:16,compressedSHA256:String(repeating:"a",count:64),rawBytes:32,rawSHA256:String(repeating:"b",count:64))
        #expect(throws:ModelDownloadError.zstd) { try ModelFiles.decode(invalid,compressed:compressed,output:output) }
        try FileManager.default.removeItem(at:output)
        let valid = Bundle.module.url(forResource:"weights.bin",withExtension:"zst",subdirectory:"Fixtures")!
        let tiny = ModelAsset(path:"raw",url:invalid.url,compressedBytes:1,compressedSHA256:invalid.compressedSHA256,rawBytes:1,rawSHA256:invalid.rawSHA256)
        #expect(throws:ModelDownloadError.zstd) { try ModelFiles.decode(tiny,compressed:valid,output:output) }
        #expect(try ModelFiles.size(output) == 0)
        let budget = ModelDiskSpace(free:(1 << 30) + 10,total:10 << 30)
        try budget.check(required:10)
        #expect(throws:ModelDownloadError.diskSpace(required:11,available:10)) { try budget.check(required:11) }
        #expect(ModelDiskSpace(free:10,total:100 << 30).reserve == 2 << 30)
    }
    @Test func manifestAndFilesystemBoundaries() throws {
        #expect(!ModelPin(id:"../escape",sourceSHA256:pin.sourceSHA256).valid)
        #expect(!ModelPin(id:pin.id,sourceSHA256:String(repeating:"A",count:64)).valid)
        #expect(!ModelManifest.pathValid("a/../b")); #expect(!ModelManifest.pathValid("/abs")); #expect(!ModelManifest.pathValid("a//b"))
        #expect(!ModelManifest.pathValid("receipt.json")); #expect(!ModelManifest.pathValid("NOTICE.txt"))
        #expect(throws:ModelDownloadError.origin) { try ModelOrigin(URL(string:"https://evil.invalid")!) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false); defer { try? FileManager.default.removeItem(at:root) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:root)
        #expect(throws:ModelDownloadError.unsafePath) { try ModelFiles.directory(link) }
        #expect(throws:ModelDownloadError.unsafePath) { try ModelFiles.size(link) }
        let duplicate = Data("{\"schema_version\":2,\"schema_version\":2}".utf8)
        #expect(throws:(any Error).self) { try ModelManifest.plan(duplicate,pin:pin) }
    }
}
