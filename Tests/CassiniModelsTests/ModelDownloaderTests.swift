// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import Darwin
@testable import CassiniModels

private let pin = ModelPin(id:"fixture-model",sourceSHA256:String(repeating:"a",count:64))
private let enough: @Sendable (URL) throws -> ModelDiskSpace = { _ in .init(free:20 << 30,total:100 << 30) }
private final class Server: @unchecked Sendable {
    let process = Process()
    private let control = Pipe(), prefixLock = NSLock()
    private var sentPrefix = false
    var prefixAcknowledged: Bool { prefixLock.withLock { sentPrefix } }
    func acknowledgePersistedPrefix(_ progress: ModelDownloadProgress) {
        guard progress.receivedBytes > 0 else { return }
        prefixLock.withLock {
            guard !sentPrefix else { return }
            do {
                try control.fileHandleForWriting.write(contentsOf:Data("prefix-persisted\n".utf8))
                sentPrefix = true
            } catch { /* The caller asserts the acknowledgement before retry. */ }
        }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniModelTests-" + UUID().uuidString)
    let origin: URL
    let log: URL
    init(_ scenario: String) throws {
        guard fcntl(control.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)
        }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        log = root.appendingPathComponent("requests.jsonl")
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/env")
        process.arguments = ["python3",Bundle.module.url(forResource:"server",withExtension:"py",subdirectory:"Fixtures")!.path,"--scenario",scenario,"--log",log.path]
        process.standardInput = control
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

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ModelDownloadProgress] = []
    func add(_ value: ModelDownloadProgress) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [ModelDownloadProgress] { lock.lock(); defer { lock.unlock() }; return values }
}

