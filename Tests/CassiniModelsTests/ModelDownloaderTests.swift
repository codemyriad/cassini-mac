// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import XCTest
import Darwin
@testable import CassiniModels

private let pin = ModelPin(id:"fixture-model",sourceSHA256:String(repeating:"a",count:64))
private let enough: @Sendable (URL) throws -> ModelDiskSpace = { _ in .init(free:20 << 30,total:100 << 30) }
/// D54: the exact header the app layer would build for CassiniTalk 9.8.7 on macOS 15.1, arm64.
private let agent = "CassiniTalk/9.8.7 (macOS 15.1; arm64)"
private final class Server: @unchecked Sendable {
    // Bound cold starts only where CI opts in; ready servers remain concurrent.
    private static let bootstrapAdmission: DispatchSemaphore? = {
        guard let value = ProcessInfo.processInfo.environment["CASSINI_FIXTURE_BOOTSTRAP_LIMIT"],
              let limit = Int(value), limit > 0 else { return nil }
        return DispatchSemaphore(value:limit)
    }()
    let process = Process()
    private let exited: DispatchSemaphore
    private let diagnosticRoot: URL?
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
    /// Pipe readiness and process teardown must never occupy a cooperative executor.
    static func start(_ scenario: String, startupTimeout: TimeInterval = 10, diagnostics: URL? = nil,
                      isolation: isolated (any Actor)? = #isolation,
                      onLaunched: @escaping @Sendable (FileHandle) -> Void = { _ in }) async throws -> Server {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                Self.bootstrapAdmission?.wait()
                defer { Self.bootstrapAdmission?.signal() }
                do { continuation.resume(returning:try Server(scenario,startupTimeout:startupTimeout,diagnostics:diagnostics,onLaunched:onLaunched)) }
                catch { continuation.resume(throwing:error) }
            }
        }
    }
    struct BootstrapFailure: Error, CustomStringConvertible {
        let description: String
        let pid: Int32
        let folder: URL
    }
    private init(_ scenario: String, startupTimeout: TimeInterval, diagnostics: URL?,
                 onLaunched: @Sendable (FileHandle) -> Void) throws {
        let exitEvent = DispatchSemaphore(value:0); exited = exitEvent
        guard fcntl(control.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)
        }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        log = root.appendingPathComponent("requests.jsonl")
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/env")
        process.arguments = ["python3",Bundle.module.url(forResource:"server",withExtension:"py",subdirectory:"Fixtures")!.path,"--scenario",scenario,"--log",log.path,"--forbid-dns"]
        let diagnostics = diagnostics ?? ProcessInfo.processInfo.environment["CASSINI_FIXTURE_DIAGNOSTICS"].map { URL(fileURLWithPath:$0) }
        diagnosticRoot = diagnostics
        if let diagnostics {
            var environment = ProcessInfo.processInfo.environment
            environment["CASSINI_FIXTURE_DIAGNOSTICS"] = diagnostics.path
            process.environment = environment
        }
        process.standardInput = control
        let errors = root.appendingPathComponent("bootstrap.stderr")
        _ = FileManager.default.createFile(atPath:errors.path,contents:nil)
        let errorFile = try FileHandle(forWritingTo:errors)
        defer { try? errorFile.close() }
        process.standardOutput = pipe; process.standardError = errorFile
        process.terminationHandler = { _ in exitEvent.signal() }
        let child = process, folder = root
        var admitted = false
        defer { if !admitted { Self.reap(child,exited:exitEvent); try? FileManager.default.removeItem(at:folder) } }
        let launchedAt = DispatchTime.now().uptimeNanoseconds
        try process.run()
        onLaunched(control.fileHandleForWriting)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(startupTimeout*1_000_000_000)
        let fd = pipe.fileHandleForReading.fileDescriptor
        var line = Data(), published = false
        while DispatchTime.now().uptimeNanoseconds < deadline {
            var ready = pollfd(fd:fd,events:Int16(POLLIN | POLLHUP),revents:0)
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { break }
            let remaining = deadline-now
            let count = poll(&ready,1,Int32(min(100,remaining/1_000_000)))
            if count < 0 { if errno == EINTR { continue }; throw ModelDownloadError.response }
            if count == 0 { continue }
            guard let byte = try pipe.fileHandleForReading.read(upToCount:1), !byte.isEmpty else { break }
            if byte == Data([10]) { published = true; break }
            line.append(byte)
        }
        guard published, let value = String(data:line,encoding:.utf8), let url = URL(string:value), url.host == "127.0.0.1" else {
            Self.captureBootstrap(process,scenario:scenario,errors:errors,launchedAt:launchedAt,ready:false,diagnostics:diagnostics,exited:exitEvent)
            let diagnostic = (try? String(contentsOf:errors,encoding:.utf8)) ?? ""
            throw BootstrapFailure(description:"Fixture \(scenario) failed readiness (newline=\(published), running=\(process.isRunning), stdout=\(String(decoding:line,as:UTF8.self)), stderr=\(diagnostic.prefix(4096)))",pid:process.processIdentifier,folder:root)
        }
        origin = url; admitted = true
        Self.captureBootstrap(process,scenario:scenario,errors:errors,launchedAt:launchedAt,ready:true,diagnostics:diagnostics,exited:exitEvent)
    }
    /// Exercise the real failure capture after a positive readiness handshake,
    /// without waiting for a deliberately expired startup deadline in this test.
    func captureFailureDiagnostics() {
        Self.captureBootstrap(process,scenario:"normal",errors:root.appendingPathComponent("bootstrap.stderr"),
                              launchedAt:DispatchTime.now().uptimeNanoseconds,ready:false,diagnostics:diagnosticRoot,exited:exited)
    }
    /// CI evidence: sample the actual timed-out child before defer reaps it.
    private static func captureBootstrap(_ child: Process, scenario: String, errors: URL,
                                         launchedAt: UInt64, ready: Bool, diagnostics: URL?, exited: DispatchSemaphore) {
        guard let root = diagnostics else { return }
        let stem = "\(child.processIdentifier)-\(scenario)"
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let value: [String:Any] = ["pid":Int(child.processIdentifier),"scenario":scenario,"ready":ready,
                "running":child.isRunning,"elapsedMs":Double(DispatchTime.now().uptimeNanoseconds-launchedAt)/1_000_000,
                "arguments":child.arguments ?? [],"PATH":child.environment?["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""]
            try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent(stem+".json"))
            if FileManager.default.fileExists(atPath:errors.path) {
                try Data(contentsOf:errors).write(to:root.appendingPathComponent(stem+".stderr.txt"))
            }
            guard !ready, scenario != "no-ready", scenario != "invalid-ready", child.isRunning else { return }
            // The registered native handler writes every Python thread stack,
            // then chains SIGUSR1's default termination. Child exit is the
            // completion event; no sleep or racing stderr-prefix read is needed.
            let registered = root.appendingPathComponent("\(child.processIdentifier).python-handler-ready")
            if FileManager.default.fileExists(atPath:registered.path), kill(child.processIdentifier,SIGUSR1) == 0,
               exited.wait(timeout:.now()+2) == .success {
                exited.signal() // Preserve the existing cleanup's exit event.
                return
            }
            func capture(_ executable: String, _ arguments: [String], name: String) throws {
                let output = root.appendingPathComponent(stem+name)
                _ = FileManager.default.createFile(atPath:output.path,contents:nil)
                let handle = try FileHandle(forWritingTo:output); defer { try? handle.close() }
                let command = Process(), ended = DispatchSemaphore(value:0)
                command.executableURL = URL(fileURLWithPath:executable); command.arguments = arguments
                command.standardOutput = handle; command.standardError = handle
                command.terminationHandler = { _ in ended.signal() }
                try command.run()
                if ended.wait(timeout:.now()+4) == .timedOut, command.isRunning {
                    kill(command.processIdentifier,SIGKILL); _ = ended.wait(timeout:.now()+2)
                }
                if !command.isRunning { command.waitUntilExit() }
            }
            try capture("/bin/ps",["-p",String(child.processIdentifier),"-o","pid=,ppid=,state=,etime=,time=,command="],name:".process.txt")
            try capture("/usr/bin/sample",[String(child.processIdentifier),"1","10","-file",root.appendingPathComponent(stem+".stack.txt").path],name:".sample.log")
        } catch { fputs("Bootstrap diagnostic failed: \(error)\n",stderr) }
    }
    private static func reap(_ process: Process, exited: DispatchSemaphore) {
        guard process.processIdentifier > 0 else { return }
        if process.isRunning { process.terminate() }
        if exited.wait(timeout:.now()+3) == .timedOut, process.isRunning {
            kill(process.processIdentifier,SIGKILL)
            _ = exited.wait(timeout:.now()+2)
        }
        if !process.isRunning { process.waitUntilExit() }
    }
    deinit {
        let child = process, event = exited, folder = root
        Thread.detachNewThread {
            Self.reap(child,exited:event)
            try? FileManager.default.removeItem(at:folder)
        }
    }
    var appData: URL { root.appendingPathComponent("data") }
    func downloader(budget: @escaping @Sendable (URL) throws -> ModelDiskSpace = enough,
                    removalLockWaiting: (@Sendable () -> Void)? = nil) throws -> ModelDownloader {
        try .init(appData:appData,fixtureOrigin:origin,userAgent:agent,budget:budget,removalLockWaiting:removalLockWaiting)
    }
    var requests: [[String:Any]] { ((try? String(contentsOf:log,encoding:.utf8)) ?? "").split(separator:"\n").compactMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any] } }
    var destination: URL { appData.appendingPathComponent("models/" + pin.id + "/" + pin.sourceSHA256) }
}
/// The child cannot publish readiness until this actor runs again after start suspends.
private actor FixtureBootstrapActor {
    // Exercise caller isolation without depending on unrelated CPU-heavy tests
    // leaving room in Swift's cooperative pool for the readiness acknowledgement.
    nonisolated let executor = DispatchSerialQueue(label:"CassiniModelFixture.bootstrap-actor")
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    func start() async throws -> Server {
        try await Server.start("await-ready",onLaunched:{ control in
            self.executor.async {
                self.assumeIsolated { actor in actor.release(control) }
            }
        })
    }
    private func release(_ control: FileHandle) {
        do { try control.write(contentsOf:Data("start\n".utf8)) }
        catch { Issue.record("Fixture actor could not acknowledge startup: \(error)") }
    }
}
private func fails(_ run: () async throws -> Void) async -> Error? { do { try await run(); Issue.record("Expected failure"); return nil } catch { return error } }

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ModelDownloadProgress] = []
    func add(_ value: ModelDownloadProgress) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [ModelDownloadProgress] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Progress is emitted only after the production delegate writes the bytes.