@Suite struct ModelDownloaderTests {
    @Test func acceptedInferenceLinksDoNotInvalidateOrRedownloadAnInstalledModel() async throws {
        let server = try Server("normal"), downloader = try server.downloader()
        let plan = try await downloader.plan(pin)
        _ = try await downloader.install(pin)
        let weights = server.destination.appendingPathComponent("weights.bin"), lease = server.root.appendingPathComponent("accepted-job-weights")
        let bytes = try Data(contentsOf:weights)
        #expect(link(weights.path,lease.path) == 0)
        #expect(ModelStorage.isInstalled(plan,in:server.appData,verifyHashes:false))
        #expect(ModelStorage.isInstalled(plan,in:server.appData))
        let transfers = server.requests.filter { ($0["path"] as? String)?.hasSuffix(".zst") == true }.count
        #expect(transfers > 0)
        #expect(try await downloader.removeInvalid(plan) == false)
        _ = try await downloader.install(pin)
        #expect(server.requests.filter { ($0["path"] as? String)?.hasSuffix(".zst") == true }.count == transfers)
        let stream = try FileHandle(forWritingTo:lease)
        try stream.write(contentsOf:Data([bytes[0] ^ 0xff]))
        #expect(!ModelStorage.isInstalled(plan,in:server.appData))
        try stream.seek(toOffset:0); try stream.write(contentsOf:bytes.prefix(1)); try stream.close()
        #expect(ModelStorage.isInstalled(plan,in:server.appData))
        try await downloader.remove(pin)
        #expect(!FileManager.default.fileExists(atPath:server.destination.path))
        #expect(try Data(contentsOf:lease) == bytes)
    }
    @Test(arguments:["weights.bin","receipt.json","NOTICE.txt"]) func retryRepairsAnIncompleteInstallation(_ missing: String) async throws {
        let server = try Server("normal"), downloader = try server.downloader()
        let plan = try await downloader.plan(pin)
        _ = try await downloader.install(pin)
        try FileManager.default.removeItem(at:server.destination.appendingPathComponent(missing))
        let repaired = try await downloader.install(pin)
        for asset in plan.files { #expect(try ModelFiles.digest(repaired.appendingPathComponent(asset.path)) == asset.rawSHA256) }
        #expect(try ModelFiles.size(repaired.appendingPathComponent("NOTICE.txt")) != nil)
        #expect(try ModelFiles.size(repaired.appendingPathComponent("receipt.json")) != nil)
    }
    @Test func retryRepairsSameSizeCorruptWeights() async throws {
        let server = try Server("normal"), downloader = try server.downloader()
        let plan = try await downloader.plan(pin)
        _ = try await downloader.install(pin)
        let weights = server.destination.appendingPathComponent("weights.bin")
        try Data(repeating:0,count:Int(plan.files[0].rawBytes)).write(to:weights)
        _ = try await downloader.install(pin)
        #expect(try ModelFiles.digest(weights) == plan.files[0].rawSHA256)
    }
    @Test func removeWaitsForAnExternalCancelledTransferToReleaseTheRevisionLock() async throws {
        let server = try Server("normal"), downloader = try server.downloader()
        _ = try await downloader.install(pin)
        let path = server.destination.deletingLastPathComponent().appendingPathComponent("." + pin.sourceSHA256 + ".lock")
        let fd = open(path.path,O_RDWR | O_CLOEXEC)
        #expect(fd >= 0); #expect(flock(fd,LOCK_EX | LOCK_NB) == 0)
        Thread.detachNewThread { Thread.sleep(forTimeInterval:0.15); flock(fd,LOCK_UN); close(fd) }
        try await server.downloader().remove(pin)
        #expect(!FileManager.default.fileExists(atPath:server.destination.path))
    }
    @Test func cancellationWhileWaitingForRemoveLeavesTheInstallationIntact() async throws {
        let server = try Server("normal"), downloader = try server.downloader()
        _ = try await downloader.install(pin)
        let path = server.destination.deletingLastPathComponent().appendingPathComponent("." + pin.sourceSHA256 + ".lock")
        let fd = open(path.path,O_RDWR | O_CLOEXEC)
        guard fd >= 0,flock(fd,LOCK_EX | LOCK_NB) == 0 else { if fd >= 0 { close(fd) }; throw ModelDownloadError.busy }
        defer { flock(fd,LOCK_UN); close(fd) }
        let task = Task { try await server.downloader().remove(pin) }
        try await Task.sleep(for:.milliseconds(100)); task.cancel()
        let error = await fails { try await task.value }
        #expect(error is CancellationError)
        #expect(FileManager.default.fileExists(atPath:server.destination.path))
    }
    @Test func inventoryRequiresReceiptAndNoticeAndNeverFetchesMetadata() async throws {
        let server = try Server("normal"), downloader = try server.downloader()
        let plan = try await downloader.plan(pin)
        _ = try await downloader.install(pin)
        let count = server.requests.count
        #expect(ModelStorage.isInstalled(plan,in:server.appData,verifyHashes:false))
        for name in ["NOTICE.txt","receipt.json"] {
            let file = server.destination.appendingPathComponent(name), bytes = try Data(contentsOf:file)
            try FileManager.default.removeItem(at:file)
            #expect(!ModelStorage.isInstalled(plan,in:server.appData,verifyHashes:false))
            try bytes.write(to:file)
        }
        #expect(server.requests.count == count)
    }
    @Test func repairUnlinksAnUnsafeChildWithoutFollowingItsTarget() async throws {
        let server = try Server("normal"), downloader = try server.downloader()
        _ = try await downloader.install(pin)
        let sentinel = server.root.appendingPathComponent("sentinel"), bytes = Data("Keep this private file".utf8)
        try bytes.write(to:sentinel)
        let weights = server.destination.appendingPathComponent("weights.bin")
        try FileManager.default.removeItem(at:weights)
        try FileManager.default.createSymbolicLink(at:weights,withDestinationURL:sentinel)
        _ = try await downloader.install(pin)
        #expect(try Data(contentsOf:sentinel) == bytes)
        #expect(try ModelFiles.size(weights) != nil)
    }
    @Test func staleInventoryDoesNotRemoveAnInstallationRepairedWhileWaitingForItsLock() async throws {
        let server = try Server("normal"), downloader = try server.downloader()
        let plan = try await downloader.plan(pin)
        _ = try await downloader.install(pin)
        let weights = server.destination.appendingPathComponent("weights.bin"), original = try Data(contentsOf:server.destination.appendingPathComponent("weights.bin"))
        try Data(repeating:0,count:original.count).write(to:weights)
        let lockFile = server.destination.deletingLastPathComponent().appendingPathComponent("." + pin.sourceSHA256 + ".lock")
        let fd = open(lockFile.path,O_RDWR | O_CLOEXEC)
        guard fd >= 0,flock(fd,LOCK_EX | LOCK_NB) == 0 else { if fd >= 0 { close(fd) }; throw ModelDownloadError.busy }
        let removal = Task { try await server.downloader().removeInvalid(plan) }
        try await Task.sleep(for:.milliseconds(100))
        try original.write(to:weights)
        flock(fd,LOCK_UN); close(fd)
        #expect(try await removal.value == false)
        #expect(ModelStorage.isInstalled(plan,in:server.appData))
    }
    @Test func progressReportsBytesAndMarksOnlyTheAtomicInstallComplete() async throws {
        let server = try Server("normal"), downloader = try server.downloader(), log = ProgressLog()
        let plan = try await downloader.plan(pin)
        let installed = try await downloader.install(pin) { log.add($0) }
        let states = log.snapshot()
        #expect(states.first?.receivedBytes == 0)
        #expect(states.last?.receivedBytes == plan.compressedBytes && states.last?.isInstalled == true)
        #expect(states.allSatisfy { $0.totalBytes == plan.compressedBytes && $0.receivedBytes <= $0.totalBytes })
        #expect(states.map(\.receivedBytes) == states.map(\.receivedBytes).sorted())
        #expect(states.dropLast().allSatisfy { !$0.isInstalled })
        #expect(FileManager.default.fileExists(atPath:installed.appendingPathComponent("receipt.json").path))
    }
    @Test func aBadDecodedHashNeverReportsAnInstalledModel() async throws {
        let server = try Server("raw-hash"), downloader = try server.downloader(), log = ProgressLog()
        let error = await fails { _ = try await downloader.install(pin) { log.add($0) } }
        #expect(error as? ModelDownloadError == .hash)
        #expect(!log.snapshot().isEmpty && !log.snapshot().contains { $0.isInstalled })
        #expect(!FileManager.default.fileExists(atPath:server.destination.path))
    }

    @Test(arguments:["normal","no-length"]) func installVerifyReuseWithoutArtifactDownloadAndRemove(_ scenario: String) async throws {
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
        #expect(server.requests.allSatisfy { $0["userAgent"] as? String == ModelHTTP.userAgent })
        #expect(!server.requests.contains { ($0["path"] as? String)?.contains("example.invalid") == true })
        try await downloader.remove(pin); #expect(!FileManager.default.fileExists(atPath:result.path)); #expect(ModelStorage.notices(in:server.appData).isEmpty)
        _ = try await downloader.install(pin); #expect(FileManager.default.fileExists(atPath:result.path))
    }
    @Test(arguments:["truncated","416","ignore-range"]) func resumeWithRangeAndIfRange(_ scenario: String) async throws {
        let server = try Server(scenario), downloader = try server.downloader()
        _ = await fails { _ = try await downloader.install(pin) { server.acknowledgePersistedPrefix($0) } }
        try #require(server.prefixAcknowledged,"Fault follows a real persisted-prefix event")
        #expect(!FileManager.default.fileExists(atPath:server.destination.path))
        _ = try await downloader.install(pin)
        let ranged = server.requests.filter { $0["range"] is String }
        #expect(ranged.count == 1)
        let manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:Bundle.module.url(forResource:"manifest",withExtension:"json",subdirectory:"Fixtures")!)) as! [String:Any]
        let digest = (manifest["artifacts"] as! [[String:Any]])[0]["sha256"] as! String
        #expect(ranged.first?["ifRange"] as? String == "\"" + digest + "\"")
    }
    @Test func transientServerFailureRetainsPreviouslyValidatedPrefix() async throws {
        let server = try Server("503"), downloader = try server.downloader()
        _ = await fails { _ = try await downloader.install(pin) { server.acknowledgePersistedPrefix($0) } }
        try #require(server.prefixAcknowledged,"Fault follows a real persisted-prefix event")
        let error = await fails { _ = try await downloader.install(pin) }
        #expect(error as? ModelDownloadError == .response)
        _ = try await downloader.install(pin)
        let ranges = server.requests.compactMap { $0["range"] as? String }
        #expect(ranges.count == 2 && ranges[0] == ranges[1])
    }
    @Test(arguments:["changed-etag","bad-range"]) func changedIdentityNeverAppends(_ scenario: String) async throws {
        let server = try Server(scenario), downloader = try server.downloader()
        _ = await fails { _ = try await downloader.install(pin) { server.acknowledgePersistedPrefix($0) } }
        try #require(server.prefixAcknowledged,"Fault follows a real persisted-prefix event")
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