/// A cached prefix is insufficient to signal that a resumed transfer started.
private final class PendingTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private let minimumBytes: UInt64
    private let event = XCTestExpectation(description:"Pending transfer wrote new bytes")
    init(after bytes: UInt64 = 0) { minimumBytes = bytes }
    func receive(_ progress: ModelDownloadProgress) {
        guard !progress.isInstalled, progress.receivedBytes > minimumBytes else { return }
        let first = lock.withLock { if signalled { return false }; signalled = true; return true }
        if first { event.fulfill() }
    }
    func wait() async throws {
        let result = await XCTWaiter.fulfillment(of:[event],timeout:2)
        try #require(result == .completed,"The transfer must write bytes before cancellation")
    }
}

/// A real failed flock attempt establishes that removal is waiting, rather
/// than merely that its task was scheduled. Success never comes from a timer.
private final class RemovalLockEvent: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private let event = XCTestExpectation(description:"Removal reached the held revision lock")
    func signal() {
        let first = lock.withLock { if signalled { return false }; signalled = true; return true }
        if first { event.fulfill() }
    }
    func wait() async throws {
        let result = await XCTWaiter.fulfillment(of:[event],timeout:2)
        try #require(result == .completed,"The removal must actually wait for the external lock")
    }
}

@Suite struct ModelDownloaderTests {
    @Test func failureCaptureRetainsTheRealChildsPythonStackAndWaitsForItsExit() async throws {
        let diagnostics = FileManager.default.temporaryDirectory.appendingPathComponent("PythonStack-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:diagnostics) }
        let server = try await Server.start("normal",diagnostics:diagnostics)
        // The ordinary readiness event proves the handler is installed. Invoke
        // the same failure capture used after a timeout; no settling sleep or
        // shorter startup deadline introduces another race under CI load.
        server.captureFailureDiagnostics()
        let pid = server.process.processIdentifier
        let stack = try String(contentsOf:diagnostics.appendingPathComponent("\(pid).python-stack.txt"),encoding:.utf8)
        #expect(stack.contains("server.py"))
        #expect(kill(pid,0) == -1 && errno == ESRCH)
    }
    @Test func fixtureBootstrapWithoutAReadinessEventFailsAndReapsItsChild() async throws {
        let failure = try #require(await fails {
            _ = try await Server.start("no-ready",startupTimeout:0.1)
        } as? Server.BootstrapFailure)
        #expect(kill(failure.pid,0) == -1 && errno == ESRCH)
        #expect(!FileManager.default.fileExists(atPath:failure.folder.path))
    }
    @Test func fixtureBootstrapReportsTheChildsErrorAndInvalidReadinessLine() async throws {
        let failure = try #require(await fails {
            _ = try await Server.start("invalid-ready")
        } as? Server.BootstrapFailure)
        #expect(failure.description.contains("deliberate fixture startup failure"))
        #expect(failure.description.contains("stdout=invalid readiness"))
        #expect(kill(failure.pid,0) == -1 && errno == ESRCH)
        #expect(!FileManager.default.fileExists(atPath:failure.folder.path))
    }
    @Test func readinessCanDependOnTheCallingActorMakingProgress() async throws {
        let server = try await FixtureBootstrapActor().start()
        let downloader = try server.downloader()
        _ = try await downloader.plan(pin)
        #expect(server.requests.contains { $0["path"] as? String == "/manifest.json" })
    }
    @Test func acceptedInferenceLinksDoNotInvalidateOrRedownloadAnInstalledModel() async throws {
        let server = try await Server.start("normal"), downloader = try server.downloader()
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
        let server = try await Server.start("normal"), downloader = try server.downloader()
        let plan = try await downloader.plan(pin)
        _ = try await downloader.install(pin)
        try FileManager.default.removeItem(at:server.destination.appendingPathComponent(missing))
        let repaired = try await downloader.install(pin)
        for asset in plan.files { #expect(try ModelFiles.digest(repaired.appendingPathComponent(asset.path)) == asset.rawSHA256) }
        #expect(try ModelFiles.size(repaired.appendingPathComponent("NOTICE.txt")) != nil)
        #expect(try ModelFiles.size(repaired.appendingPathComponent("receipt.json")) != nil)
    }
    @Test func retryRepairsSameSizeCorruptWeights() async throws {
        let server = try await Server.start("normal"), downloader = try server.downloader()
        let plan = try await downloader.plan(pin)
        _ = try await downloader.install(pin)
        let weights = server.destination.appendingPathComponent("weights.bin")
        try Data(repeating:0,count:Int(plan.files[0].rawBytes)).write(to:weights)
        _ = try await downloader.install(pin)
        #expect(try ModelFiles.digest(weights) == plan.files[0].rawSHA256)
    }
    @Test func removeWaitsForAnExternalCancelledTransferToReleaseTheRevisionLock() async throws {
        let server = try await Server.start("normal"), downloader = try server.downloader()
        _ = try await downloader.install(pin)
        let path = server.destination.deletingLastPathComponent().appendingPathComponent("." + pin.sourceSHA256 + ".lock")
        let fd = open(path.path,O_RDWR | O_CLOEXEC)
        #expect(fd >= 0); #expect(flock(fd,LOCK_EX | LOCK_NB) == 0)
        defer { flock(fd,LOCK_UN); close(fd) }
        let waiting = RemovalLockEvent()
        let remover = try server.downloader(removalLockWaiting:{ waiting.signal() })
        let removal = Task { try await remover.remove(pin) }
        defer { removal.cancel() }
        try await waiting.wait()
        #expect(FileManager.default.fileExists(atPath:server.destination.path),"A contended removal cannot delete the installation")
        flock(fd,LOCK_UN)
        try await removal.value
        #expect(!FileManager.default.fileExists(atPath:server.destination.path))
    }
    @Test func cancellationWhileWaitingForRemoveLeavesTheInstallationIntact() async throws {
        let server = try await Server.start("normal"), downloader = try server.downloader()
        _ = try await downloader.install(pin)
        let path = server.destination.deletingLastPathComponent().appendingPathComponent("." + pin.sourceSHA256 + ".lock")
        let fd = open(path.path,O_RDWR | O_CLOEXEC)
        guard fd >= 0,flock(fd,LOCK_EX | LOCK_NB) == 0 else { if fd >= 0 { close(fd) }; throw ModelDownloadError.busy }
        defer { flock(fd,LOCK_UN); close(fd) }
        let waiting = RemovalLockEvent()
        let remover = try server.downloader(removalLockWaiting:{ waiting.signal() })
        let task = Task { try await remover.remove(pin) }
        defer { task.cancel() }
        try await waiting.wait()
        task.cancel()
        let error = await fails { try await task.value }
        #expect(error is CancellationError)
        #expect(FileManager.default.fileExists(atPath:server.destination.path))
    }
    @Test func inventoryRequiresReceiptAndNoticeAndNeverFetchesMetadata() async throws {
        let server = try await Server.start("normal"), downloader = try server.downloader()
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
        let server = try await Server.start("normal"), downloader = try server.downloader()
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
        let server = try await Server.start("normal"), downloader = try server.downloader()
        let plan = try await downloader.plan(pin)
        _ = try await downloader.install(pin)
        let weights = server.destination.appendingPathComponent("weights.bin"), original = try Data(contentsOf:server.destination.appendingPathComponent("weights.bin"))
        try Data(repeating:0,count:original.count).write(to:weights)
        let lockFile = server.destination.deletingLastPathComponent().appendingPathComponent("." + pin.sourceSHA256 + ".lock")
        let fd = open(lockFile.path,O_RDWR | O_CLOEXEC)
        guard fd >= 0,flock(fd,LOCK_EX | LOCK_NB) == 0 else { if fd >= 0 { close(fd) }; throw ModelDownloadError.busy }
        defer { flock(fd,LOCK_UN); close(fd) }
        let waiting = RemovalLockEvent()
        let remover = try server.downloader(removalLockWaiting:{ waiting.signal() })
        let removal = Task { try await remover.removeInvalid(plan) }
        defer { removal.cancel() }
        try await waiting.wait()
        try original.write(to:weights)
        flock(fd,LOCK_UN)
        #expect(try await removal.value == false)
        #expect(ModelStorage.isInstalled(plan,in:server.appData))
    }
    @Test func progressReportsBytesAndMarksOnlyTheAtomicInstallComplete() async throws {
        let server = try await Server.start("normal"), downloader = try server.downloader(), log = ProgressLog()
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
        let server = try await Server.start("raw-hash"), downloader = try server.downloader(), log = ProgressLog()
        let error = await fails { _ = try await downloader.install(pin) { log.add($0) } }
        #expect(error as? ModelDownloadError == .hash)
        #expect(!log.snapshot().isEmpty && !log.snapshot().contains { $0.isInstalled })
        #expect(!FileManager.default.fileExists(atPath:server.destination.path))
    }

    @Test(arguments:["normal","no-length"]) func installVerifyReuseWithoutArtifactDownloadAndRemove(_ scenario: String) async throws {
        let server = try await Server.start(scenario), downloader = try server.downloader()
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
        // D54: the manifest, the NOTICE and every artifact request carry the exact header.
        let paths = server.requests.compactMap { $0["path"] as? String }
        #expect(paths.contains("/manifest.json") && paths.contains("/NOTICE.txt") && paths.contains { $0.hasPrefix("/models/") })
        #expect(server.requests.allSatisfy { $0["userAgent"] as? String == agent })
        #expect(!server.requests.contains { ($0["path"] as? String)?.contains("example.invalid") == true })
        try await downloader.remove(pin); #expect(!FileManager.default.fileExists(atPath:result.path)); #expect(ModelStorage.notices(in:server.appData).isEmpty)
        _ = try await downloader.install(pin); #expect(FileManager.default.fileExists(atPath:result.path))
    }
    @Test(arguments:["truncated","416","ignore-range"]) func resumeWithRangeAndIfRange(_ scenario: String) async throws {
        let server = try await Server.start(scenario), downloader = try server.downloader()
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
        let server = try await Server.start("503"), downloader = try server.downloader()
        _ = await fails { _ = try await downloader.install(pin) { server.acknowledgePersistedPrefix($0) } }
        try #require(server.prefixAcknowledged,"Fault follows a real persisted-prefix event")
        let error = await fails { _ = try await downloader.install(pin) }
        #expect(error as? ModelDownloadError == .response)
        _ = try await downloader.install(pin)
        let ranges = server.requests.compactMap { $0["range"] as? String }
        #expect(ranges.count == 2 && ranges[0] == ranges[1])
    }
    @Test(arguments:["changed-etag","bad-range"]) func changedIdentityNeverAppends(_ scenario: String) async throws {
        let server = try await Server.start(scenario), downloader = try server.downloader()
        _ = await fails { _ = try await downloader.install(pin) { server.acknowledgePersistedPrefix($0) } }
        try #require(server.prefixAcknowledged,"Fault follows a real persisted-prefix event")
        let error = await fails { _ = try await downloader.install(pin) }
        #expect((error as? ModelDownloadError) == (scenario == "changed-etag" ? .etag : .range))
        #expect(!FileManager.default.fileExists(atPath:server.destination.path))
        _ = try await downloader.install(pin)
        #expect(server.requests.filter { $0["range"] is String }.count == 1)
    }
    @Test(arguments:["compressed-hash","raw-hash","unsafe-path","wrong-origin","redirect"]) func rejectsWithoutPublishing(_ scenario: String) async throws {
        let server = try await Server.start(scenario), downloader = try server.downloader()
        let error = await fails { _ = try await downloader.install(pin) }
        if scenario.contains("hash") { #expect(error as? ModelDownloadError == .hash) }
        #expect(!FileManager.default.fileExists(atPath:server.destination.path))
        let folders = (try? FileManager.default.contentsOfDirectory(atPath:server.destination.deletingLastPathComponent().path)) ?? []
        #expect(!folders.contains { $0.hasPrefix(".install-") })
        if scenario == "unsafe-path" || scenario == "wrong-origin" { #expect(server.requests.count == 1) }
        // D54: the hop that answered with a redirect carried the header too; the redirect
        // itself is refused (models come only from the pinned origin).
        if scenario == "redirect" { #expect(server.requests.contains { ($0["path"] as? String)?.hasPrefix("/models/") == true }) }
        #expect(server.requests.allSatisfy { $0["userAgent"] as? String == agent })
    }
    @Test func theUserAgentNamesTheAppItsVersionAndThePlatformOnly() {
        #expect(ModelUserAgent.make(version:"9.8.7",system:.init(majorVersion:15,minorVersion:1,patchVersion:0),architecture:"arm64") == agent)
        #expect(ModelUserAgent.make(version:"0.3.0-dev",system:.init(majorVersion:26,minorVersion:0,patchVersion:2),architecture:"x86_64")
                == "CassiniTalk/0.3.0-dev (macOS 26.0.2; x86_64)")
        // A missing or unsafe version is never replaced by a stale literal.
        #expect(ModelUserAgent.make(version:"",system:.init(majorVersion:15,minorVersion:1,patchVersion:0),architecture:"arm64") == "CassiniTalk/unknown (macOS 15.1; arm64)")
        #expect(ModelUserAgent.make(version:"1.0\r\nX: y",system:.init(majorVersion:15,minorVersion:1,patchVersion:0),architecture:"arm64").hasPrefix("CassiniTalk/unknown "))
        #expect(ModelUserAgent.architecture == "arm64" || ModelUserAgent.architecture == "x86_64")
    }
    @Test func fullDiskStopsBeforeArtifact() async throws {
        let server = try await Server.start("normal"), downloader = try server.downloader(budget:{ _ in .init(free:1 << 30,total:100 << 30) })
        let error = await fails { _ = try await downloader.install(pin) }
        guard case .diskSpace = error as? ModelDownloadError else { Issue.record("Missing disk budget failure"); return }
        #expect(server.requests.count == 1)
        #expect(!FileManager.default.fileExists(atPath:server.destination.path))
    }
    @Test func cancelAndRemoveWaitForTransferWithoutResurrection() async throws {
        let server = try await Server.start("pending"), downloader = try server.downloader()
        let first = PendingTransfer()
        let task = Task { try await downloader.install(pin) { first.receive($0) } }
        defer { task.cancel() }
        try await first.wait()
        await downloader.cancel(pin)
        let cancelled = await fails { _ = try await task.value }
        #expect(cancelled is CancellationError || (cancelled as? URLError)?.code == .cancelled)
        #expect(!FileManager.default.fileExists(atPath:server.destination.path))
        let cache = server.appData.appendingPathComponent("model-downloads/" + pin.id + "/" + pin.sourceSHA256)
        let files = try FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil)
        let partial = try #require(files.first { $0.pathExtension == "part" })
        let size = try ModelFiles.size(partial)
        let prefix = try #require(size)
        #expect(prefix > 0)
        let second = PendingTransfer(after:prefix)
        let task2 = Task { try await downloader.install(pin) { second.receive($0) } }
        defer { task2.cancel() }
        try await second.wait()
        #expect(server.requests.contains { $0["range"] as? String == "bytes=\(prefix)-" })
        try await downloader.remove(pin)
        let removed = await fails { _ = try await task2.value }
        #expect(removed is CancellationError || (removed as? URLError)?.code == .cancelled)
        #expect(!FileManager.default.fileExists(atPath:server.destination.path))
        #expect(!FileManager.default.fileExists(atPath:cache.path))
    }
    @Test func revisionPinMustBePresentAndOriginalInstallSurvivesBadUpdate() async throws {
        let server = try await Server.start("normal"), downloader = try server.downloader()
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
